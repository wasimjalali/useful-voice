import Foundation

/// Reads the system's Now Playing state through Apple's own `/usr/bin/perl`.
///
/// Since macOS 15.4 MediaRemote answers a third-party process with "nothing playing". Apple's
/// perl is a platform binary (`com.apple.perl`) and still gets real answers, so a small perl
/// script loads our library (`bundle/mediaremote/uv_nowplaying.c`) and answers one JSON line
/// per "get" line on stdin. The approach is the one the open-source ungive/mediaremote-adapter
/// (BSD-3-Clause) uses; the script and the library here are our own code.
///
/// One long-lived perl process serves every read. `read()` blocks its caller for at most 500 ms
/// (a few ms in practice) and is only called from the policy's own queue, never the main thread.
/// Any failure (no helper files, perl missing, a timeout, the process dying) returns nil, logs
/// one line, and after repeated failures stops trying: the policy then uses the audio list.
final class NowPlayingReader: @unchecked Sendable {
    static let readTimeout: TimeInterval = 0.5
    /// Perl starting and loading the library takes a moment the first time.
    static let startTimeout: TimeInterval = 3
    private static let failuresBeforeGivingUp = 3

    private let directory: URL?
    private let diagnostics: Diagnostics
    private let condition = NSCondition()
    private let requests = NSLock()

    private var process: Process?
    private var input: FileHandle?
    private var ready = false
    private var responses = 0
    private var latest: NowPlayingState?
    private var failures = 0
    private var givenUp = false
    private var loggedFailure = false

    /// - Parameter directory: the folder holding `uv-nowplaying.pl` and `libuvnowplaying.dylib`
    ///   (`Contents/Resources/MediaRemote` in the app). Nil or missing files: unavailable.
    init(directory: URL?, diagnostics: Diagnostics = .shared) {
        self.directory = directory
        self.diagnostics = diagnostics
    }

    /// Starts the helper ahead of the first dictation. Safe from any thread.
    func warmUp() {
        DispatchQueue.global(qos: .utility).async { [self] in
            requests.lock()
            defer { requests.unlock() }
            _ = startIfNeeded()
        }
    }

    /// Asks the helper for the current state. Nil when it cannot answer.
    func read() -> NowPlayingState? {
        requests.lock()
        defer { requests.unlock() }
        guard !isGivenUp else { return nil }
        guard startIfNeeded(), let input else { return noteFailure("the helper could not start") }

        condition.lock()
        let target = responses + 1
        condition.unlock()
        do {
            try input.write(contentsOf: Data("get\n".utf8))
        } catch {
            return noteFailure("could not write to the helper (\(error.localizedDescription))")
        }
        let deadline = Date().addingTimeInterval(Self.readTimeout)
        condition.lock()
        while responses < target, condition.wait(until: deadline) {}
        let answered = responses >= target
        let state = latest
        condition.unlock()
        guard answered else { return noteFailure("the helper did not answer within 500 ms") }
        guard let state else { return noteFailure("MediaRemote did not answer the helper") }
        failures = 0
        return state
    }

    // MARK: - Process

    private var isGivenUp: Bool {
        condition.lock()
        defer { condition.unlock() }
        return givenUp
    }

    /// Caller holds `requests`.
    private func startIfNeeded() -> Bool {
        condition.lock()
        let alreadyRunning = process?.isRunning == true && ready
        condition.unlock()
        if alreadyRunning { return true }
        stop()

        guard let directory,
              case let script = directory.appendingPathComponent("uv-nowplaying.pl"),
              case let library = directory.appendingPathComponent("libuvnowplaying.dylib"),
              FileManager.default.isReadableFile(atPath: script.path),
              FileManager.default.isReadableFile(atPath: library.path) else {
            giveUp("the helper files are missing")
            return false
        }
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        guard FileManager.default.isExecutableFile(atPath: perl.path) else {
            giveUp("/usr/bin/perl is missing")
            return false
        }

        let task = Process()
        task.executableURL = perl
        task.arguments = [script.path, library.path]
        task.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let stdin = Pipe(), stdout = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            giveUp("perl would not start (\(error.localizedDescription))")
            return false
        }
        condition.lock()
        process = task
        input = stdin.fileHandleForWriting
        ready = false
        responses = 0
        latest = nil
        condition.unlock()
        let thread = Thread { [weak self] in self?.readLines(from: stdout.fileHandleForReading) }
        thread.name = "ai.useful.voice.nowplaying-reader"
        thread.start()

        let deadline = Date().addingTimeInterval(Self.startTimeout)
        condition.lock()
        while !ready, task.isRunning, condition.wait(until: deadline) {}
        let isReady = ready
        condition.unlock()
        if !isReady {
            stop()
            _ = noteFailure("the helper did not become ready")
        }
        return isReady
    }

    private func readLines(from handle: FileHandle) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }   // end of output: the process exited
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                consume(line: line)
            }
        }
        condition.lock()
        ready = false
        condition.broadcast()
        condition.unlock()
    }

    private func consume(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        condition.lock()
        defer { condition.unlock() }
        if object["ready"] != nil {
            ready = true
        } else if let playing = object["playing"] as? Int, let pid = object["pid"] as? Int {
            let bundle = (object["bundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            latest = NowPlayingState(isPlaying: playing == 1, pid: Int32(pid), bundleID: bundle)
            responses += 1
        } else {
            latest = nil   // {"error": ...}
            responses += 1
        }
        condition.broadcast()
    }

    private func stop() {
        condition.lock()
        let task = process
        let handle = input
        process = nil
        input = nil
        ready = false
        condition.broadcast()
        condition.unlock()
        try? handle?.write(contentsOf: Data("quit\n".utf8))
        try? handle?.close()
        if let task, task.isRunning { task.terminate() }
    }

    private func noteFailure(_ reason: String) -> NowPlayingState? {
        failures += 1
        if !loggedFailure {
            loggedFailure = true
            diagnostics.warning("media", "Reading Now Playing failed: \(reason). Using the audio process list instead")
        }
        if failures >= Self.failuresBeforeGivingUp { giveUp("it failed \(failures) times in a row") }
        return nil
    }

    private func giveUp(_ reason: String) {
        condition.lock()
        givenUp = true
        condition.unlock()
        if !loggedFailure {
            loggedFailure = true
            diagnostics.warning("media", "Reading Now Playing is off: \(reason). Using the audio process list instead")
        }
        stop()
    }
}
