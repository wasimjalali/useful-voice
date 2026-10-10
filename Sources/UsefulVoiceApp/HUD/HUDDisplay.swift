import AppKit
import Foundation
import UsefulVoiceCore

/// Display-only state for the HUD. Richer than DictationState on purpose
/// (recording carries seconds and level, done carries a word count), so new
/// display-only cases land here, not in the controller state machines.
enum HUDDisplay: Equatable {
    /// `stopsIn` is the whole seconds until the recording ends on its own, nil
    /// until 5 s or less remain.
    case recording(seconds: Int, level: Float, stopsIn: Int?)
    /// Local transcription emits segments as they decode; `partial` is the latest
    /// one. `local` picks the label ("Transcribing locally") and the bubble.
    case transcribing(partial: String?, local: Bool)
    case delivering
    case done(HUDDone)
    /// The text is on the clipboard but could not be pasted.
    case copiedNotPasted
    case cancelled
    case error(HUDError)
    /// A confirmation that the dictation language was switched.
    case language(LanguagePin)
}

/// A finished dictation. `words` is nil for a reprocess, which has no count.
struct HUDDone: Equatable {
    let label: String
    let words: Int?

    static func inserted(words: Int) -> HUDDone { HUDDone(label: "Inserted", words: words) }
    static func savedAndCopied(words: Int) -> HUDDone { HUDDone(label: "Saved and copied", words: words) }
    static let reprocessed = HUDDone(label: "Reprocessed", words: nil)

    /// "24 words" with the German-region thousands separator (77.974 words).
    var wordsText: String? {
        guard let words else { return nil }
        let number = Self.formatter.string(from: NSNumber(value: words)) ?? "\(words)"
        return words == 1 ? "1 word" : "\(number) words"
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        return formatter
    }()
}

/// One line and at most one fix verb. The line is short on purpose: the full
/// text stays in the window and the menu.
struct HUDError: Equatable {
    let message: String
    /// SF Symbol drawn in front of the line.
    let symbol: String
    let fix: DictationFix?

    init(message: String, symbol: String = "exclamationmark.triangle", fix: DictationFix? = nil) {
        self.message = message
        self.symbol = symbol
        self.fix = fix
    }

    init(_ error: DictationError) {
        fix = error.fix
        switch error.kind {
        case .offline:
            message = "No connection"
            symbol = "wifi.slash"
        case .micUnavailable:
            message = "Microphone access is off"
            symbol = "mic.slash"
        case .secureField:
            message = "Dictation is off in password fields"
            symbol = "lock"
        case .stopFailed:
            message = "Couldn't stop recording"
            symbol = "exclamationmark.triangle"
        case .noSpeech:
            message = "No speech detected"
            symbol = "waveform.slash"
        case .tooShort:
            message = "Recording was too short"
            symbol = "exclamationmark.triangle"
        case .noProvider:
            message = "No engine set up"
            symbol = "exclamationmark.triangle"
        case .keyRejected:
            message = "Deepgram key was rejected"
            symbol = "key"
        case .outOfCredits:
            message = "Deepgram is out of credits"
            symbol = "exclamationmark.triangle"
        case .timedOut:
            message = "Transcription timed out"
            symbol = "clock"
        case .providerFailed, .engineFailed:
            message = "Transcription failed"
            symbol = "exclamationmark.triangle"
        }
    }
}

extension DictationFix {
    /// The one verb the HUD pill carries. System Settings panes and the app's
    /// own engine settings are both "Open settings".
    var hudTitle: String {
        switch self {
        case .retry: return "Retry last recording"
        case .openMicrophoneSettings, .openAccessibilitySettings, .openEngineSettings:
            return "Open settings"
        }
    }
}

extension HUDDisplay {
    /// How long the HUD stays after it is shown, or nil while the state is the
    /// dictation itself (recording, transcribing, inserting). Errors and
    /// "Copied" outlast the quick states so they can be read and acted on; the
    /// fix stays reachable in the window and the menu after they go.
    var lifetime: TimeInterval? {
        switch self {
        case .recording, .transcribing, .delivering: return nil
        case .done: return 1.2
        case .language: return 1.0
        case .cancelled: return 1.5
        case .copiedNotPasted, .error: return 8
        }
    }

    /// A state that holds until something replaces it or its timer runs out, so
    /// it carries a close button.
    var isPersistent: Bool {
        switch self {
        case .copiedNotPasted, .error: return true
        default: return false
        }
    }

    /// The fix verb the pill carries, if any.
    var fix: DictationFix? {
        switch self {
        case .copiedNotPasted: return .openAccessibilitySettings
        case .error(let error): return error.fix
        default: return nil
        }
    }

    /// True while the dictation is in flight, so a stray hide cannot leave a
    /// stale "Recording" on screen.
    var isProgress: Bool {
        switch self {
        case .recording, .transcribing, .delivering: return true
        default: return false
        }
    }

    /// A coarse identity for the kind of state, so the content cross-fades when
    /// the kind changes but not as the timer and level tick or partial text grows.
    var phase: Int {
        switch self {
        case .recording: return 0
        case .transcribing(let partial, _): return partial == nil ? 1 : 2
        case .delivering: return 3
        case .done: return 4
        case .copiedNotPasted: return 5
        case .cancelled: return 6
        case .error: return 7
        case .language: return 8
        }
    }

    /// The bubble that grows upward for local partial text.
    var isBubble: Bool {
        if case .transcribing(let partial, _) = self { return partial != nil }
        return false
    }

    /// The accessible label of the whole HUD. The recording one carries the
    /// elapsed time ("Recording, 0:12"); the ticking timer itself is not a live
    /// region, state changes are announced through `Announcer` instead.
    var accessibilityLabel: String {
        switch self {
        case .recording(let seconds, _, let stopsIn):
            var label = "Recording, \(HUDView.timecode(seconds))"
            if let stopsIn { label += ", stops in \(stopsIn) seconds" }
            return label
        case .transcribing(_, let local): return local ? "Transcribing locally" : "Transcribing"
        case .delivering: return "Inserting"
        case .done(let done):
            if let words = done.wordsText { return "\(done.label), \(words)" }
            return done.label
        case .copiedNotPasted: return "Copied. Press Command V to paste"
        case .cancelled: return "Cancelled"
        case .error(let error): return error.message
        case .language(let pin): return "Language, \(pin.hudName)"
        }
    }
}

extension LanguagePin {
    /// The name the HUD and the menu show: the language's own name, so a speaker
    /// recognises it without translating.
    var hudName: String {
        if isAuto { return "Auto-detect" }
        if isMultilingual { return "Multiple languages" }
        return nativeName ?? displayName
    }
}

/// Keeps the newest words of a live partial visible.
enum HUDPartial {
    static let font = NSFont.systemFont(ofSize: 13)
    static let ellipsis = "\u{2026}"
    /// 1,45 times the 13 pt size, as the board sets the live words.
    static let lineHeight: CGFloat = 19

    /// The ending of `text` that fits `lines` lines of `width`, cut at a word
    /// start and prefixed with an ellipsis. The cut is on the logical start of
    /// the text, so for a right-to-left script the clipped words are the ones on
    /// the right and the newest words stay in view.
    static func tail(_ text: String, width: CGFloat, lines: Int) -> String {
        let flat = text.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return "" }
        if lineCount(flat, width: width) <= lines { return flat }
        let ellipsis = Self.ellipsis
        // Word starts, oldest first. Fewer words fit with every step, so the
        // first start whose tail fits is the longest ending that does.
        var starts: [String.Index] = []
        var previousWasSpace = true
        for index in flat.indices {
            let isSpace = flat[index] == " "
            if previousWasSpace && !isSpace { starts.append(index) }
            previousWasSpace = isSpace
        }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high) / 2
            if lineCount(ellipsis + flat[starts[mid]...], width: width) <= lines {
                high = mid
            } else {
                low = mid + 1
            }
        }
        guard let start = starts.indices.contains(low) ? starts[low] : starts.last else { return flat }
        return ellipsis + flat[start...]
    }

    /// First strong character decides: Arabic, Hebrew and their presentation
    /// forms read right to left.
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
            default:
                if scalar.properties.isAlphabetic { return false }
            }
        }
        return false
    }

    static func lineCount(_ text: String, width: CGFloat) -> Int {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let one = NSAttributedString(string: "Ag", attributes: attributes)
            .boundingRect(with: NSSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin]).height
        let box = NSAttributedString(string: text, attributes: attributes)
            .boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height
        return max(1, Int((box / max(one, 1)).rounded()))
    }
}
