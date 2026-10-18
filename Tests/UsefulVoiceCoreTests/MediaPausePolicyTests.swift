import Testing
import Foundation
@testable import UsefulVoiceCore

/// A scripted system. Processes are "outputting" or not; Pause and Play act on the Now
/// Playing app (the last one that started as a player, like macOS); background streams (a
/// call app) output forever and no command reaches them. Every call is recorded in order.
private final class FakeMedia: MediaEffects, @unchecked Sendable {
    private let lock = NSLock()
    private var playing: [MediaPlayerID] = []
    private var alive: Set<Int32> = []
    private var calls: [String] = []
    private var target: MediaPlayerID?
    private var queries = 0

    /// A refusing system: the commands are accepted and do nothing.
    var commandsWork = true
    var pauseDelay: TimeInterval = 0
    var realSleep = false
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
    /// Runs after each Pause command, outside the lock (Now Playing moving, say).
    var onPause: (() -> Void)?
    /// Called inside `outputtingPlayers`, to hold the queue or script a change.
    var onOutputQuery: (() -> Void)?
    /// For the transient-alert test: how many queries see the players before they vanish.
    var vanishAfterQueries: Int?

    /// A player the commands reach.
    func start(_ player: MediaPlayerID) {
        lock.withLock {
            if !playing.contains(player) { playing.append(player) }
            alive.insert(player.pid)
            target = player
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
        }
    }
    /// An alert: outputs for `duration` from now, then stops by itself. No command reaches it.
    func blip(_ player: MediaPlayerID, for duration: TimeInterval) {
        startBackground(player)
        DispatchQueue.global().asyncAfter(deadline: .now() + duration) { [self] in stop(player) }
    }
    func stop(_ player: MediaPlayerID) { lock.withLock { playing.removeAll { $0 == player } } }
    func die(_ player: MediaPlayerID) {
        lock.withLock {
            playing.removeAll { $0 == player }
            alive.remove(player.pid)
        }
    }

    func outputtingPlayers() throws -> [MediaPlayerID] {
        onOutputQuery?()
        return try lock.withLock {
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
        let (delay, victim): (TimeInterval, MediaPlayerID?) = try lock.withLock {
            calls.append("pause")
            if let pauseError { throw pauseError }
            return (pauseDelay, commandsWork ? target : nil)
        }
        defer { onPause?() }
        guard let victim else { return }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in stop(victim) }
        } else {
            stop(victim)
        }
    }
    func sendPlay() throws {
        let starter: MediaPlayerID? = try lock.withLock {
            calls.append("play")
            if let playError { throw playError }
            transient = transientOnPlay
            guard commandsWork, let target, alive.contains(target.pid), !playing.contains(target) else { return nil }
            return playStartsAs ?? target
        }
        guard let starter else { return }
        if playDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + playDelay) { [self] in
                lock.withLock { if !playing.contains(starter) { playing.append(starter) } }
            }
        } else {
            lock.withLock { if !playing.contains(starter) { playing.append(starter) } }
        }
    }
    func sleep(_ seconds: TimeInterval) {
        if realSleep { Thread.sleep(forTimeInterval: seconds) }
    }

    var callList: [String] { lock.withLock { calls } }
    var isPlaying: [MediaPlayerID] { lock.withLock { playing } }
}

private struct Boom: Error {}

/// The code's quit budget plus half a second. Asserting the exact budget fails on a loaded CI
/// Mac (1.528 s was measured against 1.5): the semaphore wait returns at the budget, and the
/// scheduler adds its own delay on top.
private let quitBudgetWithSlack = MediaPausePolicy.Timing().shutdownBudget + 0.5

private let spotify = MediaPlayerID(pid: 100, bundleID: "com.spotify.client")
private let chrome = MediaPlayerID(pid: 200, bundleID: "com.google.Chrome.helper")
private let zoom = MediaPlayerID(pid: 300, bundleID: "us.zoom.xos")

private func makePolicy(
    _ media: FakeMedia,
    enabled: @escaping () -> Bool = { true },
    grace: TimeInterval = 0.05,
    watch: TimeInterval = 0.02
) -> (MediaPausePolicy, Diagnostics) {
    let diagnostics = Diagnostics(directory: nil)
    var timing = MediaPausePolicy.Timing()
    timing.resumeGrace = grace
    timing.watchInterval = watch
    return (MediaPausePolicy(effects: media, isEnabled: enabled, diagnostics: diagnostics, timing: timing), diagnostics)
}

/// Waits for a condition (the resume runs after the grace), up to 2 s, then lets queued work finish.
private func settle(_ policy: MediaPausePolicy, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, !condition() { Thread.sleep(forTimeInterval: 0.01) }
    policy.flush()
}

/// Lets a resume that should NOT happen have every chance to.
private func waitOutGrace(_ policy: MediaPausePolicy, _ seconds: TimeInterval = 0.3) {
    Thread.sleep(forTimeInterval: seconds)
    policy.flush()
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
        Thread.sleep(forTimeInterval: 0.15)        // ...long enough for the 500 ms watch (20 ms here) to see it
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
        Thread.sleep(forTimeInterval: 0.15)
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
        Thread.sleep(forTimeInterval: 0.1)
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
        Thread.sleep(forTimeInterval: 0.15)
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
        media.realSleep = true
        media.pauseDelay = 0.05   // the player stops 50 ms after the command
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 5)
        policy.recordingStarted()
        Thread.sleep(forTimeInterval: 0.18)   // the press look is over, the pause is out and waiting for its effect
        let began = Date()
        policy.shutdown()
        #expect(Date().timeIntervalSince(began) < quitBudgetWithSlack)
        #expect(media.callList == ["pause", "play"])
        #expect(media.isPlaying == [spotify])
    }

    @Test func quitNeverWaitsLongerThanItsBudgetBehindAPauseThatDoesNothing() {
        let media = FakeMedia()
        media.realSleep = true
        media.commandsWork = false   // the pause will never show
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 5)
        policy.recordingStarted()
        Thread.sleep(forTimeInterval: 0.1)
        let began = Date()
        policy.shutdown()
        #expect(Date().timeIntervalSince(began) < quitBudgetWithSlack)
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
        media.realSleep = true
        media.retarget(spotify)                 // a paused Now Playing app that a stray Play would start
        media.blip(chrome, for: 0.35)           // seen at the press and 150 ms later, gone ~200 ms after the command
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted()
        Thread.sleep(forTimeInterval: 0.6)
        policy.recordingEnded()
        waitOutGrace(policy, 0.8)
        #expect(media.callList == ["pause"])    // the (harmless) pause, and never a play
        #expect(media.isPlaying.isEmpty)
        #expect(diagnostics.entries().contains { $0.level == .warning && $0.message.contains("not remembered") })
    }

    @Test func anAlertThatEndsBeforeTheSecondLookSendsNothingAtAll() {
        let media = FakeMedia()
        media.realSleep = true
        media.retarget(spotify)
        media.blip(chrome, for: 0.05)           // gone long before the look 150 ms after the press
        let (policy, _) = makePolicy(media)
        policy.recordingStarted()
        Thread.sleep(forTimeInterval: 0.3)
        policy.recordingEnded()
        waitOutGrace(policy, 0.8)
        #expect(media.callList == [])
    }

    @Test func aPlayerThatStopsAfterTheStopWindowIsNotRemembered() {
        let media = FakeMedia()
        media.realSleep = true
        media.pauseDelay = 0.25                 // a slow player, or one process serving several tabs
        media.start(spotify)
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted()
        Thread.sleep(forTimeInterval: 0.7)
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
        media.realSleep = true
        media.playDelay = 0.08              // a slow player
        media.transientOnPlay = chrome      // a ding in the first look after Play
        media.start(spotify)
        let (policy, _) = makePolicy(media, watch: 100)
        policy.recordingStarted()
        Thread.sleep(forTimeInterval: 0.4)
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
