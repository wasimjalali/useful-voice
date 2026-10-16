import Testing
@testable import UsefulVoiceApp

/// The app layer's own cap on the text-before-cursor read (the controller waits at most
/// 0.3 s for it, see `AppAwareDictationTests.theCursorReadCapsArePinned`).
@MainActor
struct CursorReadBudgetTests {
    @Test func theAppLayerCapsItsReadAt150Milliseconds() {
        #expect(FocusTracker.cursorReadBudget == 0.15)
    }
}
