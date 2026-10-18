// Live E2E for "Pause media while dictating". It compiles the app's own policy and system
// effects (Sources/UsefulVoiceCore/Media) with a test player (player.swift) that plays
// silence, drives recordingStarted and recordingEnded the way the app does, and checks the
// player's own command log and Core Audio's view of its output.
//
// Run through `scripts/media-pause-e2e/run.sh`. It refuses to start while anything else on
// the Mac is outputting audio, because the commands go to the Now Playing app.
import Foundation

/// Diagnostics.swift names the app's data folder. The harness logs to memory only, so a
/// stand-in keeps it from pulling in the rest of the app.
enum DataFolder {
    static func current(environment: [String: String]) -> URL? { nil }
}

struct Check {
    let scenario: String
    let name: String
    let passed: Bool
    let detail: String
}

final class Player {
    let process = Process()
    let stdin = Pipe()
    let logURL: URL
    private(set) var pid: Int32 = 0

    init(playerPath: String, logURL: URL, startPaused: Bool, background: Bool = false, tail: Int = 0) throws {
        self.logURL = logURL
        process.executableURL = URL(fileURLWithPath: playerPath)
        process.arguments = ["--log", logURL.path] + (startPaused ? ["--paused"] : [])
            + (background ? ["--background"] : []) + (tail > 0 ? ["--tail", String(tail)] : [])
        process.standardInput = stdin
        try process.run()
        pid = process.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !lines().contains(where: { $0.text.hasPrefix("READY") }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.4)   // let Now Playing registration settle
    }

    func send(_ word: String) {
        stdin.fileHandleForWriting.write(Data((word + "\n").utf8))
    }

    struct Line { let time: TimeInterval; let text: String }
    func lines() -> [Line] {
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let time = Double(parts[0]) else { return nil }
            return Line(time: time, text: String(parts[1]))
        }
    }
    func commands(_ name: String) -> [Line] { lines().filter { $0.text == "COMMAND \(name)" } }
    func allCommands() -> [Line] { lines().filter { $0.text.hasPrefix("COMMAND") } }

    func quit() {
        send("quit")
        process.waitUntilExit()
    }
}

@main
struct Harness {
    static func isRunning(_ bundleID: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-xq", bundleID == "com.apple.Music" ? "Music" : bundleID]
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
    static let musicWasRunningBefore = isRunning("com.apple.Music")
    static var checks: [Check] = []
    static var timeline: [String] = []
    static var latencies: [(String, Double)] = []
    static let origin = Date().timeIntervalSince1970
    /// `UV_E2E_AUDIO_ONLY=1` leaves the Now Playing reader out, so the audio fallback is what runs.
    static let audioOnly = ProcessInfo.processInfo.environment["UV_E2E_AUDIO_ONLY"] == "1"
    static let effects = SystemMediaEffects(
        helperDirectory: audioOnly || CommandLine.arguments.count < 5 ? nil : URL(fileURLWithPath: CommandLine.arguments[4]))

    static func note(_ text: String) {
        let line = String(format: "[+%7.3fs] %@", Date().timeIntervalSince1970 - origin, text)
        timeline.append(line)
        print(line)
    }

    static func record(_ scenario: String, _ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append(Check(scenario: scenario, name: name, passed: passed, detail: detail))
        note("\(passed ? "PASS" : "FAIL") \(scenario): \(name) \(detail)")
    }

    /// Everything outputting audio that is not this process and not a system sound.
    static func outputting() -> [MediaPlayerID] { (try? effects.outputtingPlayers()) ?? [] }

    /// Waits until the player's output state is `wanted`; returns the wall-clock time it
    /// was first seen, or nil on timeout. Polls every 2 ms.
    static func waitOutput(pid: Int32, playing wanted: Bool, timeout: TimeInterval) -> TimeInterval? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let isPlaying = outputting().contains { $0.pid == pid }
            if isPlaying == wanted { return Date().timeIntervalSince1970 }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return nil
    }

    static func makePolicy(diagnostics: Diagnostics, effects: MediaEffects? = nil) -> MediaPausePolicy {
        MediaPausePolicy(effects: effects ?? Self.effects, isEnabled: { true }, diagnostics: diagnostics)
    }

    static func ms(_ seconds: TimeInterval) -> String { String(format: "%.0f ms", seconds * 1000) }

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4 else {
            print("usage: harness <player binary> <out dir> <only: all|name> [helper dir]")
            exit(2)
        }
        let playerPath = arguments[1]
        let outDir = URL(fileURLWithPath: arguments[2])
        let only = arguments[3]
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        _ = musicWasRunningBefore   // read before anything runs, for the "Music was not launched" check

        // A full run starts from clean player logs, so an old one cannot colour the checks.
        if only == "all", let old = try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            for url in old where url.lastPathComponent.hasPrefix("player-") { try? FileManager.default.removeItem(at: url) }
        }

        // Never pause the owner's real media.
        let busy = outputting()
        if !busy.isEmpty {
            note("SKIPPED: \(busy.map(\.description).joined(separator: ", ")) is outputting audio. Not sending any command.")
            write(outDir, skipped: busy)
            exit(3)
        }

        let scenarios: [(String, () throws -> Void)] = [
            ("A-pause-and-resume", scenarioPauseAndResume),
            ("B-nothing-playing", scenarioNothingPlaying),
            ("C-user-restarts-mid-dictation", scenarioUserRestarts),
            ("D-user-plays-and-pauses-with-nothing-held", scenarioUserPlaysAndPauses),
            ("E-back-to-back", scenarioBackToBack),
            ("F-quit-while-paused", scenarioQuit),
            ("G-background-stream", scenarioBackgroundStream),
            ("I-user-plays-then-pauses-again-mid-dictation", scenarioUserPlaysThenPausesAgain),
            ("J-play-reaches-a-different-app", scenarioPlayReachesAnotherApp),
            ("N-chromium-style-audio-tail", scenarioAudioTail),
            ("K-alert-blip-300ms", { try scenarioAlertBlip(id: "K", milliseconds: 300) }),
            ("L-alert-blip-60ms", { try scenarioAlertBlip(id: "L", milliseconds: 60) }),
            ("M-alert-blip-200ms-known-gap", { try scenarioAlertBlip(id: "M", milliseconds: 200, informational: true) }),
            ("H-latency-x10", scenarioLatency),
        ]
        for (name, run) in scenarios where only == "all" || only == name {
            let stillBusy = outputting()
            guard stillBusy.isEmpty else {
                record(name, "precondition: nothing else playing", false, stillBusy.map(\.description).joined(separator: ", "))
                continue
            }
            note("--- \(name)")
            do { try run() } catch { record(name, "ran without an error", false, "\(error)") }
        }
        // The Play/Pause key toggles and is never used: no scenario may have seen one.
        if only == "all", let logs = try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil) {
            let toggles = logs.filter { $0.lastPathComponent.hasPrefix("player-") }
                .filter { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("togglePlayPause") }
            record("all", "no Play/Pause key press reached any player", toggles.isEmpty,
                   toggles.map(\.lastPathComponent).joined(separator: ", "))
        }
        write(outDir, skipped: [])
        let failed = checks.filter { !$0.passed }
        exit(failed.isEmpty ? 0 : 1)
    }

    // MARK: - Scenarios

    static func scenarioPauseAndResume() throws {
        let s = "A-pause-and-resume"
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: false)
        defer { player.quit() }
        record(s, "test player is outputting", outputting().contains { $0.pid == player.pid })
        let diagnostics = Diagnostics(directory: nil)
        let policy = makePolicy(diagnostics: diagnostics)

        let t0 = Date().timeIntervalSince1970
        policy.recordingStarted()
        note("recordingStarted() returned after \(ms(Date().timeIntervalSince1970 - t0))")
        let hotPath = Date().timeIntervalSince1970 - t0
        record(s, "recordingStarted returns at once (< 50 ms)", hotPath < 0.05, ms(hotPath))
        let stopped = waitOutput(pid: player.pid, playing: false, timeout: 1.5)
        policy.flush()
        let pauseCommand = player.commands("pause").first
        if let pauseCommand {
            let latency = pauseCommand.time - t0
            latencies.append(("pause command received", latency))
            record(s, "pause command received within 500 ms", latency < 0.5, ms(latency))
        } else {
            record(s, "pause command received within 500 ms", false, "no pause command")
        }
        if let stopped {
            latencies.append(("output stopped", stopped - t0))
            record(s, "player stopped outputting within 500 ms", stopped - t0 < 0.5, ms(stopped - t0))
        } else {
            record(s, "player stopped outputting within 500 ms", false, "still outputting")
        }

        Thread.sleep(forTimeInterval: 0.3)   // a dictation
        let t1 = Date().timeIntervalSince1970
        policy.recordingEnded()
        let started = waitOutput(pid: player.pid, playing: true, timeout: 2)
        policy.flush()
        if let playCommand = player.commands("play").first {
            latencies.append(("play command received", playCommand.time - t1))
            record(s, "play command received after the recording ended", true, ms(playCommand.time - t1))
        } else {
            record(s, "play command received after the recording ended", false, "no play command")
        }
        if let started {
            latencies.append(("output resumed", started - t1))
            record(s, "player outputs again", true, ms(started - t1))
        } else {
            record(s, "player outputs again", false)
        }
        record(s, "exactly one pause and one play", player.commands("pause").count == 1 && player.commands("play").count == 1,
               "pause \(player.commands("pause").count), play \(player.commands("play").count)")
        note("diagnostics: " + diagnostics.entries().map { "[\($0.level.rawValue)] \($0.category): \($0.message)" }.joined(separator: " | "))
    }

    static func scenarioNothingPlaying() throws {
        let s = "B-nothing-playing"
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: true)
        defer { player.quit() }
        let policy = makePolicy(diagnostics: Diagnostics(directory: nil))
        policy.recordingStarted()
        Thread.sleep(forTimeInterval: 0.5)
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 0.6)
        policy.flush()
        record(s, "no command sent to a registered but paused player", player.allCommands().isEmpty,
               "\(player.allCommands().count) commands")
        record(s, "player still not outputting", !outputting().contains { $0.pid == player.pid })
    }

    static func scenarioUserRestarts() throws {
        let s = "C-user-restarts-mid-dictation"
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: false)
        defer { player.quit() }
        let policy = makePolicy(diagnostics: Diagnostics(directory: nil))
        policy.recordingStarted()
        _ = waitOutput(pid: player.pid, playing: false, timeout: 1.5)
        policy.flush()
        record(s, "paused by the dictation", player.commands("pause").count == 1)
        player.send("play")   // the user presses play in the player mid-dictation
        _ = waitOutput(pid: player.pid, playing: true, timeout: 1)
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 0.8)
        policy.flush()
        record(s, "no play command sent by us after the user restarted it", player.commands("play").isEmpty,
               "play commands: \(player.commands("play").count)")
        record(s, "player is still playing, undisturbed", outputting().contains { $0.pid == player.pid })
    }

    static func scenarioUserPlaysAndPauses() throws {
        let s = "D-user-plays-and-pauses-with-nothing-held"
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: true)
        defer { player.quit() }
        let policy = makePolicy(diagnostics: Diagnostics(directory: nil))
        policy.recordingStarted()
        Thread.sleep(forTimeInterval: 0.3)
        player.send("play")
        Thread.sleep(forTimeInterval: 0.4)
        player.send("pause")
        Thread.sleep(forTimeInterval: 0.3)
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 0.6)
        policy.flush()
        record(s, "no commands from us (the user's own play and pause only)", player.allCommands().isEmpty,
               "\(player.allCommands().count) commands")
        record(s, "player left paused as the user left it", !outputting().contains { $0.pid == player.pid })
    }

    static func scenarioBackToBack() throws {
        let s = "E-back-to-back"
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: false)
        defer { player.quit() }
        let policy = makePolicy(diagnostics: Diagnostics(directory: nil))
        policy.recordingStarted()
        _ = waitOutput(pid: player.pid, playing: false, timeout: 1.5)
        policy.flush()
        Thread.sleep(forTimeInterval: 0.2)
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 0.3)    // inside the 400 ms resume grace
        policy.recordingStarted()
        Thread.sleep(forTimeInterval: 0.8)
        policy.flush()
        record(s, "no play between two dictations", player.commands("play").isEmpty)
        record(s, "no second pause", player.commands("pause").count == 1, "pause \(player.commands("pause").count)")
        record(s, "player still paused", !outputting().contains { $0.pid == player.pid })
        policy.recordingEnded()
        let started = waitOutput(pid: player.pid, playing: true, timeout: 2)
        policy.flush()
        record(s, "resumed once after the last dictation", player.commands("play").count == 1 && started != nil,
               "play \(player.commands("play").count)")
    }

    static func scenarioQuit() throws {
        let s = "F-quit-while-paused"
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: false)
        defer { player.quit() }
        let policy = makePolicy(diagnostics: Diagnostics(directory: nil))
        policy.recordingStarted()
        _ = waitOutput(pid: player.pid, playing: false, timeout: 1.5)
        policy.flush()
        let t0 = Date().timeIntervalSince1970
        policy.shutdown()
        let took = Date().timeIntervalSince1970 - t0
        let resumed = outputting().contains { $0.pid == player.pid }
        record(s, "shutdown() resumed before returning", resumed && player.commands("play").count == 1, "took \(ms(took))")
    }

    /// A call app keeps its output stream open the whole time and cannot be paused. It must
    /// stay untouched, and it must not stop the player from resuming.
    static func scenarioBackgroundStream() throws {
        let s = "G-background-stream"
        let background = try Player(playerPath: Self.playerPath, logURL: logURL(s + "-background"),
                                    startPaused: false, background: true)
        defer { background.quit() }
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: false)
        defer { player.quit() }
        let diagnostics = Diagnostics(directory: nil)
        let policy = makePolicy(diagnostics: diagnostics)
        record(s, "both streams are outputting", outputting().contains { $0.pid == player.pid }
               && outputting().contains { $0.pid == background.pid })

        let t0 = Date().timeIntervalSince1970
        policy.recordingStarted()
        let stopped = waitOutput(pid: player.pid, playing: false, timeout: 1.5)
        policy.flush()
        record(s, "the player was paused", stopped != nil && player.commands("pause").count == 1,
               stopped.map { ms($0 - t0) } ?? "still outputting")
        record(s, "the background stream kept outputting", outputting().contains { $0.pid == background.pid })
        Thread.sleep(forTimeInterval: 0.8)   // a dictation, long enough for the 500 ms watch
        policy.recordingEnded()
        let started = waitOutput(pid: player.pid, playing: true, timeout: 3)
        policy.flush()
        record(s, "the player resumed although the background stream never stopped",
               started != nil && player.commands("play").count == 1, "play \(player.commands("play").count)")
        record(s, "the background stream was never touched", outputting().contains { $0.pid == background.pid })
        note("diagnostics: " + diagnostics.entries().map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: " | "))
    }

    /// Held player, then the user plays it and pauses it again before the dictation ends.
    /// The end looks quiet, but the 500 ms watch saw it, so nothing resumes.
    static func scenarioUserPlaysThenPausesAgain() throws {
        let s = "I-user-plays-then-pauses-again-mid-dictation"
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: false)
        defer { player.quit() }
        let policy = makePolicy(diagnostics: Diagnostics(directory: nil))
        policy.recordingStarted()
        _ = waitOutput(pid: player.pid, playing: false, timeout: 1.5)
        policy.flush()
        player.send("play")
        _ = waitOutput(pid: player.pid, playing: true, timeout: 1)
        Thread.sleep(forTimeInterval: 1.2)   // the watch runs every 500 ms
        player.send("pause")
        _ = waitOutput(pid: player.pid, playing: false, timeout: 1)
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 1.0)
        policy.flush()
        record(s, "no play command from us", player.commands("play").isEmpty, "play commands: \(player.commands("play").count)")
        record(s, "player left paused as the user left it", !outputting().contains { $0.pid == player.pid })
    }

    /// While the dictation ran, another app became the Now Playing app. Play then reaches that
    /// app; the policy must pause it again rather than leave an unintended app playing. What
    /// macOS does with the second app is observed, not assumed, so both outcomes are checked.
    static func scenarioPlayReachesAnotherApp() throws {
        let s = "J-play-reaches-a-different-app"
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: false)
        defer { player.quit() }
        let policy = makePolicy(diagnostics: Diagnostics(directory: nil))
        policy.recordingStarted()
        _ = waitOutput(pid: player.pid, playing: false, timeout: 1.5)
        policy.flush()
        let other = try Player(playerPath: Self.playerPath, logURL: logURL(s + "-other"), startPaused: true)
        defer { other.quit() }
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 2.0)
        policy.flush()
        let otherPlays = other.commands("play").count
        if otherPlays > 0 {
            record(s, "Play reached the other app, which was paused again", other.commands("pause").count >= 1
                   && !outputting().contains { $0.pid == other.pid }, "other: play \(otherPlays), pause \(other.commands("pause").count)")
            record(s, "nothing unintended is left playing", outputting().isEmpty)
        } else {
            record(s, "macOS kept the first app as Now Playing, so it resumed", player.commands("play").count == 1
                   && outputting().contains { $0.pid == player.pid }, "first app play \(player.commands("play").count)")
            note("note: the second app never became Now Playing here, so the undo path is covered by the unit tests only")
        }
    }

    /// An alert sound at the press: a second silent process outputs for `milliseconds` and
    /// stops by itself, while the real player sits paused as the Now Playing app. Whatever the
    /// policy does about the blip, it must never send Play: a Play would start the paused player.
    ///
    /// `informational`: a blip whose output lasts between the press look (150 ms) and the press
    /// look plus the stop window (about 250 ms) can look like a player that obeyed Pause. That
    /// gap is known and documented; the run records what happened instead of failing on it.
    static func scenarioAlertBlip(id: String, milliseconds: Int, informational: Bool = false) throws {
        let s = "\(id)-alert-blip-\(milliseconds)ms\(informational ? "-known-gap" : "")"
        // The player has really played and was then paused by the user, so it is the Now Playing
        // app. A wrongly sent Play would reach it (logged, silent) rather than launch Music.
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: false)
        defer { player.quit() }
        player.send("pause")
        _ = waitOutput(pid: player.pid, playing: false, timeout: 2)
        Thread.sleep(forTimeInterval: 0.4)
        let blip = try Player(playerPath: Self.playerPath, logURL: logURL(s + "-blip"), startPaused: true, background: true)
        defer { blip.quit() }
        let diagnostics = Diagnostics(directory: nil)
        let policy = makePolicy(diagnostics: diagnostics)

        blip.send("blip \(milliseconds)")
        guard waitOutput(pid: blip.pid, playing: true, timeout: 1) != nil else {
            record(s, "the blip started outputting", false)
            return
        }
        policy.recordingStarted()   // the press, as soon as the alert is audible
        Thread.sleep(forTimeInterval: 0.8)
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 1.2)
        policy.flush()
        record(s, "the blip is over and the player is still paused",
               !outputting().contains { $0.pid == blip.pid } && !outputting().contains { $0.pid == player.pid })
        let commands = player.allCommands().map(\.text).joined(separator: ", ")
        if informational {
            note("KNOWN GAP \(s): player commands [\(commands)]; a Play here is undone by the post-Play check")
            return
        }
        record(s, "no play was ever sent to the paused player", player.commands("play").isEmpty,
               "player commands: \(commands)")
        if milliseconds < 150 {
            record(s, "a blip shorter than the press look sends nothing at all", player.allCommands().isEmpty)
        }
        record(s, "Music was not launched by the run", !isRunning("com.apple.Music") || musicWasRunningBefore,
               "a stray Play with no Now Playing app launches Music")
        note("diagnostics: " + diagnostics.entries().map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: " | "))
    }

    /// A Chromium-style tab: the app reports paused at once, but its audio process keeps rendering
    /// silence for 3 s (10 s in Chromium). Now Playing sees through that; the audio list alone cannot
    /// (a process without a Chromium bundle id is not given the long window, so this one is skipped
    /// in the audio-only run).
    static func scenarioAudioTail() throws {
        let s = "N-chromium-style-audio-tail"
        guard !audioOnly else {
            note("skipped in the audio-only run: the test player has no Chromium bundle id")
            return
        }
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: false, tail: 3000)
        defer { player.quit() }
        let diagnostics = Diagnostics(directory: nil)
        let policy = makePolicy(diagnostics: diagnostics)
        let t0 = Date().timeIntervalSince1970
        policy.recordingStarted()
        Thread.sleep(forTimeInterval: 0.5)
        record(s, "paused at once although the audio process is still outputting",
               player.commands("pause").count == 1 && outputting().contains { $0.pid == player.pid },
               player.commands("pause").first.map { ms($0.time - t0) } ?? "no pause")
        let t1 = Date().timeIntervalSince1970
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 1.5)
        policy.flush()
        let play = player.commands("play").first
        record(s, "resumed right after the end, while the tail was still running", play != nil && play!.time - t1 < 1.5,
               play.map { ms($0.time - t1) } ?? "no play")
        record(s, "one pause and one play", player.commands("pause").count == 1 && player.commands("play").count == 1)
        note("diagnostics: " + diagnostics.entries().map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: " | "))
    }

    /// Ten dictations in a row on one player: the numbers the report quotes.
    static func scenarioLatency() throws {
        let s = "H-latency-x10"
        let player = try Player(playerPath: Self.playerPath, logURL: logURL(s), startPaused: false)
        defer { player.quit() }
        let diagnostics = Diagnostics(directory: nil)
        let policy = makePolicy(diagnostics: diagnostics)
        var pauseCmd: [Double] = [], pauseOut: [Double] = [], playCmd: [Double] = [], playOut: [Double] = []
        for round in 1...10 {
            let before = (player.commands("pause").count, player.commands("play").count)
            let t0 = Date().timeIntervalSince1970
            policy.recordingStarted()
            let stopped = waitOutput(pid: player.pid, playing: false, timeout: 1.5)
            policy.flush()
            if let command = player.commands("pause").dropFirst(before.0).first { pauseCmd.append(command.time - t0) }
            if let stopped { pauseOut.append(stopped - t0) }
            Thread.sleep(forTimeInterval: 0.25)
            let t1 = Date().timeIntervalSince1970
            policy.recordingEnded()
            let started = waitOutput(pid: player.pid, playing: true, timeout: 2)
            policy.flush()
            if let command = player.commands("play").dropFirst(before.1).first { playCmd.append(command.time - t1) }
            if let started { playOut.append(started - t1) }
            note("round \(round): pause cmd \(pauseCmd.last.map(ms) ?? "-"), stopped \(pauseOut.last.map(ms) ?? "-"), play cmd \(playCmd.last.map(ms) ?? "-"), resumed \(playOut.last.map(ms) ?? "-")")
            Thread.sleep(forTimeInterval: 0.3)
        }
        note("diagnostics: " + diagnostics.entries().map { "[\($0.level.rawValue)] \($0.message)" }.joined(separator: " | "))
        func stats(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "no data" }
            let sorted = values.sorted()
            return "min \(ms(sorted.first!)), median \(ms(sorted[sorted.count / 2])), max \(ms(sorted.last!)) (n=\(values.count))"
        }
        note("pause command   : \(stats(pauseCmd))")
        note("output stopped  : \(stats(pauseOut))")
        note("play command    : \(stats(playCmd))")
        note("output resumed  : \(stats(playOut))")
        record(s, "all 10 rounds paused and resumed", pauseCmd.count == 10 && playOut.count == 10,
               "pause \(pauseCmd.count)/10, resumed \(playOut.count)/10")
        record(s, "worst pause command under 500 ms", (pauseCmd.max() ?? 9) < 0.5, stats(pauseCmd))
    }

    // MARK: - Plumbing

    static var playerPath: String { CommandLine.arguments[1] }
    static var outDirectory: URL { URL(fileURLWithPath: CommandLine.arguments[2]) }
    static func logURL(_ scenario: String) -> URL { outDirectory.appendingPathComponent("player-\(scenario).log") }

    static func write(_ outDir: URL, skipped: [MediaPlayerID]) {
        var text = "# media-pause E2E, \(ISO8601DateFormatter().string(from: Date()))\n"
        text += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        text += "detector: \(audioOnly ? "audio process list only (UV_E2E_AUDIO_ONLY=1)" : "Now Playing through perl, audio list as fallback")\n\n"
        if !skipped.isEmpty {
            text += "SKIPPED: \(skipped.map(\.description).joined(separator: ", ")) was outputting audio, so no command was sent.\n\n"
        }
        text += "## Timeline\n" + timeline.joined(separator: "\n") + "\n\n## Checks\n"
        for check in checks {
            text += "\(check.passed ? "PASS" : "FAIL")  \(check.scenario): \(check.name) \(check.detail)\n"
        }
        text += "\n\(checks.filter(\.passed).count) of \(checks.count) checks passed\n"
        try? text.write(to: outDir.appendingPathComponent("harness.log"), atomically: true, encoding: .utf8)
    }
}
