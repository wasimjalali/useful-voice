import Foundation

/// A process that is making sound. This is the "player identity" the policy remembers.
public struct MediaPlayerID: Hashable, Sendable, CustomStringConvertible {
    public let pid: Int32
    public let bundleID: String?

    public init(pid: Int32, bundleID: String?) {
        self.pid = pid
        self.bundleID = bundleID
    }

    public var description: String {
        guard let bundleID, !bundleID.isEmpty else { return "pid \(pid)" }
        return "\(bundleID) (\(pid))"
    }

    /// The same process, or another process of the same app (a browser restarts its audio
    /// helper under a new pid).
    func isSameApp(as other: MediaPlayerID) -> Bool {
        if pid == other.pid { return true }
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleID == other.bundleID
    }
}

public enum MediaEffectsError: Error, LocalizedError, Equatable {
    /// This macOS has no Core Audio process list (before 14.2). The feature turns itself off.
    case processListUnsupported
    case mediaRemoteUnavailable(String)
    case commandRefused(String)
    case coreAudio(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .processListUnsupported:
            return "This macOS has no audio process list (needs 14.2), so pausing media is off"
        case .mediaRemoteUnavailable(let detail): return "MediaRemote is unavailable: \(detail)"
        case .commandRefused(let name): return "The system refused the \(name) command"
        case .coreAudio(let what, let status): return "Core Audio \(what) failed (\(status))"
        }
    }
}

/// Everything the policy does to the outside world, so the rules can be tested without
/// a speaker. `SystemMediaEffects` is the real one.
///
/// There is deliberately no Play/Pause key: it toggles, and it can start a paused Now
/// Playing app while another process keeps an output stream open.
public protocol MediaEffects: AnyObject, Sendable {
    /// Processes that are outputting audio right now, never this app's own or a system
    /// sound service. Throws `processListUnsupported` on a macOS without the process list.
    func outputtingPlayers() throws -> [MediaPlayerID]
    /// Whether the process is still running.
    func isAlive(_ player: MediaPlayerID) -> Bool
    /// The system Pause and Play commands (MediaRemote). Pause is idempotent on a player
    /// that is already paused. They go to the app macOS treats as Now Playing, so the
    /// caller checks their effect in the audio output.
    func sendPause() throws
    func sendPlay() throws
    func sleep(_ seconds: TimeInterval)
}

/// Decides which processes count as "media playing". A process that only plays a system
/// alert, a chime or a voice prompt is not a player: pausing "it" would be pointless and,
/// worse, the later resume would start whatever was playing before.
public enum MediaPlayerFilter {
    /// Bundle id prefixes of system services that make short sounds, not media.
    static let systemPrefixes = [
        "com.apple.audio.", "com.apple.CoreSpeech", "com.apple.assistantd",
        "com.apple.Siri", "com.apple.siri", "com.apple.accessibility",
        "com.apple.universalaccessd", "com.apple.controlcenter", "com.apple.mediaremoted",
        "com.apple.avconferenced", "com.apple.TelephonyUtilities", "com.apple.cloudpaird",
        "com.apple.cmio.", "com.apple.VoiceOver", "com.apple.speech", "com.apple.coreaudiod",
        "com.apple.audiomxd", "systemsoundserverd",
    ]
    /// This app, in every identity it has shipped under.
    static let ownBundleIDs: Set<String> = ["ai.useful.voice", "ai.karko.sadaa"]

    public static func isMedia(pid: Int32, bundleID: String?, ownPID: Int32) -> Bool {
        if pid == ownPID { return false }
        guard let bundleID, !bundleID.isEmpty else { return true }
        if ownBundleIDs.contains(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }) { return false }
        return !systemPrefixes.contains { bundleID.hasPrefix($0) }
    }
}

/// Pause media while dictating.
///
/// When a recording starts, whatever is playing is paused. When the recording ends, for
/// any reason, exactly what was paused is resumed, and only if nothing changed in between.
/// Nothing here may delay a recording or surface as a dictation error: every call returns
/// at once and the work runs on one serial queue.
///
/// The rules, in order of how easily they break:
/// 1. Only MediaRemote Pause and Play are used. Both go to the Now Playing app; Pause is
///    safe on a paused player, and what they did is always checked in the audio output.
/// 2. Pause: the players are those outputting in two looks 40 ms apart (P0). After the
///    command, `held` is the part of P0 that stopped and `background` the part that kept
///    going (a call app, say). A background stream never blocks the resume.
/// 3. Resume only when `held` is non-empty and still alive, nothing in `held` is outputting
///    (so the user did not press play), nothing new is outputting beyond `background`
///    (so the user did not start something else), and during the dictation none of that
///    happened and was undone (checked every 500 ms).
/// 4. After Play, if a different app started instead, it is paused again.
/// 5. A new recording within the grace after an end keeps the media paused, with no
///    resume in between and no second pause.
/// 6. The setting is read at every start; turning it off mid-dictation does not strand a
///    paused player.
public final class MediaPausePolicy: @unchecked Sendable {
    public struct Timing: Sendable {
        /// Between the two looks at what is playing, so a short alert sound is not
        /// mistaken for media.
        public var confirmDelay: TimeInterval = 0.04
        /// How long an end waits before resuming. A new recording inside this window keeps
        /// the media paused (same as Windows).
        public var resumeGrace: TimeInterval = 0.4
        /// How long to wait for a command to show in the audio output.
        public var settleTimeout: TimeInterval = 0.6
        public var pollInterval: TimeInterval = 0.02
        /// How often to look for the user touching a paused player during a dictation.
        public var watchInterval: TimeInterval = 0.5
        /// How long a pause that is still waiting for its effect keeps waiting once the
        /// app is quitting.
        public var quitSettleTimeout: TimeInterval = 0.3
        /// The longest a quit waits for the resume.
        public var shutdownBudget: TimeInterval = 1.5

        public init() {}
    }

    private struct Hold {
        var held: Set<MediaPlayerID>
        var background: Set<MediaPlayerID>
        /// The user played the paused player, or started something else, during the dictation.
        var touched = false
    }

    private let effects: MediaEffects
    private let isEnabled: () -> Bool
    private let diagnostics: Diagnostics
    private let timing: Timing
    private let queue = DispatchQueue(label: "ai.useful.voice.media-pause", qos: .userInitiated)

    // Written from any thread, under the lock: whether a recording is live and which one.
    private let lock = NSLock()
    private var recording = false
    private var epoch = 0
    private var shuttingDown = false

    // Only touched on the queue.
    private var hold: Hold?
    private var watcher: DispatchSourceTimer?
    private var unsupported = false
    private var logged: Set<String> = []

    public init(effects: MediaEffects,
                isEnabled: @escaping () -> Bool,
                diagnostics: Diagnostics = .shared,
                timing: Timing = Timing()) {
        self.effects = effects
        self.isEnabled = isEnabled
        self.diagnostics = diagnostics
        self.timing = timing
    }

    // MARK: - Entry points (any thread, never block)

    /// A recording has started (hotkey or window mic).
    public func recordingStarted() {
        let mine: Int = lock.withLock {
            recording = true
            epoch += 1
            return epoch
        }
        queue.async { [self] in pauseIfPlaying(epoch: mine) }
    }

    /// The recording ended: stop, auto-stop, silence limit, maximum length, cancel,
    /// recorder error or a start that failed. Safe to call more than once.
    public func recordingEnded() {
        let mine: Int? = lock.withLock {
            guard recording else { return nil }
            recording = false
            return epoch
        }
        guard let mine else { return }
        queue.asyncAfter(deadline: .now() + timing.resumeGrace) { [self] in
            resume(afterEpoch: mine, shuttingDown: false)
        }
    }

    /// The app is quitting: resume now, waiting at most `shutdownBudget`. A pause still
    /// waiting for its effect is cut short rather than waited out.
    public func shutdown() {
        lock.withLock {
            recording = false
            shuttingDown = true
        }
        let finished = DispatchSemaphore(value: 0)
        queue.async { [self] in
            resume(afterEpoch: nil, shuttingDown: true)
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + timing.shutdownBudget)
    }

    /// Waits for queued work. For tests and the harness.
    public func flush() {
        queue.sync {}
    }

    // MARK: - Pause

    private func pauseIfPlaying(epoch mine: Int) {
        guard !unsupported, isEnabled() else { return }
        // Already holding it: a back-to-back dictation. Keep it paused, pause nothing twice.
        guard hold == nil else { return }
        guard isLive(mine) else { return }
        do {
            let first = Set(try effects.outputtingPlayers())
            guard !first.isEmpty else { return }
            effects.sleep(timing.confirmDelay)
            let p0 = first.intersection(Set(try effects.outputtingPlayers()))
            guard !p0.isEmpty, isLive(mine) else { return }

            try effects.sendPause()
            let stopped = try waitForStop(of: p0)
            guard !stopped.isEmpty else {
                diagnostics.warning("media", "Could not pause \(describe(p0)): it kept playing after the pause command")
                return
            }
            hold = Hold(held: stopped, background: p0.subtracting(stopped))
            startWatching()
            var message = "Paused \(describe(stopped)) for the dictation"
            if !hold!.background.isEmpty { message += "; \(describe(hold!.background)) keeps playing and is left alone" }
            diagnostics.info("media", message)
        } catch {
            handle(error, context: "Pausing media failed")
        }
    }

    /// The part of `players` that stopped, as soon as any did, or empty after the timeout.
    /// A quit shortens the wait to `quitSettleTimeout`: the command is already out, and the
    /// player usually stops within 100 ms, so it can still be found and resumed.
    private func waitForStop(of players: Set<MediaPlayerID>) throws -> Set<MediaPlayerID> {
        var waited: TimeInterval = 0
        while true {
            let stopped = players.subtracting(Set(try effects.outputtingPlayers()))
            if !stopped.isEmpty { return stopped }
            let limit = lock.withLock({ shuttingDown }) ? min(timing.settleTimeout, timing.quitSettleTimeout) : timing.settleTimeout
            if waited >= limit { return [] }
            effects.sleep(timing.pollInterval)
            waited += timing.pollInterval
        }
    }

    // MARK: - Watching a dictation for the user touching the player

    private func startWatching() {
        guard watcher == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timing.watchInterval, repeating: timing.watchInterval)
        timer.setEventHandler { [weak self] in self?.watchTick() }
        timer.resume()
        watcher = timer
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func watchTick() {
        guard var current = hold else { return stopWatching() }
        guard !current.touched else { return }
        // A failed look is not "touched"; the gate at the end looks again.
        guard let playing = try? effects.outputtingPlayers() else { return }
        if Self.userActivity(in: playing, hold: current) {
            current.touched = true
            hold = current
        }
    }

    /// Something other than the background streams is outputting: the paused player (the
    /// user pressed play) or a new one.
    private static func userActivity(in playing: [MediaPlayerID], hold: Hold) -> Bool {
        playing.contains { player in
            !hold.background.contains { $0.isSameApp(as: player) }
        }
    }

    // MARK: - Resume

    private func resume(afterEpoch ended: Int?, shuttingDown quitting: Bool) {
        if let ended {
            // A newer recording started while this resume was waiting: stay paused.
            let stillTheEnd = lock.withLock { !recording && epoch == ended }
            guard stillTheEnd else { return }
        }
        stopWatching()
        guard let current = hold else { return }
        hold = nil
        do {
            guard !current.touched else {
                diagnostics.info("media", "Not resuming: the player was used during the dictation")
                return
            }
            let alive = current.held.filter { effects.isAlive($0) }
            guard !alive.isEmpty else {
                diagnostics.info("media", "Not resuming: \(describe(current.held)) is gone")
                return
            }
            let playingNow = try effects.outputtingPlayers()
            guard !Self.userActivity(in: playingNow, hold: current) else {
                diagnostics.info("media", "Not resuming: \(describe(Set(playingNow))) is playing")
                return
            }
            try effects.sendPlay()
            try confirmResume(alive: alive, background: current.background)
        } catch {
            handle(error, context: "Resuming media failed")
        }
    }

    /// After Play: done when the paused player outputs; if a different app started
    /// instead, pause it again.
    private func confirmResume(alive: Set<MediaPlayerID>, background: Set<MediaPlayerID>) throws {
        var waited: TimeInterval = 0
        while true {
            let playing = try effects.outputtingPlayers()
            if playing.contains(where: { player in alive.contains { $0.isSameApp(as: player) } }) {
                diagnostics.info("media", "Resumed \(describe(alive))")
                return
            }
            let strangers = playing.filter { player in !background.contains { $0.isSameApp(as: player) } }
            if !strangers.isEmpty {
                try effects.sendPause()
                diagnostics.warning("media", "Play reached \(describe(Set(strangers))) instead of \(describe(alive)); paused it again")
                return
            }
            if waited >= timing.settleTimeout {
                diagnostics.warning("media", "Could not resume \(describe(alive))")
                return
            }
            effects.sleep(timing.pollInterval)
            waited += timing.pollInterval
        }
    }

    // MARK: - Helpers

    private func isLive(_ mine: Int) -> Bool {
        lock.withLock { recording && epoch == mine }
    }

    /// A macOS without the process list turns the feature off for good, with one log line.
    /// Anything else is logged once per kind of failure, so a refusing system does not
    /// fill the log with one line per dictation.
    private func handle(_ error: Error, context: String) {
        if let media = error as? MediaEffectsError {
            switch media {
            case .processListUnsupported:
                unsupported = true
                logOnce("unsupported", error)
                return
            case .mediaRemoteUnavailable:
                unsupported = true
                logOnce("mediaremote", error)
                return
            case .commandRefused(let name):
                logOnce("refused-\(name)", error)
                return
            case .coreAudio:
                break
            }
        }
        diagnostics.failure("media", error, context: context)
    }

    private func logOnce(_ key: String, _ error: Error) {
        guard logged.insert(key).inserted else { return }
        diagnostics.warning("media", "\(error.localizedDescription). Media is left alone")
    }

    private func describe(_ players: Set<MediaPlayerID>) -> String {
        players.map(\.description).sorted().joined(separator: ", ")
    }
}
