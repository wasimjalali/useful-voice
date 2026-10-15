import Foundation

/// Formal / Casual / Very casual.
/// `windows/src/core/formatting/categoryStyle.ts` mirrors this file rule for rule.
///
/// Formal leaves the text as is. Casual drops the closing full stop of a one-sentence
/// message (never a ? or !). Very casual does that and lowercases the first letter.
public enum CategoryStyling {
    /// Drops the final "." of a single-sentence message. Left alone when: there is a line
    /// break, another sentence ends inside the text, the text ends in "..", or the last word
    /// has a dot inside it ("p.m.", "e.g.", "3.5.", "index.ts.").
    public static func dropTrailingFullStop(_ text: String) -> String {
        if CategoryText.containsNewline(text) { return text }
        let cs = Array(text)
        var end = cs.count
        while end > 0 && CategoryText.isWS(cs[end - 1]) { end -= 1 }
        if end == 0 || cs[end - 1] != "." { return text }
        if end >= 2 && cs[end - 2] == "." { return text }
        let stem = Array(cs[0..<(end - 1)])
        if stem.isEmpty { return text }
        for i in 0..<stem.count {
            let c = stem[i]
            if c != "." && c != "!" && c != "?" { continue }
            if i + 1 >= stem.count || CategoryText.isWS(stem[i + 1]) { return text }
        }
        var wordStart = stem.count
        while wordStart > 0 && !CategoryText.isWS(stem[wordStart - 1]) { wordStart -= 1 }
        if stem[wordStart...].contains(".") { return text }
        return String(stem) + String(cs[end...])
    }

    /// Applies an already-resolved style (see `FormattingStyle.effective`).
    public static func apply(_ text: String, style: FormattingStyle, dictionaryWords: [String]) -> String {
        if style == .formal { return text }
        let dropped = dropTrailingFullStop(text)
        if style == .casual { return dropped }
        return CategoryContinuation.lowercaseFirstWord(dropped, dictionaryWords: dictionaryWords)
    }
}
