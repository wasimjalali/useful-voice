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
}

/// Everything the policy does to the outside world, so the rules can be tested without
/// a speaker. `SystemMediaEffects` is the real one.
public protocol MediaEffects: AnyObject, Sendable {
    /// Processes that are outputting audio right now, never this app's own.
    func outputtingPlayers() throws -> [MediaPlayerID]
    /// Whether the process is still running.
    func isAlive(_ player: MediaPlayerID) -> Bool
    /// The system Pause and Play commands (MediaRemote). They go to the app macOS
    /// treats as Now Playing, so the caller checks the effect.
    func sendPause() throws
    func sendPlay() throws
    /// The Play/Pause media key. It toggles, so the caller only uses it after
    /// checking what is playing.
    func sendPlayPauseKey() throws
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
/// any reason, exactly what was paused is resumed, and only if it is still paused.
/// Nothing here may delay a recording or surface as a dictation error: every call returns
/// at once and the work runs on one serial queue.
///
/// The rules, in order of how easily they break:
/// 1. Never start playback that was not playing before the dictation. Resume happens only
///    for what this policy paused, only while the system is silent (a different player,
///    or the same one restarted by the user, means hands off), and only if the process
///    is still alive.
/// 2. A new recording that starts while a resume is waiting cancels it. Dictations back to
///    back keep the media paused throughout and never pause twice.
/// 3. The setting is read at every start. Turning it off mid-dictation does not strand a
///    paused player.
public final class MediaPausePolicy: @unchecked Sendable {
    public struct Timing: Sendable {
        /// Between two looks at what is playing, so a short alert sound is not mistaken
        /// for media.
        public var confirmDelay: TimeInterval = 0.04
        /// How long a stop waits before resuming. A new recording inside this window
        /// keeps the media paused. Short enough to feel immediate.
        public var resumeGrace: TimeInterval = 0.12
        /// How long to wait for a command to show in the audio output.
        public var settleTimeout: TimeInterval = 0.6
        public var pollInterval: TimeInterval = 0.02

        public init() {}
    }

    private let effects: MediaEffects
    private let isEnabled: @Sendable () -> Bool
    private let diagnostics: Diagnostics
    private let timing: Timing
    private let queue = DispatchQueue(label: "ai.useful.voice.media-pause", qos: .userInitiated)

    // Written from any thread, under the lock: whether a recording is live and which one.
    private let lock = NSLock()
    private var recording = false
    private var epoch = 0

    // Only touched on the queue: what this policy paused.
    private var held: Set<MediaPlayerID> = []

    public init(effects: MediaEffects,
                isEnabled: @escaping @Sendable () -> Bool,
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
            resume(afterEpoch: mine)
        }
    }

    /// The app is quitting: resume now and wait for it, within the command timeouts.
    public func shutdown() {
        lock.withLock { recording = false }
        queue.sync { resume(afterEpoch: nil) }
    }

    /// Waits for queued work. For tests and the harness.
    public func flush() {
        queue.sync {}
    }

    // MARK: - Pause

    private func pauseIfPlaying(epoch mine: Int) {
        guard isEnabled() else { return }
        // Already holding it: a back-to-back dictation. Keep it paused, pause nothing twice.
        guard held.isEmpty else { return }
        guard isLive(mine) else { return }
        do {
            let first = Set(try effects.outputtingPlayers())
            guard !first.isEmpty else { return }
            effects.sleep(timing.confirmDelay)
            let playing = first.intersection(Set(try effects.outputtingPlayers()))
            guard !playing.isEmpty, isLive(mine) else { return }

            try effects.sendPause()
            var stopped = try waitForStop(of: playing)
            if stopped.isEmpty {
                // The system command did nothing. The key toggles, so it goes out only
                // while the audio is still playing.
                let stillPlaying = Set(try effects.outputtingPlayers()).intersection(playing)
                guard !stillPlaying.isEmpty else { return }
                try effects.sendPlayPauseKey()
                stopped = try waitForStop(of: playing)
            }
            guard !stopped.isEmpty else {
                diagnostics.warning("media", "Could not pause \(describe(playing)): it kept playing after the pause command and the media key")
                return
            }
            held = stopped
            diagnostics.info("media", "Paused \(describe(stopped)) for the dictation")
        } catch {
            diagnostics.failure("media", error, context: "Pausing media failed")
        }
    }

    private func waitForStop(of players: Set<MediaPlayerID>) throws -> Set<MediaPlayerID> {
        var waited: TimeInterval = 0
        while true {
            let outputting = Set(try effects.outputtingPlayers())
            let stopped = players.subtracting(outputting)
            if !stopped.isEmpty { return stopped }
            if waited >= timing.settleTimeout { return [] }
            effects.sleep(timing.pollInterval)
            waited += timing.pollInterval
        }
    }

    // MARK: - Resume

    private func resume(afterEpoch ended: Int?) {
        if let ended {
            // A newer recording started while this resume was waiting: stay paused.
            let stillTheEnd = lock.withLock { !recording && epoch == ended }
            guard stillTheEnd else { return }
        }
        guard !held.isEmpty else { return }
        let players = held
        held = []
        do {
            let alive = players.filter { effects.isAlive($0) }
            guard !alive.isEmpty else {
                diagnostics.info("media", "Not resuming: \(describe(players)) is gone")
                return
            }
            let playingNow = try effects.outputtingPlayers()
            guard playingNow.isEmpty else {
                // The user started it again, or started something else. Both mean leave it.
                diagnostics.info("media", "Not resuming: \(describe(Set(playingNow))) is playing")
                return
            }
            try effects.sendPlay()
            if try waitForStart(of: alive) {
                diagnostics.info("media", "Resumed \(describe(alive))")
                return
            }
            // The key toggles: only safe while nothing at all is playing.
            guard try effects.outputtingPlayers().isEmpty else { return }
            try effects.sendPlayPauseKey()
            if try waitForStart(of: alive) {
                diagnostics.info("media", "Resumed \(describe(alive)) with the media key")
            } else {
                diagnostics.warning("media", "Could not resume \(describe(alive))")
            }
        } catch {
            diagnostics.failure("media", error, context: "Resuming media failed")
        }
    }

    private func waitForStart(of players: Set<MediaPlayerID>) throws -> Bool {
        var waited: TimeInterval = 0
        while true {
            if !players.isDisjoint(with: Set(try effects.outputtingPlayers())) { return true }
            if waited >= timing.settleTimeout { return false }
            effects.sleep(timing.pollInterval)
            waited += timing.pollInterval
        }
    }

    // MARK: - Helpers

    private func isLive(_ mine: Int) -> Bool {
        lock.withLock { recording && epoch == mine }
    }

    private func describe(_ players: Set<MediaPlayerID>) -> String {
        players.map(\.description).sorted().joined(separator: ", ")
    }
}
