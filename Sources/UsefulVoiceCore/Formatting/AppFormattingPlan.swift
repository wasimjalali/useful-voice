import Foundation

/// How one dictation is formatted for the app it goes into, decided at the hotkey press.
///
/// Wraps `CategoryFormatter` with the pipeline's safety rule: when the formatter returns
/// nothing usable, the text the pipeline already had is delivered as it was. A dictation is
/// never lost or emptied by category formatting.
public struct AppFormattingPlan: Equatable, Sendable {
    public let category: AppCategory
    /// The user's style for the category; nil means the category default.
    public let style: FormattingStyle?
    /// The name for an email sign-off. Empty means none is added.
    public let userName: String
    /// Up to `TextBeforeCursor.limit` characters before the caret in the target's field,
    /// read at the press. Memory only. Nil when unknown.
    public let textBeforeCursor: String?

    public init(category: AppCategory, style: FormattingStyle? = nil, userName: String = "",
                textBeforeCursor: String? = nil) {
        self.category = category
        self.style = style
        self.userName = userName
        self.textBeforeCursor = textBeforeCursor
    }

    public func apply(to text: String, dictionaryWords: [String] = []) -> String {
        let formatted = CategoryFormatter.format(
            text, category: category, style: style,
            userName: userName.isEmpty ? nil : userName,
            textBeforeCursor: textBeforeCursor, dictionaryWords: dictionaryWords)
        // Unsure, or nothing came back: keep what the pipeline produced.
        if formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return formatted
    }
}

/// The text just before the caret in the target's focused field, for continuation.
public enum TextBeforeCursor {
    /// The most that is ever read.
    public static let limit = 200

    /// The last `limit` characters of `value` before the caret.
    ///
    /// - Parameters:
    ///   - value: the field's whole text.
    ///   - caretUTF16: the caret as an offset in UTF-16 units (what Accessibility reports), or
    ///     the start of the selection.
    /// - Returns: nil when the caret is outside the text (a stale read), so the formatter
    ///   treats the context as unknown instead of guessing.
    public static func extract(value: String, caretUTF16: Int, limit: Int = TextBeforeCursor.limit) -> String? {
        let units = value.utf16
        guard caretUTF16 >= 0, caretUTF16 <= units.count, limit > 0 else { return nil }
        // Only a window around the caret is turned into a String: `limit` characters are never
        // more than `limit` * 8 UTF-16 units even with long grapheme clusters, and a huge
        // document is not copied whole.
        let from = max(0, caretUTF16 - limit * 8)
        let start = units.index(units.startIndex, offsetBy: from)
        let end = units.index(units.startIndex, offsetBy: caretUTF16)
        let window = String(decoding: Array(units[start..<end]), as: UTF16.self)
        return String(window.suffix(limit))
    }
}
