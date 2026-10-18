import Foundation

/// Reads the system's Now Playing state through Apple's own `/usr/bin/perl`.
///
/// Since macOS 15.4 MediaRemote answers a third-party process with "nothing playing". Apple's
/// perl is a platform binary (`com.apple.perl`) and still gets real answers, so a small perl
/// script loads our library (`bundle/mediaremote/uv_nowplaying.c`) and answers one JSON line
/// per "get <n>" line on stdin. The approach is the one the open-source ungive/mediaremote-adapter
/// (BSD-3-Clause) uses; the script and the library here are our own code.
///
/// One long-lived perl process serves every read. `read()` blocks its caller for at most 500 ms
/// (a few ms in practice) and is only called from the policy's own queue, never the main thread.
///
/// Failure handling, because this is a child process that can die at any time:
/// - Writes never raise SIGPIPE (`F_SETNOSIGPIPE`), and nothing is written to a process that is
///   not running; a dead helper is a failed read, and the next read starts a new one.
/// - Every request carries a number and every answer echoes it, so a late answer to a request
///   that timed out is never taken for the next one.
/// - After three failures in a row the reader backs off (30 s, then 2 min, then 2 min again)
///   and returns nil without starting anything; the policy uses the audio process list meanwhile.
/// - Missing files, a missing perl, or a library whose signature is not the app's turn it off
///   for the session. The library's signature is checked before every start.
/// Every failure is logged to Diagnostics, once per backoff.
final class NowPlayingReader: @unchecked Sendable {
    private let directory: URL?
    private let executable: URL
    private let diagnostics: Diagnostics
    private let verify: (URL) -> String?
    private let backoff: [TimeInterval]
    private let readTimeout: TimeInterval
    private let startTimeout: TimeInterval
    private let failuresBeforeBackoff: Int
    private let clock: () -> Date

    /// Held for a whole `read()` or start, so there is one request in flight at a time.
    private let requests = NSLock()
    /// Guards what the reading thread shares with `read()`.
    private let condition = NSCondition()

    // Shared with the reading thread (under `condition`).
    private var process: Process?
    private var input: FileHandle?
    private var ready = false
    /// The helper's output ended: it exited (or closed its output).
    private var finished = false
    private var processGeneration = 0
    private enum Answer { case state(NowPlayingState), failed }
    private var answers: [Int: Answer] = [:]

    // Only under `requests`.
    private var sequence = 0
    private var failures = 0
    private var backoffLevel = 0
    private var backoffUntil: Date?
    private var permanentlyOff = false
    private var loggedFirstFailure = false

    /// - Parameters:
    ///   - directory: the folder holding `uv-nowplaying.pl` and `libuvnowplaying.dylib`
    ///     (`Contents/Resources/MediaRemote` in the app). Nil or missing files: unavailable.
    ///   - verify: returns why a library must not be loaded, or nil when it is trusted.
    init(directory: URL?,
         executable: URL = URL(fileURLWithPath: "/usr/bin/perl"),
         diagnostics: Diagnostics = .shared,
         verify: @escaping (URL) -> String? = HelperSignature.problem(with:),
         backoff: [TimeInterval] = [30, 120],
         readTimeout: TimeInterval = 0.5,
         startTimeout: TimeInterval = 3,
         failuresBeforeBackoff: Int = 3,
         clock: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.executable = executable
        self.diagnostics = diagnostics
        self.verify = verify
        self.backoff = backoff.isEmpty ? [30] : backoff
        self.readTimeout = readTimeout
        self.startTimeout = startTimeout
        self.failuresBeforeBackoff = failuresBeforeBackoff
        self.clock = clock
    }

    /// The helper's process id, for tests that kill it.
    var helperProcessIDForTesting: Int32? {
        condition.lock()
        defer { condition.unlock() }
        return process?.processIdentifier
    }

    /// Starts the helper ahead of the first dictation. Safe from any thread.
    func warmUp() {
        DispatchQueue.global(qos: .utility).async { [self] in
            requests.lock()
            defer { requests.unlock() }
            guard canTry else { return }
            _ = startIfNeeded()
        }
    }

    /// Asks the helper for the current state. Nil when it cannot answer.
    func read(timeout: TimeInterval? = nil) -> NowPlayingState? {
        requests.lock()
        defer { requests.unlock() }
        guard canTry else { return nil }
        guard startIfNeeded() else { return nil }

        condition.lock()
        let task = process, handle = input, generation = processGeneration
        condition.unlock()
        guard let task, let handle, task.isRunning else {
            stopHelper()
            return fail("the helper is not running")
        }

        sequence += 1
        let id = sequence
        condition.lock()
        answers = answers.filter { $0.key >= id }   // forget answers to requests nobody waits for
        condition.unlock()
        guard send("get \(id)\n", to: handle, task: task) else {
            stopHelper()
            return fail("the helper could not be written to")
        }

        let limit = timeout ?? readTimeout
        let deadline = Date().addingTimeInterval(limit)
        condition.lock()
        while answers[id] == nil, !finished, processGeneration == generation, condition.wait(until: deadline) {}
        let answer = answers[id]
        condition.unlock()

        switch answer {
        case .state(let state)?:
            failures = 0
            backoffLevel = 0
            backoffUntil = nil
            return state
        case .failed?:
            return fail("MediaRemote did not answer the helper")
        case nil:
            if !task.isRunning {
                stopHelper()
                return fail("the helper exited while a read was waiting")
            }
            return fail("the helper did not answer within \(Int(limit * 1000)) ms")
        }
    }

    // MARK: - Process

    /// Caller holds `requests`. False while backing off or turned off.
    private var canTry: Bool {
        if permanentlyOff { return false }
        if let backoffUntil, clock() < backoffUntil { return false }
        return true
    }

    /// Caller holds `requests`.
    private func startIfNeeded() -> Bool {
        condition.lock()
        let alreadyRunning = process?.isRunning == true && ready
        condition.unlock()
        if alreadyRunning { return true }
        stopHelper()

        guard let directory,
              case let script = directory.appendingPathComponent("uv-nowplaying.pl"),
              case let library = directory.appendingPathComponent("libuvnowplaying.dylib"),
              FileManager.default.isReadableFile(atPath: script.path),
              FileManager.default.isReadableFile(atPath: library.path) else {
            turnOff("the helper files are missing")
            return false
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            turnOff("\(executable.path) is missing")
            return false
        }
        if let problem = verify(library) {
            turnOff("it will not load a helper that is not the app's own: \(problem)")
            return false
        }

        let task = Process()
        task.executableURL = executable
        task.arguments = [script.path, library.path]
        task.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let stdin = Pipe(), stdout = Pipe()
        // A write to a helper that has exited must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            _ = fail("perl would not start (\(error.localizedDescription))")
            return false
        }
        condition.lock()
        processGeneration += 1
        let generation = processGeneration
        process = task
        input = stdin.fileHandleForWriting
        ready = false
        finished = false
        answers = [:]
        condition.unlock()
        let reading = stdout.fileHandleForReading
        let thread = Thread { [weak self] in self?.readLines(from: reading, generation: generation) }
        thread.name = "ai.useful.voice.nowplaying-reader"
        thread.start()

        let deadline = Date().addingTimeInterval(startTimeout)
        condition.lock()
        while !ready, !finished, processGeneration == generation, condition.wait(until: deadline) {}
        let isReady = ready && !finished
        condition.unlock()
        if !isReady {
            let exited = !task.isRunning
            stopHelper()
            _ = fail(exited ? "the helper exited before it was ready" : "the helper did not become ready")
        }
        return isReady
    }

    private func readLines(from handle: FileHandle, generation: Int) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }   // end of output: the process exited
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                consume(line: line, generation: generation)
            }
        }
        condition.lock()
        if processGeneration == generation {
            ready = false
            finished = true
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Lines are `{"ready":1}` once, then `seq=<n> {json}` per answer.
    private func consume(line: Data, generation: Int) {
        guard let text = String(data: line, encoding: .utf8) else { return }
        condition.lock()
        defer { condition.unlock() }
        guard processGeneration == generation else { return }
        if text.hasPrefix("seq="), let space = text.firstIndex(of: " "),
           let id = Int(text[text.index(text.startIndex, offsetBy: 4)..<space]) {
            let json = Data(text[text.index(after: space)...].utf8)
            guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
                answers[id] = .failed
                condition.broadcast()
                return
            }
            if let playing = object["playing"] as? Int, let pid = object["pid"] as? Int {
                let bundle = (object["bundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                answers[id] = .state(NowPlayingState(isPlaying: playing == 1, pid: Int32(pid), bundleID: bundle))
            } else {
                answers[id] = .failed   // {"error": ...}
            }
        } else if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  object["ready"] != nil {
            ready = true
        }
        condition.broadcast()
    }

    private func send(_ text: String, to handle: FileHandle, task: Process) -> Bool {
        guard task.isRunning else { return false }
        do {
            try handle.write(contentsOf: Data(text.utf8))
            return true
        } catch {
            return false   // EPIPE: the helper is gone
        }
    }

    /// Caller holds `requests`.
    private func stopHelper() {
        condition.lock()
        let task = process
        let handle = input
        process = nil
        input = nil
        ready = false
        processGeneration += 1
        condition.broadcast()
        condition.unlock()
        if let task, let handle {
            _ = send("quit\n", to: handle, task: task)
        }
        try? handle?.close()
        if let task, task.isRunning { task.terminate() }
    }

    // MARK: - Failures

    /// Caller holds `requests`. Always returns nil, so a read can `return fail(...)`.
    private func fail(_ reason: String) -> NowPlayingState? {
        failures += 1
        if failures >= failuresBeforeBackoff {
            let delay = backoff[min(backoffLevel, backoff.count - 1)]
            backoffLevel += 1
            failures = 0
            backoffUntil = clock().addingTimeInterval(delay)
            stopHelper()
            diagnostics.warning("media", "Reading Now Playing failed \(failuresBeforeBackoff) times (\(reason)). Using the audio process list, trying again in \(Int(delay)) s")
        } else if !loggedFirstFailure {
            loggedFirstFailure = true
            diagnostics.warning("media", "Reading Now Playing failed: \(reason). Using the audio process list for now")
        }
        return nil
    }

    /// Caller holds `requests`. For failures a retry cannot fix.
    private func turnOff(_ reason: String) {
        guard !permanentlyOff else { return }
        permanentlyOff = true
        diagnostics.warning("media", "Reading Now Playing is off for this session: \(reason). Using the audio process list")
        stopHelper()
    }
}
