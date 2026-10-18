import Testing
import Foundation
@testable import UsefulVoiceCore

/// A scripted system: some players are "playing", commands act on the Now Playing app
/// (the last one that started, like macOS) and every call is recorded in order.
private final class FakeMedia: MediaEffects, @unchecked Sendable {
    let lock = NSLock()
    private var playing: [MediaPlayerID] = []
    private var alive: Set<Int32> = []
    private(set) var calls: [String] = []
    /// What the system commands do. A command that "does nothing" models macOS refusing it.
    var commandsWork = true
    var keyWorks = true
    var outputError: Error?
    var pauseError: Error?
    var playError: Error?
    /// Called inside `outputtingPlayers`, to hold the queue or script a change.
    var onOutputQuery: (() -> Void)?
    private var queries = 0
    /// For the transient-alert test: how many queries see the players before they vanish.
    var vanishAfterQueries: Int?

    func start(_ player: MediaPlayerID) {
        lock.withLock {
            playing.append(player)
            alive.insert(player.pid)
        }
    }
    func stop(_ player: MediaPlayerID) { lock.withLock { playing.removeAll { $0 == player } } }
    func die(_ player: MediaPlayerID) {
        lock.withLock {
            playing.removeAll { $0 == player }
            alive.remove(player.pid)
        }
    }
    /// A paused player stays alive.
    private var nowPlaying: MediaPlayerID?

    func outputtingPlayers() throws -> [MediaPlayerID] {
        onOutputQuery?()
        return try lock.withLock {
            if let outputError { throw outputError }
            queries += 1
            if let vanishAfterQueries, queries > vanishAfterQueries { playing.removeAll() }
            return playing
        }
    }
    func isAlive(_ player: MediaPlayerID) -> Bool { lock.withLock { alive.contains(player.pid) } }
    func sendPause() throws {
        try lock.withLock {
            calls.append("pause")
            if let pauseError { throw pauseError }
            if commandsWork, let target = nowPlayingTarget { playing.removeAll { $0 == target } }
        }
    }
    func sendPlay() throws {
        try lock.withLock {
            calls.append("play")
            if let playError { throw playError }
            if commandsWork, let target = lastPaused, !playing.contains(target) { playing.append(target) }
        }
    }
    func sendPlayPauseKey() throws {
        lock.withLock {
            calls.append("key")
            guard keyWorks else { return }
            if let target = nowPlayingTarget { playing.removeAll { $0 == target } }
            else if let target = lastPaused { playing.append(target) }
        }
    }
    func sleep(_ seconds: TimeInterval) {}

    /// The player a command reaches: the most recently started one that is playing.
    private var nowPlayingTarget: MediaPlayerID? {
        let target = playing.last
        if let target { lastPaused = target }
        return target
    }
    private var lastPaused: MediaPlayerID?
    var callList: [String] { lock.withLock { calls } }
    var isPlaying: [MediaPlayerID] { lock.withLock { playing } }
}

private struct Boom: Error {}

private let spotify = MediaPlayerID(pid: 100, bundleID: "com.spotify.client")
private let chrome = MediaPlayerID(pid: 200, bundleID: "com.google.Chrome.helper")

private func makePolicy(
    _ media: FakeMedia,
    enabled: @escaping @Sendable () -> Bool = { true },
    grace: TimeInterval = 0.05
) -> (MediaPausePolicy, Diagnostics) {
    let diagnostics = Diagnostics(directory: nil)
    var timing = MediaPausePolicy.Timing()
    timing.resumeGrace = grace
    return (MediaPausePolicy(effects: media, isEnabled: enabled, diagnostics: diagnostics, timing: timing), diagnostics)
}

/// Waits for the resume job (it runs after the grace), up to 2 s.
private func settle(_ policy: MediaPausePolicy, _ condition: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, !condition() { Thread.sleep(forTimeInterval: 0.01) }
    policy.flush()
}

@Suite struct MediaPausePolicyTests {
    // 1. The setting
    @Test func settingOffNeverTouchesMedia() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, enabled: { false })
        policy.recordingStarted()
        policy.flush()
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 0.2); policy.flush()
        #expect(media.callList.isEmpty)
        #expect(media.isPlaying == [spotify])
    }

    @Test func settingIsReadAtEveryStart() {
        let media = FakeMedia()
        media.start(spotify)
        let enabled = Flag(true)
        let (policy, _) = makePolicy(media, enabled: { enabled.value })
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); settle(policy) { media.isPlaying == [spotify] && media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
        enabled.value = false
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause", "play"])   // second dictation left it alone
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

    // 2. Detect, pause only that, never delay the recording
    @Test func nothingPlayingSendsNothing() {
        let media = FakeMedia()
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); Thread.sleep(forTimeInterval: 0.15); policy.flush()
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
        #expect(Date().timeIntervalSince(began) < 0.1)   // the detection is parked on the gate
        gate.signal(); gate.signal(); gate.signal(); gate.signal()
        media.onOutputQuery = nil
        policy.flush()
    }

    // 3. Resume for every way a recording ends, only what we paused
    @Test func endingTwiceResumesOnce() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        Thread.sleep(forTimeInterval: 0.15); policy.flush()
        #expect(media.callList == ["pause", "play"])
    }

    @Test func aRecordingThatEndsBeforeDetectionFinishesNeverPauses() {
        let media = FakeMedia()
        media.start(spotify)
        let gate = DispatchSemaphore(value: 0)
        media.onOutputQuery = { _ = gate.wait(timeout: .now() + 5) }
        let (policy, _) = makePolicy(media)
        policy.recordingStarted()
        policy.recordingEnded()   // a start failure: the end comes at once
        media.onOutputQuery = nil
        gate.signal(); gate.signal(); gate.signal()
        Thread.sleep(forTimeInterval: 0.3); policy.flush()
        #expect(media.callList.isEmpty)
        #expect(media.isPlaying == [spotify])
    }

    @Test func doesNotResumeWhenTheUserRestartedThePlayer() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.start(spotify)   // the user pressed play mid-dictation
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 0.3); policy.flush()
        #expect(media.callList == ["pause"])
    }

    @Test func doesNotResumeWhenADifferentPlayerStarted() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.start(chrome)   // a video started meanwhile
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 0.3); policy.flush()
        #expect(media.callList == ["pause"])
        #expect(media.isPlaying == [chrome])
    }

    @Test func doesNotResumeWhenThePausedPlayerIsGone() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        media.die(spotify)
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 0.3); policy.flush()
        #expect(media.callList == ["pause"])
    }

    @Test func aPlayerTheUserPausedDuringTheDictationIsLeftAlone() {
        let media = FakeMedia()
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()   // nothing playing: we hold nothing
        media.start(spotify)    // the user plays something mid-dictation...
        media.stop(spotify)     // ...and pauses it again
        policy.recordingEnded()
        Thread.sleep(forTimeInterval: 0.3); policy.flush()
        #expect(media.callList.isEmpty)
    }

    // 4. Back to back
    @Test func aNewDictationDuringAPendingResumeKeepsTheMediaPaused() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 0.25)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded()
        policy.recordingStarted()   // inside the grace window
        policy.flush()
        Thread.sleep(forTimeInterval: 0.5); policy.flush()
        #expect(media.callList == ["pause"])   // no resume, no second pause
        policy.recordingEnded()
        settle(policy) { media.callList.contains("play") }
        #expect(media.callList == ["pause", "play"])
    }

    @Test func aSecondStartWithoutAnEndDoesNotPauseTwice() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause"])
    }

    // 5. Quit
    @Test func quittingWhilePausedResumesBeforeReturning() {
        let media = FakeMedia()
        media.start(spotify)
        let (policy, _) = makePolicy(media, grace: 5)
        policy.recordingStarted(); policy.flush()
        policy.shutdown()   // synchronous: no waiting for the grace
        #expect(media.callList == ["pause", "play"])
        #expect(media.isPlaying == [spotify])
    }

    // 6. Failures are logged, never thrown
    @Test func aFailingDetectionIsLoggedAndSwallowed() {
        let media = FakeMedia()
        media.outputError = Boom()
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); Thread.sleep(forTimeInterval: 0.15); policy.flush()
        let entries = diagnostics.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.category == "media")
        #expect(entries.first?.level == .error)
    }

    @Test func aFailingPauseCommandIsLoggedAndHoldsNothing() {
        let media = FakeMedia()
        media.start(spotify)
        media.pauseError = Boom()
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); Thread.sleep(forTimeInterval: 0.15); policy.flush()
        #expect(diagnostics.entries().contains { $0.category == "media" && $0.level == .error })
        #expect(media.callList == ["pause"])   // nothing held, nothing resumed
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

    // Fallback to the media key
    @Test func fallsBackToTheMediaKeyWhenTheCommandIsIgnored() {
        let media = FakeMedia()
        media.start(spotify)
        media.commandsWork = false
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        #expect(media.callList == ["pause", "key"])
        #expect(media.isPlaying.isEmpty)
        policy.recordingEnded()
        settle(policy) { media.callList.count >= 4 }
        #expect(media.callList == ["pause", "key", "play", "key"])
        #expect(media.isPlaying == [spotify])
    }

    @Test func givesUpAndHoldsNothingWhenNothingCanPause() {
        let media = FakeMedia()
        media.start(spotify)
        media.commandsWork = false
        media.keyWorks = false
        let (policy, diagnostics) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        policy.recordingEnded(); Thread.sleep(forTimeInterval: 0.2); policy.flush()
        #expect(media.callList == ["pause", "key"])
        #expect(diagnostics.entries().contains { $0.level == .warning && $0.category == "media" })
    }

    // Short sounds are not media
    @Test func aSoundThatEndsBeforeTheSecondLookIsNotPaused() {
        let media = FakeMedia()
        media.start(chrome)
        media.vanishAfterQueries = 1   // an alert: there on the first look, gone on the second
        let (policy, _) = makePolicy(media)
        policy.recordingStarted(); policy.flush()
        #expect(media.callList.isEmpty)
    }

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
