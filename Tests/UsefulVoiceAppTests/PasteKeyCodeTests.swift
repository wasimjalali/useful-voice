import Testing
@testable import UsefulVoiceApp

@MainActor
@Suite("Paste key code")
struct PasteKeyCodeTests {
    /// The real layout lookup on this Mac: a valid key code, the same on a second
    /// call (the per-layout cache). The search over a layout is covered in
    /// KeyCodeSearchTests with scripted layouts.
    @Test func currentLayoutResolvesToAValidStableKey() {
        let first = PasteKeyCode.current()
        #expect(first < 128)
        #expect(PasteKeyCode.current() == first)
        print("PasteKeyCode.current() on this Mac:", first)
    }
}
