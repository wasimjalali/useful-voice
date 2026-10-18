import AppKit
import Testing
@testable import UsefulVoiceApp

/// Which of our own text fields may receive a dictation paste: only the main window's.
/// The language picker's search field must never get one.
@MainActor
@Suite("Own field focus")
struct OwnFieldFocusTests {
    private func window(editable: Bool, panel: Bool = false) -> NSWindow {
        let window: NSWindow = panel
            ? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                      styleMask: [.titled], backing: .buffered, defer: true)
            : NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                       styleMask: [.titled], backing: .buffered, defer: true)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        text.isEditable = editable
        window.contentView = text
        window.makeFirstResponder(text)
        return window
    }

    @Test func editableFieldInTheMainWindowCounts() {
        let main = window(editable: true)
        #expect(MainWindowController.editableFieldFocused(in: main, mainWindow: main))
    }

    @Test func aReadOnlyTextViewDoesNotCount() {
        let main = window(editable: false)
        #expect(!MainWindowController.editableFieldFocused(in: main, mainWindow: main))
    }

    @Test func theLanguagePickersSearchFieldDoesNotCount() {
        let main = window(editable: true)
        let picker = window(editable: true, panel: true)
        #expect(!MainWindowController.editableFieldFocused(in: picker, mainWindow: main))
    }

    @Test func aSheetOfTheMainWindowCounts() {
        let main = window(editable: true)
        let sheet = window(editable: true)
        main.beginSheet(sheet)
        defer { main.endSheet(sheet) }
        #expect(sheet.sheetParent === main)
        #expect(MainWindowController.editableFieldFocused(in: sheet, mainWindow: main))
    }

    @Test func aSheetOfAnotherWindowDoesNotCount() {
        let main = window(editable: true)
        let other = window(editable: true, panel: true)
        let sheet = window(editable: true)
        other.beginSheet(sheet)
        defer { other.endSheet(sheet) }
        #expect(!MainWindowController.editableFieldFocused(in: sheet, mainWindow: main))
    }

    @Test func noKeyWindowOrNoMainWindowDoesNotCount() {
        let main = window(editable: true)
        #expect(!MainWindowController.editableFieldFocused(in: nil, mainWindow: main))
        #expect(!MainWindowController.editableFieldFocused(in: main, mainWindow: nil))
    }
}
