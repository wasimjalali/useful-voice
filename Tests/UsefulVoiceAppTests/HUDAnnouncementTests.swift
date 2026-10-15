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
}
