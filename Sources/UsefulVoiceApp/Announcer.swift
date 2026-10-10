import AppKit

/// Speaks HUD state changes to VoiceOver. The HUD panel never takes focus, so
/// nothing would announce it: the app posts an NSAccessibility announcement on
/// each change of state instead (UV-037).
@MainActor
enum Announcer {
    /// An announcement and how urgently it should interrupt: errors are high.
    struct Message: Equatable {
        let text: String
        let urgent: Bool
    }

    static func message(for display: HUDDisplay) -> Message? {
        switch display {
        case .recording: return Message(text: "Recording", urgent: false)
        case .transcribing(_, let local):
            return Message(text: local ? "Transcribing locally" : "Transcribing", urgent: false)
        // Inserting is held for as long as the paste takes: the result follows at once.
        case .delivering: return nil
        case .done(let done):
            if let words = done.wordsText { return Message(text: "\(done.label), \(words)", urgent: false) }
            return Message(text: done.label, urgent: false)
        case .copiedNotPasted:
            return Message(text: "Copied. Press Command V to paste", urgent: true)
        case .cancelled: return Message(text: "Cancelled", urgent: false)
        case .error(let error): return Message(text: error.message, urgent: true)
        case .language(let pin): return Message(text: "Language, \(pin.hudName)", urgent: false)
        }
    }

    static func post(_ message: Message) {
        let priority: NSAccessibilityPriorityLevel = message.urgent ? .high : .medium
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message.text,
                .priority: priority.rawValue,
            ])
    }
}
