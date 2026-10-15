import Testing
import UsefulVoiceCore
@testable import UsefulVoiceApp

/// What VoiceOver is told for each HUD state (UV-037), and that the recording timer is
/// not read out every second. The HUD panel never takes focus, so `Announcer` posts
/// these as NSAccessibility announcements; the text is decided here.
@MainActor
@Suite("HUD announcements")
struct HUDAnnouncementTests {
    private func said(_ display: HUDDisplay) -> Announcer.Message? {
        Announcer.message(for: display)
    }

    @Test func eachStateHasItsAnnouncement() {
        #expect(said(.recording(seconds: 0, level: 0, stopsIn: nil)) == .init(text: "Recording", urgent: false))
        #expect(said(.transcribing(partial: nil, local: false)) == .init(text: "Transcribing", urgent: false))
        #expect(said(.transcribing(partial: "hello", local: true)) == .init(text: "Transcribing locally", urgent: false))
        #expect(said(.done(.inserted(words: 24))) == .init(text: "Inserted, 24 words", urgent: false))
        #expect(said(.done(.savedAndCopied(words: 1))) == .init(text: "Saved and copied, 1 word", urgent: false))
        #expect(said(.done(.reprocessed)) == .init(text: "Reprocessed", urgent: false))
        #expect(said(.copiedNotPasted(fix: nil)) == .init(text: "Copied. Press Command V to paste", urgent: true))
        #expect(said(.cancelled) == .init(text: "Cancelled", urgent: false))
        #expect(said(.language(.de))?.urgent == false)
        #expect(said(.language(.de))?.text.hasPrefix("Language, ") == true)
    }

    /// Inserting lasts as long as the paste takes and the result follows at once.
    @Test func insertingSaysNothing() {
        #expect(said(.delivering) == nil)
    }

    @Test func anErrorIsSpokenUrgently() {
        let error = HUDDisplay.error(HUDError(message: "No connection"))
        #expect(said(error) == .init(text: "No connection", urgent: true))
    }

    /// The label carries "Recording, 0:12" for anyone exploring the HUD; the announcement
    /// is the same word whatever the clock says, so the ticking timer is never spoken.
    @Test func theRecordingTimerIsInTheLabelAndNeverInTheAnnouncement() {
        let early = HUDDisplay.recording(seconds: 3, level: 0.2, stopsIn: nil)
        let late = HUDDisplay.recording(seconds: 12, level: 0.9, stopsIn: nil)
        #expect(early.accessibilityLabel == "Recording, 0:03")
        #expect(late.accessibilityLabel == "Recording, 0:12")
        #expect(said(early) == said(late))
        #expect(said(late)?.text.contains(":") == false)
    }

    @Test func theCountdownIsInTheLabel() {
        let display = HUDDisplay.recording(seconds: 55, level: 0, stopsIn: 5)
        #expect(display.accessibilityLabel == "Recording, 0:55, stops in 5 seconds")
    }

    @Test func labelsMatchTheAnnouncementsForTheQuickStates() {
        for display in [HUDDisplay.cancelled, .done(.inserted(words: 3)), .copiedNotPasted(fix: nil),
                        .transcribing(partial: nil, local: false)] {
            #expect(display.accessibilityLabel == said(display)?.text)
        }
    }

    // MARK: How long each state stays (UV-022)

    /// Done, language and cancelled go on their own; an error and the Copied notice wait
    /// for the user for 8 s; the dictation itself has no timer.
    @Test func eachStateStaysForItsOwnTime() {
        #expect(HUDDisplay.recording(seconds: 0, level: 0, stopsIn: nil).lifetime == nil)
        #expect(HUDDisplay.transcribing(partial: nil, local: false).lifetime == nil)
        #expect(HUDDisplay.delivering.lifetime == nil)
        #expect(HUDDisplay.done(.inserted(words: 1)).lifetime == 1.2)
        #expect(HUDDisplay.language(.de).lifetime == 1.0)
        #expect(HUDDisplay.cancelled.lifetime == 1.5)
        #expect(HUDDisplay.copiedNotPasted(fix: nil).lifetime == 8)
        #expect(HUDDisplay.error(HUDError(message: "No connection")).lifetime == 8)
    }

    /// Only the two that wait for the user carry a close button.
    @Test func onlyAnErrorAndTheCopiedNoticeArePersistent() {
        #expect(HUDDisplay.copiedNotPasted(fix: nil).isPersistent)
        #expect(HUDDisplay.error(HUDError(message: "x")).isPersistent)
        #expect(!HUDDisplay.cancelled.isPersistent)
        #expect(!HUDDisplay.done(.savedAndCopied(words: 2)).isPersistent)
        #expect(!HUDDisplay.recording(seconds: 1, level: 0, stopsIn: nil).isPersistent)
    }

    /// A state that is still in flight is what a stray hide must not leave behind.
    @Test func inFlightStatesAreProgress() {
        #expect(HUDDisplay.recording(seconds: 1, level: 0, stopsIn: nil).isProgress)
        #expect(HUDDisplay.transcribing(partial: nil, local: false).isProgress)
        #expect(HUDDisplay.delivering.isProgress)
        #expect(!HUDDisplay.error(HUDError(message: "x")).isProgress)
        #expect(!HUDDisplay.done(.inserted(words: 1)).isProgress)
    }

    /// The pill carries one fix verb, and the HUD error carries the typed error's fix.
    @Test func anErrorKeepsItsFixAndTheFixHasAVerb() {
        let typed = DictationError(kind: .offline, message: "Could not reach Deepgram.", fix: .retry)
        let error = HUDDisplay.error(HUDError(typed))
        #expect(error.fix == .retry)
        #expect(DictationFix.retry.hudTitle == "Retry last recording")
        #expect(DictationFix.openMicrophoneSettings.hudTitle == "Open settings")
        #expect(DictationFix.openEngineSettings.hudTitle == "Open settings")
        #expect(HUDDisplay.copiedNotPasted(fix: .openAccessibilitySettings).fix == .openAccessibilitySettings)
        #expect(HUDDisplay.copiedNotPasted(fix: nil).fix == nil)
    }
}
