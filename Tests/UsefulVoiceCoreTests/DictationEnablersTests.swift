import Testing
import Foundation
import Combine
@testable import UsefulVoiceCore

// WAYS THIS CAN FAIL (written before the code; each line names the test that pins it)
//
// Source and delivery mode (DictationControllerTests)
//  1. A window start pastes into the frontmost app, which may be Useful Voice itself.
//     -> testWindowStartDeliversByCopyWithoutAppName
//  2. A hotkey start loses its app name, or looks the app up for a window start.
//     -> testHotkeyStartPastesAndNamesTheApp
//  3. The stop toggle (hotkey stopping a window dictation, or the reverse) rewrites the
//     source chosen at start. -> testStopToggleNeverChangesTheSourceChosenAtStart
//  4. The auto-stop (which calls toggle() with the default hotkey source) rewrites it.
//     -> testAutoStopKeepsTheSourceChosenAtStart
//  5. A late auto-stop, queued before a manual stop, starts a new recording or stops the
//     next one. -> testAutoStopAfterManualStopDoesNotStartAnotherRecording, and in the
//     recorder the auto-stop is dropped unless its session is still the live one.
//  6. The source of a finished or failed dictation leaks into the next one.
//     -> testSourceDoesNotLeakIntoTheNextDictation, ...PastAWindowDictationThatFailed
//  7. A failed start (mic denied) records a source that a later stop then uses.
//     -> testStartFailureDoesNotCaptureASource
//  8. Retry pastes because the original was a hotkey dictation, or names an app.
//     -> testRetryAlwaysCopiesWhateverStartedTheOriginal
//  9. Retry runs while a new recording is in progress. -> testRetryWhileRecordingIsIgnored
//
// Outcomes
// 10. The outcome fires before the history record, or after the state is already idle, so a
//     listener that renders "done" sees idle first. -> testOutcomeIsPublishedAfterTheRecord...
// 11. A completion called twice fires the outcome twice or ends the next delivery.
//     -> testDeliveryCompletionFiresTheOutcomeOnlyOnce, testStaleCompletion...
// 12. Esc during delivering cancels, or fires a cancelled outcome after the text went out.
//     -> testEscDuringDeliveringIsIgnored
// 13. cancel() outside recording (idle, transcribing) fires an outcome, or fires twice.
//     -> testCancelPublishesOneCancelledOutcomeBeforeIdle, testCancelOutsideRecording...
// 14. An auto-stop after a cancel starts or stops something. -> testAutoStopAfterCancelIsIgnored
// 15. An error publishes an outcome. -> testNoOutcomeFiresForErrors
// 16. Word count special-cases scripts or counts empty tokens. -> testWordCountIs...
// 17. A new toggle during delivering starts a recording mid-paste. -> testNewToggleIsIgnored...
//
// Typed errors
// 18. A provider failure is mapped to the wrong kind (a 401 shown as offline, a TLS error as
//     offline, a timeout as a generic failure), or its message text changes.
//     -> testTranscriptionFailuresAreTypedWithTheirFixAndTheOldMessage
// 19. .retry is offered when no audio was kept. -> testErrorsWithoutRetainedAudioNeverOfferRetry
// 20. Errors that are not ProviderError (a bare URLError) fall to the wrong kind.
//     -> testNonProviderTransportErrorIsClassifiedToo
//
// Issue and outcome state for the window (DictationFeedback, below)
// 21. An old error stays on screen after the next recording, a retry or a delivery starts.
// 22. A copied-not-pasted notice is cleared by the idle that follows it, or is raised for a
//     plain paste or a copy-mode delivery.
// 23. dismissIssue() clears the outcome too, or the next error cannot set it again.
//
// Telemetry (below)
// 24. Level, timer or a countdown stays non-nil after an error, idle or cancel.
// 25. A tick or a partial queued before the phase changed brings stale data back.
// 26. An unchanged value republishes, redrawing the dock 30 times a second for nothing.
// 27. "Stops in 5 s" shows early, shows negative, or is never shown (rounding).
// 28. The silence deadline moves while the user is silent, or ignores a reset by speech.
// 29. A deadline from a finished session stays readable (AudioRecorder clears it on
//     stop/cancel; the reading side is a lock-guarded snapshot, never the watchdog).
//
// Clipboard (App layer, no unit tests there; verified by reading the code path)
// 30. Copy mode restores the user's old clipboard over the copy it just wrote, or posts a
//     paste. Copy mode only calls Clipboard.writeString, never snapshot/restore/Cmd-V, and
//     the controller stays in .delivering until it returns.

@Suite struct DictationFeedbackTests {
    private let hotkeyError = DictationError(kind: .providerFailed, message: "boom", fix: .retry)

    @Test func testErrorStateRaisesTheIssue() {
        var feedback = DictationFeedback()
        feedback.apply(state: .error(hotkeyError))
        #expect(feedback.issue == .error(hotkeyError))
        #expect(feedback.issue?.fix == .retry)
        #expect(feedback.issue?.message == "boom")
    }

    @Test func testTheNextRecordingTranscribingOrDeliveringClearsTheOldResult() {
        for next in [DictationState.recording, .transcribing, .delivering] {
            var feedback = DictationFeedback()
            feedback.apply(state: .error(hotkeyError))
            feedback.apply(outcome: .cancelled)
            feedback.apply(state: next)
            #expect(feedback.issue == nil, "\(next)")
            #expect(feedback.outcome == nil, "\(next)")
        }
    }

    @Test func testCopiedNotPastedRaisesTheNoticeAndSurvivesTheIdleThatFollows() {
        var feedback = DictationFeedback()
        feedback.apply(state: .recording)
        feedback.apply(state: .transcribing)
        feedback.apply(state: .delivering)
        feedback.apply(outcome: .delivered(words: 3, mode: .copiedNotPasted, appName: "Slack"))
        feedback.apply(state: .idle)
        #expect(feedback.issue == .copiedNotPasted)
        #expect(feedback.issue?.fix == .openAccessibilitySettings)
        #expect(feedback.issue?.message == "Copied. Press \u{2318}V to paste.")
        #expect(feedback.outcome == .delivered(words: 3, mode: .copiedNotPasted, appName: "Slack"))
    }

    @Test func testAppChangedCopyRaisesANoticeWithNoAccessibilityFix() {
        var feedback = DictationFeedback()
        feedback.apply(state: .delivering)
        feedback.apply(outcome: .delivered(words: 3, mode: .copiedAppChanged, appName: "Slack"))
        feedback.apply(state: .idle)
        #expect(feedback.issue == .copiedAppChanged)
        #expect(feedback.issue?.fix == nil)
        #expect(feedback.issue?.message == "Copied. Press \u{2318}V to paste.")
        #expect(DictationIssue.copiedNotPasted.fix == .openAccessibilitySettings)
    }

    @Test func testSecureFieldCopyRaisesANoticeWithNoFix() {
        var feedback = DictationFeedback()
        feedback.apply(state: .delivering)
        feedback.apply(outcome: .delivered(words: 3, mode: .copiedSecureField, appName: "Safari"))
        feedback.apply(state: .idle)
        #expect(feedback.issue == .copiedSecureField)
        #expect(feedback.issue?.fix == nil)
        #expect(feedback.issue?.message == "Copied. Press \u{2318}V to paste.")
    }

    @Test func testPlainPasteAndCopyRaiseNoIssue() {
        for mode in [DeliveryResult.pasted, .copied] {
            var feedback = DictationFeedback()
            feedback.apply(state: .delivering)
            feedback.apply(outcome: .delivered(words: 2, mode: mode, appName: nil))
            feedback.apply(state: .idle)
            #expect(feedback.issue == nil)
            #expect(feedback.outcome == .delivered(words: 2, mode: mode, appName: nil))
        }
    }

    @Test func testDismissClearsOnlyTheIssueAndALaterErrorRaisesItAgain() {
        var feedback = DictationFeedback()
        feedback.apply(state: .delivering)
        feedback.apply(outcome: .delivered(words: 1, mode: .copiedNotPasted, appName: nil))
        feedback.dismissIssue()
        #expect(feedback.issue == nil)
        #expect(feedback.outcome != nil)
        feedback.apply(state: .error(hotkeyError))
        #expect(feedback.issue == .error(hotkeyError))
    }

    @Test func testCancelledOutcomeRaisesNoIssue() {
        var feedback = DictationFeedback()
        feedback.apply(state: .recording)
        feedback.apply(outcome: .cancelled)
        feedback.apply(state: .idle)
        #expect(feedback.issue == nil)
        #expect(feedback.outcome == .cancelled)
    }

    @Test func testStartingFromAnErrorStateClearsItEvenWithoutAnIdleBetween() {
        var feedback = DictationFeedback()
        feedback.apply(state: .error(hotkeyError))
        feedback.apply(state: .recording)
        #expect(feedback.issue == nil)
    }
}

@Suite struct AutoStopDeadlineTests {
    @Test func testWatchdogDeadlineIsNilUntilTheFirstSampleThenSeedsFromIt() {
        var watchdog = SilenceWatchdog(threshold: 0.01, timeout: 60)
        #expect(watchdog.silenceDeadline == nil)
        _ = watchdog.observe(rms: 0.001, at: 2)          // a quiet first sample seeds the clock
        #expect(watchdog.silenceDeadline == 62)
    }

    @Test func testDeadlineHoldsStillWhileQuietAndMovesOnSpeech() {
        var watchdog = SilenceWatchdog(threshold: 0.01, timeout: 60)
        _ = watchdog.observe(rms: 0.5, at: 0)
        #expect(watchdog.silenceDeadline == 60)
        _ = watchdog.observe(rms: 0.001, at: 20)
        _ = watchdog.observe(rms: 0.001, at: 40)
        #expect(watchdog.silenceDeadline == 60)
        _ = watchdog.observe(rms: 0.5, at: 45)           // speech resets it
        #expect(watchdog.silenceDeadline == 105)
    }

    @Test func testDeadlinesAreAbsoluteDates() {
        var watchdog = SilenceWatchdog(threshold: 0.01, timeout: 60)
        _ = watchdog.observe(rms: 0.5, at: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        let deadlines = AutoStopDeadlines(startedAt: start, watchdog: watchdog, maxDuration: 600)
        #expect(deadlines.silence == Date(timeIntervalSince1970: 1_070))
        #expect(deadlines.max == Date(timeIntervalSince1970: 1_600))
        let before = AutoStopDeadlines(startedAt: start, watchdog: SilenceWatchdog(timeout: 60),
                                       maxDuration: 600)
        #expect(before.silence == nil)
        #expect(before.max == Date(timeIntervalSince1970: 1_600))
        #expect(AutoStopDeadlines.none.silence == nil && AutoStopDeadlines.none.max == nil)
    }

    @Test func testCountdownShowsOnlyTheLastFiveSecondsRoundedUp() {
        let now = Date(timeIntervalSince1970: 5_000)
        func seconds(_ remaining: TimeInterval?) -> Int? {
            AutoStopCountdown.seconds(until: remaining.map { now.addingTimeInterval($0) }, now: now)
        }
        #expect(seconds(nil) == nil)
        #expect(seconds(60) == nil)
        #expect(seconds(5.01) == nil)
        #expect(seconds(5) == 5)
        #expect(seconds(4.2) == 5)
        #expect(seconds(1.01) == 2)
        #expect(seconds(0.2) == 1)
        #expect(seconds(0) == 0)
        #expect(seconds(-3) == 0)
    }
}

@MainActor @Suite struct DictationTelemetryTests {
    private func emissions(_ telemetry: DictationTelemetry) -> () -> Int {
        var count = 0
        let cancellable = telemetry.objectWillChange.sink { count += 1 }
        // Keep the subscription alive for the lifetime of the closure.
        return { _ = cancellable; return count }
    }

    private let now = Date(timeIntervalSince1970: 10_000)
    private func near(_ silence: TimeInterval?, max: TimeInterval? = nil) -> AutoStopDeadlines {
        AutoStopDeadlines(silence: silence.map { now.addingTimeInterval($0) },
                          max: max.map { now.addingTimeInterval($0) })
    }

    @Test func testRecordingStartsFromZeroAndTicksFeedTheNumbers() {
        let telemetry = DictationTelemetry()
        telemetry.apply(state: .recording)
        telemetry.tick(elapsed: 7, level: 0.4, deadlines: near(3, max: 4.2), now: now)
        #expect(telemetry.elapsedSeconds == 7)
        #expect(telemetry.level == 0.4)
        #expect(telemetry.silenceRemaining == 3)
        #expect(telemetry.maxRemaining == 5)
        telemetry.tick(elapsed: 8, level: 0.1, deadlines: near(30), now: now)
        #expect(telemetry.silenceRemaining == nil)
        #expect(telemetry.maxRemaining == nil)
    }

    @Test func testLeavingRecordingDropsLevelAndCountdownsButKeepsNothingLive() {
        let telemetry = DictationTelemetry()
        telemetry.apply(state: .recording)
        telemetry.tick(elapsed: 9, level: 0.7, deadlines: near(2), now: now)
        telemetry.apply(state: .transcribing)
        #expect(telemetry.level == 0)
        #expect(telemetry.silenceRemaining == nil)
        #expect(telemetry.maxRemaining == nil)
    }

    @Test func testErrorAndIdleClearEverything() {
        for end in [DictationState.idle,
                    .error(DictationError(kind: .noSpeech, message: "x"))] {
            let telemetry = DictationTelemetry()
            telemetry.apply(state: .recording)
            telemetry.tick(elapsed: 12, level: 0.9, deadlines: near(1, max: 1), now: now)
            telemetry.apply(state: .transcribing)
            telemetry.setPartial("hello wor")
            telemetry.apply(state: end)
            #expect(telemetry.elapsedSeconds == 0)
            #expect(telemetry.level == 0)
            #expect(telemetry.localPartial == nil)
            #expect(telemetry.silenceRemaining == nil)
            #expect(telemetry.maxRemaining == nil)
        }
    }

    @Test func testALateTickAfterTheRecordingEndedIsDropped() {
        let telemetry = DictationTelemetry()
        telemetry.apply(state: .recording)
        telemetry.apply(state: .transcribing)
        telemetry.tick(elapsed: 5, level: 0.8, deadlines: near(1), now: now)
        #expect(telemetry.level == 0)
        #expect(telemetry.silenceRemaining == nil)
        telemetry.apply(state: .idle)
        telemetry.tick(elapsed: 5, level: 0.8, deadlines: near(1), now: now)
        #expect(telemetry.elapsedSeconds == 0)
    }

    @Test func testPartialsLiveOnlyWhileTranscribing() {
        let telemetry = DictationTelemetry()
        telemetry.setPartial("too early")
        #expect(telemetry.localPartial == nil)
        telemetry.apply(state: .recording)
        telemetry.setPartial("still recording")
        #expect(telemetry.localPartial == nil)
        telemetry.apply(state: .transcribing)
        telemetry.setPartial("hello")
        telemetry.setPartial("hello world")
        #expect(telemetry.localPartial == "hello world")
        telemetry.apply(state: .delivering)       // the record is already in history
        #expect(telemetry.localPartial == nil)
        telemetry.setPartial("late partial")      // a callback that hopped threads
        #expect(telemetry.localPartial == nil)
    }

    @Test func testANewTranscriptionStartsWithoutTheLastPartial() {
        let telemetry = DictationTelemetry()
        telemetry.apply(state: .transcribing)
        telemetry.setPartial("old")
        telemetry.apply(state: .error(DictationError(kind: .providerFailed, message: "x", fix: .retry)))
        telemetry.apply(state: .transcribing)     // a retry
        #expect(telemetry.localPartial == nil)
    }

    @Test func testUnchangedValuesDoNotRepublish() {
        let telemetry = DictationTelemetry()
        telemetry.apply(state: .recording)
        telemetry.tick(elapsed: 1, level: 0.3, deadlines: near(2), now: now)
        let count = emissions(telemetry)
        telemetry.tick(elapsed: 1, level: 0.3, deadlines: near(2), now: now)
        telemetry.tick(elapsed: 1, level: 0.3, deadlines: near(2), now: now)
        #expect(count() == 0)
        telemetry.tick(elapsed: 1, level: 0.5, deadlines: near(2), now: now)
        #expect(count() == 1)
        telemetry.setPartial("x")                 // ignored while recording
        #expect(count() == 1)
    }
}
