import Foundation

/// A process that is making sound. This is the "player identity" the audio fallback remembers.
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

    /// The same process, or another process of the same app. Used only to recognise the paused
    /// player coming back after Play (a browser relaunches its audio helper under a new pid);
    /// everything else is matched by pid.
    func isSameApp(as other: MediaPlayerID) -> Bool {
        if pid == other.pid { return true }
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleID == other.bundleID
    }
}

/// What the system's Now Playing says: the app that owns the media controls and whether it
/// plays. `pid` 0 means no app.
public struct NowPlayingState: Equatable, Sendable, CustomStringConvertible {
    public let isPlaying: Bool
    public let pid: Int32
    public let bundleID: String?

    public init(isPlaying: Bool, pid: Int32, bundleID: String?) {
        self.isPlaying = isPlaying
        self.pid = pid
        self.bundleID = bundleID
    }

    public var hasApp: Bool { pid > 0 }

    /// The same app: pid and bundle id both.
    func isSameApp(as other: NowPlayingState) -> Bool {
        pid == other.pid && bundleID == other.bundleID
    }

    public var description: String {
        guard hasApp else { return "no Now Playing app" }
        return "\(bundleID ?? "pid \(pid)") (\(pid), \(isPlaying ? "playing" : "paused"))"
    }
}

public enum MediaEffectsError: Error, LocalizedError, Equatable {
    /// This macOS has no Core Audio process list (before 14.2): the audio fallback is off.
    case processListUnsupported
    case mediaRemoteUnavailable(String)
    case commandRefused(String)
    case coreAudio(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .processListUnsupported:
            return "This macOS has no audio process list (needs 14.2), so audio detection is off"
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
    /// The system's Now Playing state, read through Apple's own perl (MediaRemote answers
    /// third-party processes with "nothing playing" since macOS 15.4). Nil when it cannot be
    /// read (no helper, perl missing, a timeout): the policy then uses the audio process list.
    func nowPlaying() -> NowPlayingState?
    /// Processes that are outputting audio right now, never this app's own or a system
    /// sound service. Throws `processListUnsupported` on a macOS without the process list.
    func outputtingPlayers() throws -> [MediaPlayerID]
    /// Whether the process is still running.
    func isAlive(_ player: MediaPlayerID) -> Bool
    /// The system Pause and Play commands (MediaRemote). Pause is idempotent on a player
    /// that is already paused. They go to the app macOS treats as Now Playing, so the
    /// caller checks their effect.
    func sendPause() throws
    func sendPlay() throws
}

public extension MediaEffects {
    func nowPlaying() -> NowPlayingState? { nil }
}

/// Decides which processes count as "media playing" in the audio fallback, and how long each
/// kind takes to go quiet after a Pause.
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
    /// Players whose output measurably outlasts a Pause by more than 100 ms (a fade, a buffer).
    static let slowToStop: Set<String> = ["com.apple.Music", "com.spotify.client", "com.apple.WebKit.GPU"]

    public static func isMedia(pid: Int32, bundleID: String?, ownPID: Int32) -> Bool {
        if pid == ownPID { return false }
        guard let bundleID, !bundleID.isEmpty else { return true }
        if ownBundleIDs.contains(where: { bundleID == $0 || bundleID.hasPrefix($0 + ".") }) { return false }
        return !systemPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// A Chromium or Electron helper process (Chrome, Vivaldi, Edge, Brave, Arc, Electron apps):
    /// "...helper", "... Helper (Renderer)", "company.thebrowser.*". Chromium's audio mixer
    /// keeps rendering silence for 10 s after a pause, so the process looks like it plays on.
    public static func isBrowserHelper(bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleID.lowercased().hasSuffix(".helper") || bundleID.contains("Helper")
            || bundleID.hasPrefix("company.thebrowser.")
    }

    public static func isSlowToStop(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return slowToStop.contains(bundleID)
    }
}

/// Pause media while dictating.
///
/// When a recording starts, whatever is playing is paused. When the recording ends, for
/// any reason, exactly what was paused is resumed, and only if nothing changed in between.
/// Nothing here may delay a recording or surface as a dictation error: every call returns
/// at once and the work runs on one serial queue.
///
/// Two ways of knowing what plays:
///
/// **Now Playing (primary).** `effects.nowPlaying()` reads the system's Now Playing app and its
/// playing state. If it plays, kMRPause goes out and the policy waits for it to report paused;
/// that app (pid and bundle id) is remembered. At the end it resumes only if Now Playing is still
/// that app, paused, and the watch (every 500 ms) never saw anything play or Now Playing change
/// app. A Now Playing that vanished is never resumed: Play with no Now Playing app launches
/// Music. This is immune to audio tails (Chromium keeps rendering silence for 10 s after a
/// pause) and to alert sounds, which never become Now Playing.
///
/// **Audio process list (fallback, when Now Playing cannot be read).** What plays is what
/// Core Audio says is outputting. See the rules below.
///
/// Audio fallback rules:
/// 1. Short sounds are not media. A process counts only if it outputs in two looks 150 ms
///    apart (P0), and it is held only if it stops soon after the Pause command: within 100 ms,
///    300 ms for Music, Spotify and WebKit's GPU process, and up to 10.5 s for Chromium and
///    Electron helpers (their mixer renders silence for 10 s). A pause that cannot be observed
///    is not remembered: never risk playing something unknown.
/// 2. A browser helper that has not stopped yet is `pending`, not blocking: the watch promotes
///    it to `held` when it goes quiet, and the end waits for that (without blocking the queue)
///    until its deadline. Until then its silence tail is never "touched".
/// 3. `held` is the part of P0 that stopped, `background` the part that kept going (a call
///    app, say). Both are matched by pid. A background stream never blocks the resume.
/// 4. A stranger is a process that is neither held, pending nor background. Strangers count
///    only when seen twice: on two watch ticks, or in two looks 40 ms apart at the end and
///    after Play.
/// 5. Resume only when `held` is alive, no held process is outputting (the user did not press
///    play), no persistent stranger is outputting and the watch saw neither.
/// 6. After Play, a persistent stranger with no held process outputting means Play reached
///    another app: it is paused again. The player just resumed is never paused.
///
/// Both modes: a new recording within the grace after an end keeps the media paused, with no
/// resume in between; the setting is read at every start; turning it off mid-dictation does
/// not strand a paused player.
public final class MediaPausePolicy: @unchecked Sendable {
    public struct Timing: Sendable {
        /// Between the two looks at the press: a process must be outputting in both.
        public var pressConfirmDelay: TimeInterval = 0.15
        /// Between the two looks that make a stranger count, at the end and after Play.
        public var strangerGap: TimeInterval = 0.04
        /// How long after the Pause command an ordinary process may take to stop and still be held.
        /// Measured on a live player: 40 to 55 ms from the command.
        public var stopWindow: TimeInterval = 0.1
        /// The same for Music, Spotify and WebKit's GPU process.
        public var slowStopWindow: TimeInterval = 0.3
        /// The same for Chromium and Electron helpers (audio_renderer_mixer's 10 s pause delay).
        public var browserStopWindow: TimeInterval = 10.5
        /// How long to wait for Now Playing to report paused after Pause.
        public var nowPlayingStopTimeout: TimeInterval = 0.6
        /// How long an end waits before resuming. A new recording inside this window keeps
        /// the media paused (same as Windows).
        public var resumeGrace: TimeInterval = 0.4
        /// How long to wait for Play to show.
        public var settleTimeout: TimeInterval = 0.6
        public var pollInterval: TimeInterval = 0.01
        /// How often the end checks whether a pending browser helper has gone quiet.
        public var pendingRetryInterval: TimeInterval = 0.25
        /// How often to look for the user touching a paused player during a dictation.
        public var watchInterval: TimeInterval = 0.5
        /// The longest a quit waits for the resume.
        public var shutdownBudget: TimeInterval = 1.5

        public init() {}
    }

    // MARK: Holds

    private struct NowPlayingHold {
        var app: NowPlayingState
        /// Now Playing was seen reporting paused after the command. False when it could not be
        /// read right after, and the hold is kept anyway.
        var confirmed = true
        /// Something played, or Now Playing changed app, during the dictation.
        var touched = false
    }

    private struct Hold {
        var held: Set<MediaPlayerID> = []
        var background: Set<MediaPlayerID> = []
        /// Browser helpers that had not stopped when the window for others closed, with the
        /// time after which they count as background instead.
        var pending: [MediaPlayerID: Date] = [:]
        /// The user played the paused player, or started something else, during the dictation.
        var touched = false
        /// Strangers seen on the previous watch tick (pids).
        var strangersLastTick: Set<Int32> = []

        func isKnown(_ player: MediaPlayerID) -> Bool {
            held.contains { $0.pid == player.pid } || background.contains { $0.pid == player.pid }
                || pending.keys.contains { $0.pid == player.pid }
        }
        func strangers(in playing: [MediaPlayerID]) -> Set<MediaPlayerID> {
            Set(playing.filter { !isKnown($0) })
        }
        func holdsHeldProcess(in playing: [MediaPlayerID]) -> Bool {
            playing.contains { player in held.contains { $0.pid == player.pid } }
        }
    }

    private let effects: MediaEffects
    private let isEnabled: () -> Bool
    private let diagnostics: Diagnostics
    private let timing: Timing
    private let clock: MediaClock
    private let queue = DispatchQueue(label: "ai.useful.voice.media-pause", qos: .userInitiated)

    // Written from any thread, under the lock: whether a recording is live and which one.
    private let lock = NSLock()
    private var recording = false
    private var epoch = 0
    private var shuttingDown = false

    // Only touched on the queue.
    private var nowPlayingHold: NowPlayingHold?
    private var hold: Hold?
    private var watcher: MediaClockToken?
    private var disabled = false
    private var audioUnsupported = false
    private var logged: Set<String> = []

    public init(effects: MediaEffects,
                isEnabled: @escaping () -> Bool,
                diagnostics: Diagnostics = .shared,
                timing: Timing = Timing(),
                clock: MediaClock = RealMediaClock()) {
        self.effects = effects
        self.isEnabled = isEnabled
        self.diagnostics = diagnostics
        self.timing = timing
        self.clock = clock
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
        _ = clock.schedule(after: timing.resumeGrace, on: queue) { [self] in
            resume(afterEpoch: mine)
        }
    }

    /// The app is quitting: resume now, waiting at most `shutdownBudget`. A pause still in
    /// flight finishes first; it is bounded by the press look and the stop window.
    public func shutdown() {
        lock.withLock {
            recording = false
            shuttingDown = true
        }
        let finished = DispatchSemaphore(value: 0)
        queue.async { [self] in
            resume(afterEpoch: nil)
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + timing.shutdownBudget)
    }

    /// Waits for queued work. For tests and the harness.
    public func flush() {
        queue.sync {}
    }

    /// The clock the policy runs on. For tests, which drive a virtual one.
    var clockForTesting: MediaClock { clock }

    /// Whether a quit has been requested. For tests that quit while a pause is in flight.
    var isShuttingDownForTesting: Bool { lock.withLock { shuttingDown } }

    /// One watch tick, on demand. For tests, which set `watchInterval` far out.
    func runWatchTickForTesting() {
        queue.sync { watchTick() }
    }

    // MARK: - Pause

    private func pauseIfPlaying(epoch mine: Int) {
        guard !disabled, isEnabled() else { return }
        guard isLive(mine) else { return }
        if let state = effects.nowPlaying() {
            pauseNowPlaying(state, epoch: mine)
        } else {
            // The reader logs its own failure once; the audio list takes over quietly.
            pauseByAudio(epoch: mine)
        }
    }

    // MARK: Pause by Now Playing

    private func pauseNowPlaying(_ state: NowPlayingState, epoch mine: Int) {
        // Still paused from the previous dictation of a back-to-back pair: nothing to do.
        // Something else playing now is the user's new media: pause it too.
        guard state.isPlaying, state.hasApp, isLive(mine) else { return }
        do {
            try effects.sendPause()
            var waited: TimeInterval = 0
            let began = clock.now()
            var confirmed = true
            while true {
                guard let now = effects.nowPlaying() else {
                    // The pause is out and the app is known from the read before it, so it is
                    // remembered. The end resumes it by the audio list if Now Playing stays unreadable.
                    confirmed = false
                    break
                }
                if now.isSameApp(as: state), !now.isPlaying { break }
                if waited >= timing.nowPlayingStopTimeout || clock.now().timeIntervalSince(began) >= timing.nowPlayingStopTimeout {
                    diagnostics.warning("media", "Could not pause \(state): it still reports playing after the pause command")
                    return
                }
                clock.sleep(timing.pollInterval)
                waited += timing.pollInterval
            }
            nowPlayingHold = NowPlayingHold(app: state, confirmed: confirmed)
            startWatching()
            var message = "Paused \(state.bundleID ?? "pid \(state.pid)") for the dictation"
            if !confirmed { message += "; Now Playing became unreadable right after, so it is not confirmed paused" }
            diagnostics.info("media", message)
        } catch {
            handle(error, context: "Pausing media failed")
        }
    }

    // MARK: Pause by audio (fallback)

    private func pauseByAudio(epoch mine: Int) {
        guard !audioUnsupported else { return }
        let known = hold ?? Hold()
        do {
            // Already holding something (a back-to-back dictation): only what is new counts.
            let first = known.strangers(in: try effects.outputtingPlayers())
            guard !first.isEmpty else { return }
            clock.sleep(timing.pressConfirmDelay)
            let p0 = first.intersection(known.strangers(in: try effects.outputtingPlayers()))
            guard !p0.isEmpty, isLive(mine) else { return }

            let commanded = clock.now()
            try effects.sendPause()
            let result = try waitForStop(of: p0, since: commanded)
            guard !result.stopped.isEmpty || !result.pending.isEmpty else {
                // Nothing stopped in time. One last look: something outside P0 that started
                // meanwhile (Now Playing moved) is paused too.
                let late = known.strangers(in: try effects.outputtingPlayers())
                    .filter { player in !p0.contains { $0.pid == player.pid } }
                if !late.isEmpty { try effects.sendPause() }
                diagnostics.warning("media", "Could not pause \(describe(p0)): nothing stopped soon enough after the pause command, so it is not remembered")
                return
            }
            var updated = known
            updated.held.formUnion(result.stopped)
            let deadline = commanded.addingTimeInterval(timing.browserStopWindow)
            for player in result.pending { updated.pending[player] = deadline }
            updated.background.formUnion(p0.subtracting(result.stopped).subtracting(result.pending))
            updated.touched = false
            hold = updated
            startWatching()
            var message = "Paused \(describe(result.stopped.union(result.pending))) for the dictation"
            if !result.pending.isEmpty { message += " (\(describe(result.pending)) is still rendering silence, waiting for it to go quiet)" }
            let background = p0.subtracting(result.stopped).subtracting(result.pending)
            if !background.isEmpty { message += "; \(describe(background)) keeps playing and is left alone" }
            diagnostics.info("media", message)
        } catch {
            handle(error, context: "Pausing media failed")
        }
    }

    /// How long a process may take to go quiet after Pause and still count as paused by it.
    private func stopWindow(for player: MediaPlayerID) -> TimeInterval {
        if MediaPlayerFilter.isBrowserHelper(bundleID: player.bundleID) { return timing.browserStopWindow }
        if MediaPlayerFilter.isSlowToStop(bundleID: player.bundleID) { return timing.slowStopWindow }
        return timing.stopWindow
    }

    /// Waits only as long as the non-browser players are allowed. Browser helpers that are still
    /// outputting then are `pending`: waiting up to 10.5 s here would hold up the end.
    private func waitForStop(of players: Set<MediaPlayerID>, since began: Date) throws
        -> (stopped: Set<MediaPlayerID>, pending: Set<MediaPlayerID>) {
        let browsers = players.filter { MediaPlayerFilter.isBrowserHelper(bundleID: $0.bundleID) }
        let others = players.subtracting(browsers)
        let shortWindow = others.map { stopWindow(for: $0) }.max() ?? 0
        var waited: TimeInterval = 0
        while true {
            let outputting = Set(try effects.outputtingPlayers())
            let elapsed = clock.now().timeIntervalSince(began)
            let quiet = players.subtracting(outputting)
            let inTime = quiet.filter { elapsed <= stopWindow(for: $0) }
            let pending = browsers.intersection(outputting)
            if !inTime.isEmpty { return (inTime, pending) }
            // The window is measured on the clock as well as in poll steps, so slow looks cannot
            // stretch it: a late stop is not a stop caused by the command.
            if waited >= shortWindow || elapsed >= shortWindow { return ([], pending) }
            clock.sleep(timing.pollInterval)
            waited += timing.pollInterval
        }
    }

    // MARK: - Watching a dictation for the user touching things

    private func startWatching() {
        guard watcher == nil else { return }
        watcher = clock.every(timing.watchInterval, on: queue) { [weak self] in self?.watchTick() }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func watchTick() {
        guard nowPlayingHold != nil || hold != nil else { return stopWatching() }
        if var current = nowPlayingHold, !current.touched, let state = effects.nowPlaying() {
            // Anything playing now is the user: the player pressed again, or something else.
            // Now Playing moving to another app is the user too. No app at all is left to the end.
            if state.isPlaying || (state.hasApp && !state.isSameApp(as: current.app)) {
                current.touched = true
                nowPlayingHold = current
            }
        }
        guard var current = hold else { return }
        // A failed look is not "touched"; the gate at the end looks again.
        guard let playing = try? effects.outputtingPlayers() else { return }
        promotePending(&current, playing: playing)
        if !current.touched {
            // Touched means: a held process outputs (the user pressed play), or a stranger outputs
            // on two consecutive ticks (the user started something). One tick of a stranger is a
            // ding. A pending browser helper's silence tail is neither.
            let strangers = Set(current.strangers(in: playing).map(\.pid))
            if current.holdsHeldProcess(in: playing) || !strangers.isDisjoint(with: current.strangersLastTick) {
                current.touched = true
            }
            current.strangersLastTick = strangers
        }
        hold = current
    }

    /// A pending browser helper that went quiet in time is held; one still rendering after its
    /// deadline is simply a background stream.
    private func promotePending(_ current: inout Hold, playing: [MediaPlayerID]) {
        let now = clock.now()
        for (player, deadline) in current.pending {
            if !playing.contains(where: { $0.pid == player.pid }) {
                current.pending[player] = nil
                if now <= deadline { current.held.insert(player) }
            } else if now > deadline {
                current.pending[player] = nil
                current.background.insert(player)
            }
        }
    }

    // MARK: - Resume

    private func resume(afterEpoch ended: Int?) {
        if let ended {
            // A newer recording started while this resume was waiting: stay paused.
            let stillTheEnd = lock.withLock { !recording && epoch == ended }
            guard stillTheEnd else { return }
        }
        // Audio holds first: a pending browser helper may ask to look again shortly.
        if var current = hold, !current.pending.isEmpty {
            if let playing = try? effects.outputtingPlayers() { promotePending(&current, playing: playing) }
            hold = current
            if current.held.isEmpty, !current.pending.isEmpty, ended != nil {
                // Wait for the silence tail without holding up the queue.
                _ = clock.schedule(after: timing.pendingRetryInterval, on: queue) { [self] in
                    resume(afterEpoch: ended)
                }
                return
            }
            if current.held.isEmpty, current.pending.isEmpty, current.background.isEmpty { hold = nil }
        }
        stopWatching()
        let nowPlayingCurrent = nowPlayingHold
        let audioCurrent = hold
        nowPlayingHold = nil
        hold = nil
        if let nowPlayingCurrent { resumeNowPlaying(nowPlayingCurrent) }
        if let audioCurrent { resumeAudio(audioCurrent) }
    }

    private func resumeNowPlaying(_ current: NowPlayingHold) {
        do {
            guard !current.touched else {
                diagnostics.info("media", "Not resuming: something played or Now Playing changed during the dictation")
                return
            }
            guard let state = effects.nowPlaying() else {
                // The pause was sent, so it is not dropped: the audio list decides instead.
                diagnostics.info("media", "Now Playing cannot be read at the end; resuming \(current.app.bundleID ?? "the player") by the audio process list")
                var fallback = Hold()
                fallback.held = [MediaPlayerID(pid: current.app.pid, bundleID: current.app.bundleID)]
                resumeAudio(fallback)
                return
            }
            guard state.hasApp, state.isSameApp(as: current.app), !state.isPlaying else {
                // Includes no Now Playing app at all: Play would launch Music.
                diagnostics.info("media", "Not resuming: Now Playing is \(state), not the paused \(current.app.bundleID ?? "player")")
                return
            }
            guard effects.isAlive(MediaPlayerID(pid: current.app.pid, bundleID: current.app.bundleID)) else {
                diagnostics.info("media", "Not resuming: \(current.app.bundleID ?? "the player") is gone")
                return
            }
            try effects.sendPlay()
            var waited: TimeInterval = 0
            let began = clock.now()
            while true {
                guard let now = effects.nowPlaying() else {
                    diagnostics.warning("media", "Could not confirm the resume: Now Playing became unreadable")
                    return
                }
                if now.isPlaying {
                    if now.isSameApp(as: current.app) {
                        diagnostics.info("media", "Resumed \(current.app.bundleID ?? "the player")")
                    } else {
                        try effects.sendPause()
                        diagnostics.warning("media", "Play reached \(now) instead of \(current.app.bundleID ?? "the player"); paused it again")
                    }
                    return
                }
                if waited >= timing.settleTimeout || clock.now().timeIntervalSince(began) >= timing.settleTimeout {
                    diagnostics.warning("media", "Could not resume \(current.app.bundleID ?? "the player")")
                    return
                }
                clock.sleep(timing.pollInterval)
                waited += timing.pollInterval
            }
        } catch {
            handle(error, context: "Resuming media failed")
        }
    }

    private func resumeAudio(_ current: Hold) {
        do {
            guard !current.touched else {
                diagnostics.info("media", "Not resuming: the player was used during the dictation")
                return
            }
            guard !current.held.isEmpty else {
                diagnostics.info("media", "Not resuming: nothing was seen stopping after the pause")
                return
            }
            let alive = current.held.filter { effects.isAlive($0) }
            guard !alive.isEmpty else {
                diagnostics.info("media", "Not resuming: \(describe(current.held)) is gone")
                return
            }
            let playingNow = try effects.outputtingPlayers()
            guard !current.holdsHeldProcess(in: playingNow) else {
                diagnostics.info("media", "Not resuming: \(describe(current.held)) was played again")
                return
            }
            // A stranger counts only when still there 40 ms later: a ding is not the user.
            let first = current.strangers(in: playingNow)
            if !first.isEmpty {
                clock.sleep(timing.strangerGap)
                let second = current.strangers(in: try effects.outputtingPlayers())
                let persistent = first.filter { player in second.contains { $0.pid == player.pid } }
                guard persistent.isEmpty else {
                    diagnostics.info("media", "Not resuming: \(describe(persistent)) is playing")
                    return
                }
            }
            try effects.sendPlay()
            try confirmResume(alive: alive, current: current)
        } catch {
            handle(error, context: "Resuming media failed")
        }
    }

    /// After Play: done when the paused player outputs (the same app counts: a browser may
    /// bring its audio helper back under a new pid). A persistent stranger with no held
    /// process outputting means Play reached another app: pause it again. The player just
    /// resumed is never paused.
    private func confirmResume(alive: Set<MediaPlayerID>, current: Hold) throws {
        func isResumed(_ playing: [MediaPlayerID]) -> Bool {
            playing.contains { player in alive.contains { $0.isSameApp(as: player) } }
        }
        func strangers(_ playing: [MediaPlayerID]) -> Set<MediaPlayerID> {
            Set(playing.filter { player in
                !current.background.contains { $0.pid == player.pid }
                    && !alive.contains { $0.isSameApp(as: player) }
            })
        }
        var waited: TimeInterval = 0
        while true {
            let playing = try effects.outputtingPlayers()
            if isResumed(playing) {
                diagnostics.info("media", "Resumed \(describe(alive))")
                return
            }
            let first = strangers(playing)
            if !first.isEmpty {
                clock.sleep(timing.strangerGap)
                waited += timing.strangerGap
                let again = try effects.outputtingPlayers()
                if isResumed(again) {
                    diagnostics.info("media", "Resumed \(describe(alive))")
                    return
                }
                let second = strangers(again)
                let persistent = first.filter { player in second.contains { $0.pid == player.pid } }
                if !persistent.isEmpty {
                    try effects.sendPause()
                    diagnostics.warning("media", "Play reached \(describe(persistent)) instead of \(describe(alive)); paused it again")
                    return
                }
            }
            if waited >= timing.settleTimeout {
                diagnostics.warning("media", "Could not resume \(describe(alive))")
                return
            }
            clock.sleep(timing.pollInterval)
            waited += timing.pollInterval
        }
    }

    // MARK: - Helpers

    private func isLive(_ mine: Int) -> Bool {
        lock.withLock { recording && epoch == mine && !shuttingDown }
    }

    /// A macOS without the audio process list turns the audio fallback off for good, with one
    /// log line. MediaRemote that cannot load turns the whole feature off. Anything else is
    /// logged once per kind of failure, so a refusing system does not fill the log with one
    /// line per dictation.
    private func handle(_ error: Error, context: String) {
        if let media = error as? MediaEffectsError {
            switch media {
            case .processListUnsupported:
                audioUnsupported = true
                logOnce("unsupported", error)
                return
            case .mediaRemoteUnavailable:
                disabled = true
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
        logOnce(key, "\(error.localizedDescription). Media is left alone", level: .warning)
    }

    private func logOnce(_ key: String, _ message: String, level: Diagnostics.Level) {
        guard logged.insert(key).inserted else { return }
        diagnostics.record(level: level, category: "media", message: message)
    }

    private func describe(_ players: Set<MediaPlayerID>) -> String {
        players.map(\.description).sorted().joined(separator: ", ")
    }
}
