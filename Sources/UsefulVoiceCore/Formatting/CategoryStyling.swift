import Foundation

/// Formal / Casual / Very casual.
/// `windows/src/core/formatting/categoryStyle.ts` mirrors this file rule for rule.
///
/// Formal leaves the text as is. Casual drops the closing full stop of a one-sentence
/// message (never a ? or !). Very casual does that and lowercases the first letter.
public enum CategoryStyling {
    /// A final dot after one of these belongs to the word: "and so on, etc." keeps its dot.
    private static let abbreviations: Set<String> = [
        "etc", "dr", "mr", "mrs", "ms", "prof", "sr", "jr", "vs", "inc", "ltd", "co", "corp", "st", "ave",
        "approx", "dept", "fig", "misc",
    ]

    /// Drops the final "." of a single-sentence message. Left alone when: there is a line
    /// break, another sentence ends inside the text, the text ends in "..", the last word
    /// has a dot inside it ("p.m.", "e.g.", "3.5.", "index.ts.") or is an abbreviation
    /// ("etc.", "Dr.").
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
        let lastWord = stem[wordStart...]
        if lastWord.contains(".") { return text }
        if abbreviations.contains(String(lastWord).lowercased()) { return text }
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
