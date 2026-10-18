import Testing
import Foundation
@testable import UsefulVoiceCore

/// Time that only moves when the test (or the policy's own sleeps) say so, so no media policy
/// test depends on how fast or loaded the machine is. Scheduled work (the grace, the pending
/// retry, the watch ticks) runs on its queue, in time order, when `advance` passes its due time.
private final class VirtualClock: MediaClock, @unchecked Sendable {
    private struct Scheduled {
        let id: Int
        var due: TimeInterval
        let interval: TimeInterval?
        let queue: DispatchQueue
        let work: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let origin = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var elapsed: TimeInterval = 0
    private var scheduled: [Int: Scheduled] = [:]
    private var nextID = 0
    /// Called inside every `sleep`, before time moves (a quit arriving while a pause waits, say).
    var sleepHook: ((TimeInterval) -> Void)?

    func now() -> Date { lock.withLock { origin.addingTimeInterval(elapsed) } }

    func sleep(_ seconds: TimeInterval) {
        sleepHook?(seconds)
        lock.withLock { elapsed += seconds }
    }

    func schedule(after delay: TimeInterval, on queue: DispatchQueue,
                  _ work: @escaping @Sendable () -> Void) -> MediaClockToken {
        add(after: delay, interval: nil, on: queue, work)
    }

    func every(_ interval: TimeInterval, on queue: DispatchQueue,
               _ work: @escaping @Sendable () -> Void) -> MediaClockToken {
        add(after: interval, interval: interval, on: queue, work)
    }

    private func add(after delay: TimeInterval, interval: TimeInterval?, on queue: DispatchQueue,
                     _ work: @escaping @Sendable () -> Void) -> MediaClockToken {
        let id: Int = lock.withLock {
            nextID += 1
            scheduled[nextID] = Scheduled(id: nextID, due: elapsed + delay, interval: interval, queue: queue, work: work)
            return nextID
        }
        return MediaClockToken { [weak self] in self?.lock.withLock { self?.scheduled[id] = nil } }
    }

    /// Moves time forward by `duration`, running whatever falls due on the way, in order.
    func advance(by duration: TimeInterval) {
        let target = lock.withLock { elapsed + duration }
        while true {
            let next: Scheduled? = lock.withLock {
                guard let task = scheduled.values.filter({ $0.due <= target })
                    .min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) else { return nil }
                if elapsed < task.due { elapsed = task.due }
                if let interval = task.interval {
                    scheduled[task.id]?.due = task.due + interval
                } else {
                    scheduled[task.id] = nil
                }
                return task
            }
            guard let next else { break }
            next.queue.sync { next.work() }
        }
        lock.withLock { if elapsed < target { elapsed = target } }
    }

    /// Steps time forward until `condition` holds, for at most `limit` of virtual time.
    func advance(until condition: () -> Bool, limit: TimeInterval = 5, step: TimeInterval = 0.01) {
        var spent: TimeInterval = 0
        while spent < limit, !condition() {
            advance(by: step)
            spent += step
        }
    }
}

/// A scripted system. Processes are "outputting" or not; Pause and Play act on the Now
/// Playing app (the last one that started as a player, like macOS); background streams (a
/// call app) output forever and no command reaches them. Every call is recorded in order.
/// Delays (an audio tail, a slow Play, an alert's length) are in virtual time.
private final class FakeMedia: MediaEffects, @unchecked Sendable {
    let clock = VirtualClock()
    private let lock = NSLock()
    private var playing: [MediaPlayerID] = []
    private var alive: Set<Int32> = []
    private var calls: [String] = []
    private var target: MediaPlayerID?
    private var queries = 0
    // Now Playing, as the perl reader would report it. Off by default: the audio fallback.
    private var npApp: MediaPlayerID?
    private var npPlaying = false
    private(set) var launchedMusic = false
    /// Changes that happen later, in virtual time.
    private var later: [(due: Date, apply: () -> Void)] = []

    /// A refusing system: the commands are accepted and do nothing.
    var commandsWork = true
    /// After Pause, the target's audio keeps outputting this long (Chromium's mixer: 10 s of silence).
    var pauseDelay: TimeInterval = 0
    var outputError: Error?
    var pauseError: Error?
    var playError: Error?
    /// When Play starts the target, another process of the same app is the one that outputs.
    var playStartsAs: MediaPlayerID?
    /// Play takes this long to show in the output (a slow player).
    var playDelay: TimeInterval = 0
    /// A process that shows up in exactly the next look, then is gone (a ding).
    var transient: MediaPlayerID?
    /// A process that shows up in exactly the next look after Play.
    var transientOnPlay: MediaPlayerID?
    /// The Now Playing reader works (primary mode). Off: it cannot be read and the audio list is used.
    var nowPlayingAvailable = false
    /// Runs after each Pause command, outside the lock (Now Playing moving, say).
    var onPause: (() -> Void)?
    /// Runs after each Play command, outside the lock.
    var onPlay: (() -> Void)?
    /// Called inside `outputtingPlayers`, to hold the queue or script a change.
    var onOutputQuery: (() -> Void)?
    /// For the transient-alert test: how many queries see the players before they vanish.
    var vanishAfterQueries: Int?

    /// Caller holds the lock: runs the changes whose time has come.
    private func applyDue() {
        let now = clock.now()
        let due = later.filter { $0.due <= now }.sorted { $0.due < $1.due }
        later.removeAll { $0.due <= now }
        for change in due { change.apply() }
    }
    private func after(_ delay: TimeInterval, _ apply: @escaping () -> Void) {
        later.append((clock.now().addingTimeInterval(delay), apply))
    }

    /// A player the commands reach.
    func start(_ player: MediaPlayerID) {
        lock.withLock {
            if !playing.contains(player) { playing.append(player) }
            alive.insert(player.pid)
            target = player
            npApp = player
            npPlaying = true
        }
    }
    /// A stream that keeps outputting whatever the commands do.
    func startBackground(_ player: MediaPlayerID) {
        lock.withLock {
            playing.append(player)
            alive.insert(player.pid)
        }
    }
    /// A paused app that Now Playing now points at (the user opened it).
    func retarget(_ player: MediaPlayerID) {
        lock.withLock {
            alive.insert(player.pid)
            target = player
            npApp = player
            npPlaying = false
        }
    }
    /// Now Playing says this app plays (or not), whatever the audio list shows.
    func setNowPlaying(_ player: MediaPlayerID?, playing isPlaying: Bool) {
        lock.withLock {
            npApp = player
            npPlaying = isPlaying
            if let player { alive.insert(player.pid); target = player }
        }
    }
    /// An alert: outputs for `duration` from now, then stops by itself. No command reaches it.
    func blip(_ player: MediaPlayerID, for duration: TimeInterval) {
        lock.withLock {
            playing.append(player)
            alive.insert(player.pid)
            after(duration) { [self] in playing.removeAll { $0 == player } }
        }
    }
    func stop(_ player: MediaPlayerID) {
        lock.withLock {
            playing.removeAll { $0 == player }
            if npApp == player { npPlaying = false }   // the user paused it
        }
    }
    func die(_ player: MediaPlayerID) {
        lock.withLock {
            playing.removeAll { $0 == player }
            alive.remove(player.pid)
            if npApp == player { npApp = nil; npPlaying = false }
        }
    }

    func nowPlaying() -> NowPlayingState? {
        lock.withLock {
            applyDue()
            guard nowPlayingAvailable else { return nil }
            guard let npApp else { return NowPlayingState(isPlaying: false, pid: 0, bundleID: nil) }
            return NowPlayingState(isPlaying: npPlaying, pid: npApp.pid, bundleID: npApp.bundleID)
        }
    }

    func outputtingPlayers() throws -> [MediaPlayerID] {
        onOutputQuery?()
        return try lock.withLock {
            applyDue()
            if let outputError { throw outputError }
            queries += 1
            if let vanishAfterQueries, queries > vanishAfterQueries { playing.removeAll() }
            var result = playing
            if let transient {
                if !result.contains(transient) { result.append(transient) }
                self.transient = nil
            }
            return result
        }
    }
    func isAlive(_ player: MediaPlayerID) -> Bool { lock.withLock { alive.contains(player.pid) } }

    func sendPause() throws {
        let victim: MediaPlayerID? = try lock.withLock {
            applyDue()
            calls.append("pause")
            if let pauseError { throw pauseError }
            if commandsWork, npApp != nil { npPlaying = false }   // Now Playing reports paused at once
            guard commandsWork, let target else { return nil }
            if pauseDelay > 0 {
                // Audio keeps rendering for a while; only the audio list changes.
                after(pauseDelay) { [self] in playing.removeAll { $0 == target } }
            } else {
                playing.removeAll { $0 == target }
            }
            return target
        }
        _ = victim
        onPause?()
    }
    func sendPlay() throws {
        try lock.withLock {
            applyDue()
            calls.append("play")
            if let playError { throw playError }
            transient = transientOnPlay
            if nowPlayingAvailable, npApp == nil { launchedMusic = true }   // Play with no Now Playing app launches Music
            guard commandsWork, let target, alive.contains(target.pid) else { return }
            if npApp == target { npPlaying = true }
            guard !playing.contains(target) else { return }
            let starter = playStartsAs ?? target
            if playDelay > 0 {
                after(playDelay) { [self] in if !playing.contains(starter) { playing.append(starter) } }
            } else {
                playing.append(starter)
            }
        }
        onPlay?()
    }

    var callList: [String] { lock.withLock { applyDue(); return calls } }
    var isPlaying: [MediaPlayerID] { lock.withLock { applyDue(); return playing } }
}

private struct Boom: Error {}

/// The code's quit budget plus half a second. The semaphore wait returns at the budget, and a
/// loaded CI Mac adds its own delay on top (1.528 s was measured against 1.5).
private let quitBudgetWithSlack = MediaPausePolicy.Timing().shutdownBudget + 0.5

// Neutral bundle ids: the real Spotify and Chromium names get their own windows (see below).
private let spotify = MediaPlayerID(pid: 100, bundleID: "com.example.musicplayer")
private let chrome = MediaPlayerID(pid: 200, bundleID: "com.example.videoapp")
private let browserHelper = MediaPlayerID(pid: 400, bundleID: "com.google.Chrome.helper")
private let realSpotify = MediaPlayerID(pid: 500, bundleID: "com.spotify.client")
private let zoom = MediaPlayerID(pid: 300, bundleID: "us.zoom.xos")

private func makePolicy(
    _ media: FakeMedia,
    enabled: @escaping () -> Bool = { true },
    grace: TimeInterval = 0.05,
    watch: TimeInterval = 0.02,
    browserWindow: TimeInterval? = nil
) -> (MediaPausePolicy, Diagnostics) {
    let diagnostics = Diagnostics(directory: nil)
    var timing = MediaPausePolicy.Timing()
    timing.resumeGrace = grace
    timing.watchInterval = watch
    if let browserWindow { timing.browserStopWindow = browserWindow }
    return (MediaPausePolicy(effects: media, isEnabled: enabled, diagnostics: diagnostics, timing: timing,
                             clock: media.clock), diagnostics)
}

private func virtualClock(of policy: MediaPausePolicy) -> VirtualClock {
    policy.clockForTesting as! VirtualClock
}

/// Lets `seconds` of virtual time pass, with the policy's queue idle before and after.
private func elapse(_ policy: MediaPausePolicy, _ seconds: TimeInterval) {
    policy.flush()
    virtualClock(of: policy).advance(by: seconds)
    policy.flush()
}

/// Steps virtual time until a condition holds (the resume runs after the grace), up to 5 s of it.
private func settle(_ policy: MediaPausePolicy, until condition: () -> Bool) {
    policy.flush()
    virtualClock(of: policy).advance(until: condition)
    policy.flush()
}

/// Lets a resume that should NOT happen have every chance to.
private func waitOutGrace(_ policy: MediaPausePolicy, _ seconds: TimeInterval = 0.3) {
    elapse(policy, seconds)
}

@Suite(.serialized) struct MediaPausePolicyTests {
    // MARK: The setting

    @Test func settingOffNeverTouchesMedia() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, enabled: { false })
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); waitOutGrace(policy)
        #expect(media.callList.isEmpty)
        #expect(media.isPlaying == [spotify])
    }

    @Test func settingIsReadAtEveryStart() {
        let media = FakeMedia()
        media.start(spotify)
        let enabled = Flag(true)
        let (policy, _) = makePolicy(media, enabled: { enabled.value })
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
        enabled.value = false
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause", "play"])   // the second dictation left it alone
    }

    @Test func turningTheSettingOffMidDictationStillResumes() {
        let media = FakeMedia()
        media.start(spotify)
        let enabled = Flag(true)
        let (policy, _) = makePolicy(media, enabled: { enabled.value })
        policy.recordingStarted(); policy.flush()
        enabled.value = false
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
        #expect(media.isPlaying == [spotify])
    }

    // MARK: Detect, pause only that, never delay the recording

    @Test func nothingPlayingSendsNothing() {
        let media = FakeMedia()
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); waitOutGrace(policy)
        #expect(media.callList.isEmpty)
    }

    @Test func pausesWhatIsPlayingAndResumesItWhenTheRecordingEnds() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause"])
        #expect(media.isPlaying.isEmpty)
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
        #expect(media.isPlaying == [spotify])
    }

    @Test func recordingStartReturnsBeforeDetectionFinishes() {
        let media = FakeMedia()
        media.start(spotify)
        let gate = DispatchSemaphore(value: 0)
        media.onOutputQuery = { _ = gate.wait(timeout: .now() + 5) }
        let (policy, _) = makePolicy(media)
        let began = Date()
        policy.recordingStarted()
        #expect(Date().timeIntervalSince(began) < 1)     // the detection is parked on the gate for up to 5 s; a loaded CI Mac can be slow, so no tight bound
        for _ in 0..<8 { gate.signal() }
        policy.flush()
        media.onOutputQuery = nil
    }

    @Test func aRecordingThatEndsBeforeDetectionFinishesNeverPauses() {
        let media = FakeMedia()
        media.start(spotify)
        let gate = DispatchSemaphore(value: 0)
        media.onOutputQuery = { _ = gate.wait(timeout: .now() + 5) }
        let (policy, _) = makePolicy(media)
        policy.recordingStarted()
        policy.recordingEnded()   // a start failure: the end comes at once
        for _ in 0..<8 { gate.signal() }
        waitOutGrace(policy)
        media.onOutputQuery = nil
        #expect(media.callList.isEmpty)
        #expect(media.isPlaying == [spotify])
    }

    @Test func aSoundThatEndsBeforeTheSecondLookIsNotPaused() {
        let media = FakeMedia()
        media.start(chrome)
        media.vanishAfterQueries = 1   // an alert: there on the first look, gone on the second
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        #expect(media.callList.isEmpty)
    }

    // MARK: Resume only what we paused, only if nothing changed

    @Test func endingTwiceResumesOnce() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        waitOutGrace(policy, 0.15)
        #expect(media.callList == ["pause", "play"])
    }

    @Test func doesNotResumeWhenTheUserRestartedThePlayer() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.start(spotify)   // the user pressed play mid-dictation
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
    }

    @Test func doesNotResumeWhenTheUserPlayedAndPausedAgainMidDictation() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.start(spotify)                       // the user plays...
        elapse(policy, 0.15)        // ...long enough for the 500 ms watch (20 ms here) to see it
        media.stop(spotify)                        // ...and pauses again: the end looks quiet
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
        #expect(media.isPlaying.isEmpty)
    }

    @Test func doesNotResumeWhenADifferentPlayerStarted() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.start(chrome)   // a video started meanwhile
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
        #expect(media.isPlaying == [chrome])
    }

    @Test func doesNotResumeWhenADifferentPlayerStartedAndStoppedDuringTheDictation() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.startBackground(chrome)
        elapse(policy, 0.15)
        media.stop(chrome)
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
    }

    @Test func doesNotResumeWhenThePausedPlayerIsGone() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.die(spotify)
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
    }

    @Test func aPlayerTheUserPlayedAndPausedWithNothingHeldIsLeftAlone() {
        let media = FakeMedia()
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()   // nothing playing: we hold nothing
        media.start(spotify)
        elapse(policy, 0.1)
        media.stop(spotify)
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList.isEmpty)
    }

    @Test func aBrowserHelperRelaunchedUnderANewPidCountsAsTheSamePlayerOnResume() {
        let media = FakeMedia()
        media.start(chrome)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        // Play reaches Chrome, whose audio helper now runs under another pid.
        let relaunched = MediaPlayerID(pid: 201, bundleID: chrome.bundleID)
        media.playStartsAs = relaunched
        policy.recordingEnded()
        settle(policy) { media.isPlaying == [relaunched] }
        waitOutGrace(policy, 0.1)
        #expect(media.callList == ["pause", "play"])   // not mistaken for a stranger and paused again
        #expect(media.isPlaying == [relaunched])
    }

    // MARK: Background streams

    @Test func aBackgroundStreamIsLeftAloneAndNeverBlocksTheResume() {
        let media = FakeMedia()
        media.startBackground(zoom)   // a call keeps its stream open
        media.start(spotify)
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause"])
        #expect(media.isPlaying == [zoom])   // only Spotify stopped
        // ...for the whole dictation, including the watch that looks for the user touching things.
        elapse(policy, 0.15)
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
        #expect(Set(media.isPlaying) == [zoom, spotify])
        #expect(diagnostics.entries().contains { $0.message.contains("keeps playing") })
    }

    @Test func onlyABackgroundStreamPlayingPausesNothingAndResumesNothing() {
        let media = FakeMedia()
        media.startBackground(zoom)   // no Now Playing app: Pause reaches nobody
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); waitOutGrace(policy)
        #expect(media.callList == ["pause"])
        #expect(media.isPlaying == [zoom])
        #expect(diagnostics.entries().contains { $0.level == .warning && $0.category == "media" })
    }

    // MARK: Play reaching the wrong app

    @Test func ifPlayStartsADifferentAppItIsPausedAgain() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.retarget(chrome)   // Now Playing moved to a paused browser tab meanwhile
        policy.recordingEnded()
        settle(policy) { media.callList.count >= 3 }
        #expect(media.callList == ["pause", "play", "pause"])
        #expect(media.isPlaying.isEmpty)   // nothing unintended left playing
        #expect(diagnostics.entries().contains { $0.level == .warning && $0.message.contains("paused it again") })
    }

    @Test func ifPlayDoesNothingItIsLoggedAndNothingElseIsSent() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.commandsWork = false
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        waitOutGrace(policy, 0.1)
        #expect(media.callList == ["pause", "play"])   // no key, no retry
        #expect(diagnostics.entries().contains { $0.level == .warning && $0.message.contains("Could not resume") })
    }

    // MARK: Back to back

    @Test func aNewDictationDuringAPendingResumeKeepsTheMediaPaused() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 0.25)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded()
        policy.recordingStarted()   // inside the grace window
        policy.flush()
        waitOutGrace(policy, 0.5)
        #expect(media.callList == ["pause"])   // no resume, no second pause
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
    }

    @Test func theDefaultGraceIs400Milliseconds() {
        #expect(MediaPausePolicy.Timing().resumeGrace == 0.4)
    }

    @Test func aSecondStartWithoutAnEndDoesNotPauseTwice() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause"])
    }

    // MARK: Quit

    @Test func quittingWhilePausedResumesBeforeReturning() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 5)
        policy.recordingStarted(); policy.flush()
        policy.shutdown()   // no waiting for the grace
        #expect(media.callList == ["pause", "play"])
        #expect(media.isPlaying == [spotify])
    }

    @Test func quittingWhileAPauseIsStillTakingEffectCatchesItAndResumes() {
        let media = FakeMedia()
        media.pauseDelay = 0.05   // the player stops 50 ms after the command
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 5)
        let quitReturned = DispatchSemaphore(value: 0)
        var quit = false
        // While the pause waits for its effect (its first poll after the command), the app quits.
        media.clock.sleepHook = { [unowned media] _ in
            guard !quit, media.callList.contains("pause") else { return }
            quit = true
            DispatchQueue.global().async {
                policy.shutdown()
                quitReturned.signal()
            }
            let deadline = Date().addingTimeInterval(10)
            while !policy.isShuttingDownForTesting, Date() < deadline { usleep(1000) }
        }
        policy.recordingStarted()
        #expect(quitReturned.wait(timeout: .now() + 10) == .success)
        #expect(media.callList == ["pause", "play"])   // the pause was caught, then resumed
        #expect(media.isPlaying == [spotify])
    }

    @Test func quitNeverWaitsLongerThanItsBudgetBehindAPauseThatDoesNothing() {
        let media = FakeMedia()
        media.commandsWork = false   // the pause will never show
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 5)
        let quitReturned = DispatchSemaphore(value: 0)
        var quit = false
        media.clock.sleepHook = { _ in
            guard !quit else { return }
            quit = true
            DispatchQueue.global().async {
                policy.shutdown()
                quitReturned.signal()
            }
            let deadline = Date().addingTimeInterval(10)
            while !policy.isShuttingDownForTesting, Date() < deadline { usleep(1000) }
        }
        policy.recordingStarted()   // the press look is the first sleep: the quit arrives inside it
        let began = Date()
        #expect(quitReturned.wait(timeout: .now() + 10) == .success)
        #expect(Date().timeIntervalSince(began) < quitBudgetWithSlack)
        #expect(media.callList.isEmpty)   // a recording that was quit before its pause went out sends nothing
    }

    // MARK: Failures are logged, never thrown

    @Test func aFailingDetectionIsLoggedAndSwallowed() {
        let media = FakeMedia()
        media.outputError = Boom()
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); waitOutGrace(policy, 0.15)
        let entries = diagnostics.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.category == "media")
        #expect(entries.first?.level == .error)
    }

    @Test func aFailingResumeIsLoggedAndSwallowed() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.playError = Boom()
        policy.recordingEnded()
        settle(policy) { diagnostics.entries().contains { $0.level == .error } }
        #expect(diagnostics.entries().contains { $0.category == "media" && $0.level == .error })
    }

    @Test func everyEntryUsesTheMediaCategory() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(!diagnostics.entries().isEmpty)
        #expect(diagnostics.entries().allSatisfy { $0.category == "media" })
    }

    @Test func aRefusingSystemIsLoggedOnceAndNothingElseIsSent() {
        let media = FakeMedia()
        media.start(spotify)
        media.pauseError = MediaEffectsError.commandRefused("pause")
        let (policy, diagnostics) = makePolicy(media)
        for _ in 0..<3 {
            policy.recordingStarted(); policy.flush()
            policy.recordingEnded(); waitOutGrace(policy, 0.1)
        }
        #expect(media.callList == ["pause", "pause", "pause"])   // asked each time, never anything else
        #expect(diagnostics.entries().count == 1)                // ...and logged once
        #expect(media.isPlaying == [spotify])
    }

    @Test func mediaRemoteThatCannotLoadIsLoggedOnceAndTheFeatureStopsTrying() {
        let media = FakeMedia()
        media.start(spotify)
        media.pauseError = MediaEffectsError.mediaRemoteUnavailable("framework not found")
        let (policy, diagnostics) = makePolicy(media)
        for _ in 0..<3 {
            policy.recordingStarted(); policy.flush()
            policy.recordingEnded(); waitOutGrace(policy, 0.1)
        }
        #expect(media.callList == ["pause"])
        #expect(diagnostics.entries().count == 1)
        #expect(diagnostics.entries().first?.category == "media")
    }

    @Test func aMacWithoutTheProcessListTurnsTheFeatureOffWithOneLogLine() {
        let media = FakeMedia()
        media.outputError = MediaEffectsError.processListUnsupported   // macOS 14.0 and 14.1
        let (policy, diagnostics) = makePolicy(media)
        for _ in 0..<3 {
            policy.recordingStarted(); policy.flush()
            policy.recordingEnded(); waitOutGrace(policy, 0.1)
        }
        #expect(media.callList.isEmpty)
        #expect(diagnostics.entries().count == 1)
        #expect(diagnostics.entries().first?.category == "media")
        #expect(diagnostics.entries().first?.level == .warning)
    }

    // MARK: Alert sounds at the press

    @Test func anAlertThatOutlivesTheSecondLookButNotTheStopWindowIsNeverHeldOrResumed() {
        let media = FakeMedia()
        media.retarget(spotify)                 // a paused Now Playing app that a stray Play would start
        media.blip(chrome, for: 0.35)           // seen at the press and 150 ms later, gone ~200 ms after the command
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted()
        elapse(policy, 0.6)
        policy.recordingEnded()
        waitOutGrace(policy, 0.8)
        #expect(media.callList == ["pause"])    // the (harmless) pause, and never a play
        #expect(media.isPlaying.isEmpty)
        #expect(diagnostics.entries().contains { $0.level == .warning && $0.message.contains("not remembered") })
    }

    @Test func anAlertThatEndsBeforeTheSecondLookSendsNothingAtAll() {
        let media = FakeMedia()
        media.retarget(spotify)
        media.blip(chrome, for: 0.05)           // gone long before the look 150 ms after the press
        let (policy, _) = makePolicy(media)
        policy.recordingStarted()
        elapse(policy, 0.3)
        policy.recordingEnded()
        waitOutGrace(policy, 0.8)
        #expect(media.callList == [])
    }

    @Test func aPlayerThatStopsAfterTheStopWindowIsNotRemembered() {
        let media = FakeMedia()
        media.pauseDelay = 0.25                 // a slow player, or one process serving several tabs
        media.start(spotify)
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted()
        elapse(policy, 0.7)
        policy.recordingEnded()
        waitOutGrace(policy, 0.8)
        #expect(media.callList == ["pause"])    // paused, never resumed: it was not observed stopping
        #expect(diagnostics.entries().contains { $0.message.contains("not remembered") })
    }

    @Test func whenNothingStopsInTimeAProcessThatStartedMeanwhileIsPausedToo() {
        let media = FakeMedia()
        media.startBackground(zoom)             // outputs, and no command reaches it
        media.onPause = { [unowned media] in media.startBackground(chrome) }   // Now Playing moved to a browser tab
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause", "pause"])
    }

    // MARK: Dings during the dictation

    @Test func oneTickOfAStrangerIsADingAndTheMediaStillResumes() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.startBackground(chrome)
        policy.runWatchTickForTesting()     // the ding is on this tick...
        media.stop(chrome)
        policy.runWatchTickForTesting()     // ...and gone on the next
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
    }

    @Test func aStrangerOnTwoConsecutiveTicksIsTheUserAndNothingResumes() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.startBackground(chrome)
        policy.runWatchTickForTesting()
        policy.runWatchTickForTesting()
        media.stop(chrome)                  // gone again at the end: the end gate would not see it
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
    }

    @Test func twoDifferentDingsOnConsecutiveTicksAreNotOneStranger() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.startBackground(chrome)
        policy.runWatchTickForTesting()
        media.stop(chrome)
        media.startBackground(zoom)
        policy.runWatchTickForTesting()
        media.stop(zoom)
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
    }

    @Test func aHeldProcessOutputtingOnOneTickIsTheUserPressingPlay() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.start(spotify)
        policy.runWatchTickForTesting()
        media.stop(spotify)                 // paused again before the end
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
    }

    @Test func aDingAtTheEndGateIsNotTheUser() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.transient = chrome            // there in the first look at the end, gone in the second
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
    }

    @Test func aDingAfterPlayWhileThePlayerIsStillStartingIsNotPausedAndTheResumeCompletes() {
        let media = FakeMedia()
        media.playDelay = 0.08              // a slow player
        media.transientOnPlay = chrome      // a ding in the first look after Play
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted()
        elapse(policy, 0.4)
        policy.recordingEnded()
        settle(policy) { media.isPlaying == [spotify] }
        waitOutGrace(policy, 0.2)
        #expect(media.callList == ["pause", "play"])   // no second pause for a ding
        #expect(media.isPlaying == [spotify])
    }

    // MARK: Back to back

    @Test func aDictationDuringAHoldStillPausesAStrangerThatIsPlayingAndResumesBoth() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 0.25, watch: 100)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded()
        media.start(chrome)                 // the user started a video in the gap
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause", "pause"])
        #expect(media.isPlaying.isEmpty)
        waitOutGrace(policy, 0.4)
        #expect(media.callList == ["pause", "pause"])  // no resume in between
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "pause", "play"])
        #expect(media.isPlaying == [chrome])           // Play goes to the Now Playing app, which is the video
    }

    // MARK: Matching by pid

    @Test func aHeldBrowserHelperIsNotHiddenBehindASameBundleBackgroundHelper() {
        let media = FakeMedia()
        let backgroundHelper = MediaPlayerID(pid: 201, bundleID: chrome.bundleID)
        media.startBackground(backgroundHelper)   // another helper of the same app keeps going
        media.start(chrome)                       // the one Pause reaches
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause"])
        #expect(media.isPlaying == [backgroundHelper])
        media.start(chrome)                       // the user presses play on the held helper
        policy.runWatchTickForTesting()
        media.stop(chrome)
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])      // seen by pid, not lost behind the same bundle id
    }

    // MARK: Now Playing (primary)

    @Test func nowPlayingPausesThePlayingAppAndResumesItAtTheEnd() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause"])
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
        #expect(media.isPlaying == [spotify])
        #expect(!media.launchedMusic)
    }

    @Test func nowPlayingNotPlayingSendsNothingEvenWhenSomethingOutputsAudio() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.startBackground(zoom)          // a call: audible, but not Now Playing media
        media.blip(chrome, for: 0.3)         // and an alert
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); waitOutGrace(policy)
        #expect(media.callList.isEmpty)
    }

    @Test func aChromiumTabIsPausedAndResumedAlthoughItsAudioHelperRendersSilenceFor10Seconds() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.pauseDelay = 10                // the audio process stays "outputting" for 10 s after the pause
        media.start(browserHelper)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
    }

    @Test func nowPlayingTheUserPressedPlayMidDictationNothingResumes() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.start(spotify)                 // plays again
        policy.runWatchTickForTesting()
        media.stop(spotify)                  // and paused again before the end
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
    }

    @Test func nowPlayingMovingToAnotherAppMidDictationNothingResumes() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.retarget(chrome)               // the user opened another player, paused
        policy.runWatchTickForTesting()
        media.setNowPlaying(spotify, playing: false)   // and it is Spotify again at the end
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
    }

    @Test func nowPlayingThatVanishedIsNeverResumedBecausePlayWouldLaunchMusic() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.die(spotify)                   // the app quit: no Now Playing app left
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
        #expect(!media.launchedMusic)
    }

    @Test func nowPlayingThatIsAnotherPausedAppAtTheEndIsNotResumed() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.setNowPlaying(chrome, playing: false)   // changed after the last tick
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
    }

    @Test func nowPlayingIfPlayReachesADifferentAppItIsPausedAgain() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, diagnostics) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.onPlay = { [unowned media] in media.setNowPlaying(chrome, playing: true) }   // Now Playing moved at the last moment
        policy.recordingEnded()
        settle(policy) { media.callList.count >= 3 }
        #expect(media.callList == ["pause", "play", "pause"])
        #expect(diagnostics.entries().contains { $0.message.contains("paused it again") })
    }

    @Test func nowPlayingThatIgnoresThePauseHoldsNothing() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.commandsWork = false
        media.start(spotify)
        let (policy, diagnostics) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); waitOutGrace(policy)
        #expect(media.callList == ["pause"])
        #expect(diagnostics.entries().contains { $0.level == .warning && $0.message.contains("still reports playing") })
    }

    @Test func nowPlayingBackToBackKeepsItPausedAndResumesOnce() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 0.25, watch: 100)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded()
        policy.recordingStarted(); policy.flush()      // inside the grace: Now Playing is paused, nothing to pause
        waitOutGrace(policy, 0.5)
        #expect(media.callList == ["pause"])
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
    }

    @Test func nowPlayingQuittingWhilePausedResumes() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 5, watch: 100)
        policy.recordingStarted(); policy.flush()
        policy.shutdown()
        #expect(media.callList == ["pause", "play"])
    }

    // MARK: A pause that was sent is never dropped because Now Playing became unreadable

    @Test func nowPlayingThatBecomesUnreadableRightAfterThePauseIsStillRemembered() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        media.onPause = { [unowned media] in media.nowPlayingAvailable = false }   // the helper died as the pause went out
        let (policy, diagnostics) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])   // resumed by the audio list, using the app read before the pause
        #expect(media.isPlaying == [spotify])
        #expect(diagnostics.entries().contains { $0.message.contains("not confirmed paused") })
        #expect(!diagnostics.entries().contains { $0.message.contains("Could not confirm the pause") })
    }

    @Test func nowPlayingThatTurnsUnreadableBeforeTheEndFallsBackToTheAudioGate() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, diagnostics) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.nowPlayingAvailable = false
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
        #expect(diagnostics.entries().contains { $0.message.contains("by the audio process list") })
    }

    @Test func theAudioGateStillRefusesWhenThePausedAppIsPlayingAgain() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.nowPlayingAvailable = false
        media.start(spotify)                         // the user pressed play meanwhile
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
    }

    @Test func theAudioGateDoesNotResumeAnAppThatIsGone() {
        let media = FakeMedia()
        media.nowPlayingAvailable = true
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted(); policy.flush()
        media.nowPlayingAvailable = false
        media.die(spotify)
        policy.recordingEnded()
        waitOutGrace(policy)
        #expect(media.callList == ["pause"])
        #expect(!media.launchedMusic)
    }

    // MARK: Audio fallback with Chromium and slow players

    @Test func aChromiumHelperThatKeepsOutputtingAfterThePauseIsResumedOnceItGoesQuiet() {
        let media = FakeMedia()
        media.pauseDelay = 0.6                // its mixer renders silence for a while (10 s in life)
        media.start(browserHelper)
        let (policy, diagnostics) = makePolicy(media, grace: 0.05, watch: 100, browserWindow: 3)
        policy.recordingStarted()
        elapse(policy, 0.4)    // the pause is out, the tail is still running
        policy.runWatchTickForTesting()
        policy.runWatchTickForTesting()       // its tail on two ticks is not the user
        policy.recordingEnded()               // the dictation ends before the tail does
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
        #expect(media.isPlaying == [browserHelper])
        #expect(diagnostics.entries().contains { $0.message.contains("still rendering silence") })
    }

    @Test func aChromiumHelperThatNeverGoesQuietInTimeIsNotResumed() {
        let media = FakeMedia()
        media.pauseDelay = 5                  // keeps rendering well past the window
        media.start(browserHelper)
        let (policy, _) = makePolicy(media, grace: 0.05, watch: 100, browserWindow: 0.6)
        policy.recordingStarted()
        elapse(policy, 0.3)
        policy.recordingEnded()
        waitOutGrace(policy, 1.2)
        #expect(media.callList == ["pause"])
    }

    @Test func aChromiumHelperPlayedAgainAfterItWentQuietIsTheUser() {
        let media = FakeMedia()
        media.pauseDelay = 0.2
        media.start(browserHelper)
        let (policy, _) = makePolicy(media, grace: 0.05, watch: 100, browserWindow: 3)
        policy.recordingStarted()
        elapse(policy, 0.5)
        policy.runWatchTickForTesting()       // went quiet: held
        media.start(browserHelper)            // the user pressed play
        policy.runWatchTickForTesting()
        policy.recordingEnded()
        waitOutGrace(policy, 0.6)
        #expect(media.callList == ["pause"])
    }

    @Test func aChromiumHelperDoesNotBlockTheEndForAnotherPlayerThatStoppedAtOnce() {
        let media = FakeMedia()
        media.start(spotify)
        media.startBackground(browserHelper)  // a tab with audio that no command reaches
        let (policy, _) = makePolicy(media, grace: 0.05, watch: 100, browserWindow: 0.3)
        policy.recordingStarted()
        elapse(policy, 0.5)
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])   // the browser helper became background after its window
    }

    @Test func aSlowSpotifyThatStopsAfter250msIsStillHeld() {
        let media = FakeMedia()
        media.pauseDelay = 0.25               // a fade, longer than the ordinary 100 ms
        media.start(realSpotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted()
        elapse(policy, 0.7)
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
    }

    @Test func aSlowPlayerBeyond300msIsNotHeld() {
        let media = FakeMedia()
        media.pauseDelay = 0.6
        media.start(realSpotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted()
        elapse(policy, 1.0)
        policy.recordingEnded()
        waitOutGrace(policy, 0.5)
        #expect(media.callList == ["pause"])
    }

    @Test func anOrdinaryPlayerStillHasOnly100ms() {
        let media = FakeMedia()
        media.pauseDelay = 0.2
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted()
        elapse(policy, 0.6)
        policy.recordingEnded()
        waitOutGrace(policy, 0.5)
        #expect(media.callList == ["pause"])
    }

    /// The one test on the real clock: no timing assumption beyond "within 10 s".
    @Test func onTheRealClockAPauseAndAResumeStillHappen() {
        let media = FakeMedia()
        media.start(spotify)
        let policy = MediaPausePolicy(effects: media, isEnabled: { true }, diagnostics: Diagnostics(directory: nil))
        policy.recordingStarted()
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, !condition() { usleep(5000) }
        }
        wait { media.callList.contains("pause") }   // after the press looks, in real time
        #expect(media.callList == ["pause"])
        policy.recordingEnded()
        wait { media.callList.contains("play") }    // after the grace, in real time
        policy.flush()
        #expect(media.callList == ["pause", "play"])
        #expect(media.isPlaying == [spotify])
    }

    // MARK: What counts as media

    @Test func systemSoundsAndThisAppAreNotMedia() {
        #expect(MediaPlayerFilter.isMedia(pid: 1, bundleID: "com.spotify.client", ownPID: 9))
        #expect(MediaPlayerFilter.isMedia(pid: 1, bundleID: "com.apple.WebKit.GPU", ownPID: 9))
        #expect(MediaPlayerFilter.isMedia(pid: 1, bundleID: "com.apple.Music", ownPID: 9))
        #expect(MediaPlayerFilter.isMedia(pid: 1, bundleID: nil, ownPID: 9))          // an unbundled player
        #expect(!MediaPlayerFilter.isMedia(pid: 9, bundleID: "com.spotify.client", ownPID: 9))   // own pid
        #expect(!MediaPlayerFilter.isMedia(pid: 1, bundleID: "ai.useful.voice", ownPID: 9))      // the chimes
        #expect(!MediaPlayerFilter.isMedia(pid: 1, bundleID: "ai.useful.voice.helper", ownPID: 9))
        #expect(!MediaPlayerFilter.isMedia(pid: 1, bundleID: "systemsoundserverd", ownPID: 9))
        #expect(!MediaPlayerFilter.isMedia(pid: 1, bundleID: "com.apple.assistantd", ownPID: 9))
        #expect(!MediaPlayerFilter.isMedia(pid: 1, bundleID: "com.apple.audio.Core-Audio-Driver-Service.helper", ownPID: 9))
    }

    @Test func chromiumAndElectronHelpersAreRecognised() {
        for id in ["com.google.Chrome.helper", "com.vivaldi.Vivaldi.helper", "com.microsoft.edgemac.helper",
                   "com.brave.Browser.helper", "com.github.Electron.helper", "company.thebrowser.Browser.helper",
                   "company.thebrowser.Browser", "com.example.App Helper (Renderer)", "com.example.App Helper (Plugin)"] {
            #expect(MediaPlayerFilter.isBrowserHelper(bundleID: id), "\(id)")
        }
        for id in ["com.spotify.client", "com.apple.Music", "com.apple.WebKit.GPU", "us.zoom.xos"] {
            #expect(!MediaPlayerFilter.isBrowserHelper(bundleID: id), "\(id)")
        }
        #expect(!MediaPlayerFilter.isBrowserHelper(bundleID: nil))
        #expect(MediaPlayerFilter.isSlowToStop(bundleID: "com.apple.Music"))
        #expect(MediaPlayerFilter.isSlowToStop(bundleID: "com.spotify.client"))
        #expect(MediaPlayerFilter.isSlowToStop(bundleID: "com.apple.WebKit.GPU"))
        #expect(!MediaPlayerFilter.isSlowToStop(bundleID: "com.example.player"))
    }

    @Test func theDefaultWindowsAre100Ms300MsAnd10Point5Seconds() {
        let timing = MediaPausePolicy.Timing()
        #expect(timing.stopWindow == 0.1)
        #expect(timing.slowStopWindow == 0.3)
        #expect(timing.browserStopWindow == 10.5)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
