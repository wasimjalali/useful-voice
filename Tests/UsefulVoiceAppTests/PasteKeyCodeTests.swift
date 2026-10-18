import CoreGraphics
import Testing
import UsefulVoiceCore
@testable import UsefulVoiceApp

@MainActor
@Suite("Paste key code", .serialized)
struct PasteKeyCodeTests {
    /// The real layout lookup on this Mac: a valid key code, the same on a second
    /// call (the per-layout cache). The search over a layout is covered in
    /// KeyCodeSearchTests with scripted layouts.
    @Test func currentLayoutResolvesToAValidStableKey() {
        PasteKeyCode.resetForTesting()
        let diagnostics = Diagnostics(directory: nil)
        let first = PasteKeyCode.current(diagnostics: diagnostics)
        #expect(first < 128)
        #expect(PasteKeyCode.current(diagnostics: diagnostics) == first)
        print("PasteKeyCode.current() on this Mac:", first)
    }

    @Test func aLayoutWithoutLayoutDataFallsBackToKeyNineAndWarnsOncePerLayout() {
        PasteKeyCode.resetForTesting()
        let diagnostics = Diagnostics(directory: nil)
        var lookups = 0
        func lookup(_ id: String) -> CGKeyCode {
            PasteKeyCode.keyCode(forLayout: id, diagnostics: diagnostics) { lookups += 1; return nil }
        }
        #expect(lookup("com.apple.keylayout.Test") == 9)
        #expect(lookup("com.apple.keylayout.Test") == 9)
        #expect(lookups == 1, "the miss is cached")
        #expect(diagnostics.entries(level: .warning).count == 1)
        #expect(diagnostics.entries(level: .warning)[0].message.contains("com.apple.keylayout.Test"))
        #expect(lookup("com.apple.keylayout.Other") == 9)
        #expect(diagnostics.entries(level: .warning).count == 2)
    }

    @Test func aFoundKeyLogsNothing() {
        PasteKeyCode.resetForTesting()
        let diagnostics = Diagnostics(directory: nil)
        #expect(PasteKeyCode.keyCode(forLayout: "dvorak", diagnostics: diagnostics) { 47 } == 47)
        #expect(diagnostics.entries(level: .warning).isEmpty)
    }
}
