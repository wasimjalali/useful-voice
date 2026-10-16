import AppKit
import Testing
@testable import UsefulVoiceApp

/// Which of our own first responders count as "an editable field of ours has focus", the
/// test that decides whether the hotkey pastes into Useful Voice or copies (window dictation).
@MainActor
@Suite("Own field focus")
struct OwnFieldFocusTests {
    @Test func anEditableTextViewCounts() {
        let view = NSTextView()
        view.isEditable = true
        #expect(AppDelegate.isEditableTextFocus(view))
    }

    @Test func aTextFieldsEditorCounts() {
        let field = NSTextField()
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.isEditable = true
        editor.delegate = field
        #expect(AppDelegate.isEditableTextFocus(editor))
    }

    @Test func aPasswordFieldsEditorDoesNot() {
        let field = NSSecureTextField()
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.isEditable = true
        editor.delegate = field            // weak: `field` stays alive until the end of the test
        #expect(!AppDelegate.isEditableTextFocus(editor))
        withExtendedLifetime(field) {}
    }

    @Test func aReadOnlyTextViewDoesNot() {
        let view = NSTextView()
        view.isEditable = false
        #expect(!AppDelegate.isEditableTextFocus(view))
    }

    @Test func noResponderOrANonTextResponderDoesNot() {
        #expect(!AppDelegate.isEditableTextFocus(nil))
        #expect(!AppDelegate.isEditableTextFocus(NSButton()))
    }
}
