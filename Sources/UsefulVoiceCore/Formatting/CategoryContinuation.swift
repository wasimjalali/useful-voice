import Foundation

/// Continuation awareness: look at the text just before the cursor and fit the dictation
/// to it. `windows/src/core/formatting/categoryContinuation.ts` mirrors this rule for rule.
///
/// Mid-sentence, the first word is not capitalised. A leading space is added only when
/// the join needs one. Unknown context (nil) leaves the dictation unchanged.
public enum CategoryContinuation {
    private static let sentenceEnds: Set<Character> = [".", "!", "?", ":"]
    /// Closing marks that can follow the full stop that ends a sentence.
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
    private static let openers: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}", "\u{00AB}"]
    /// A cursor right after one of these has nothing to space away from: paths, mentions, prices, tags.
    private static let noSpaceAfter: Set<Character> = ["/", "\\", "@", "#", "$", "~"]
    /// Punctuation that attaches to the text before it, so a dictation starting with it needs no space.
    private static let attachFirst: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "%", "\u{2026}", "\u{201D}", "\u{2019}", "'",
    ]
    /// A line that holds only one of these is an empty list item: the cursor is at the start of its text.
    private static let bullets: Set<Character> = ["-", "*", "\u{2022}", "\u{2013}", ">"]

    /// Whether the cursor sits in the middle of a sentence. False for empty or unknown context.
    public static func isMidSentence(_ textBeforeCursor: String?) -> Bool {
        guard let textBeforeCursor else { return false }
        let cs = Array(textBeforeCursor)
        var j = cs.count - 1
        var sawNewline = false
        while j >= 0 && CategoryText.isWS(cs[j]) {
            if CategoryText.isNewline(cs[j]) { sawNewline = true }
            j -= 1
        }
        if j < 0 || sawNewline { return false }
        var k = j
        while k >= 0 && closers.contains(cs[k]) { k -= 1 }
        if k >= 0 && sentenceEnds.contains(cs[k]) { return false }
        if bullets.contains(cs[j]) {
            var lineStart = j
            while lineStart > 0 && !CategoryText.isNewline(cs[lineStart - 1]) { lineStart -= 1 }
            if cs[lineStart..<j].allSatisfy(CategoryText.isWS) { return false }
        }
        return true
    }

    /// Whether the cursor sits at the start of a line (or in empty text). Unknown context is not.
    public static func isAtLineStart(_ textBeforeCursor: String?) -> Bool {
        guard let textBeforeCursor else { return false }
        let cs = Array(textBeforeCursor)
        var j = cs.count - 1
        while j >= 0 && CategoryText.isWS(cs[j]) {
            if CategoryText.isNewline(cs[j]) { return true }
            j -= 1
        }
        return j < 0
    }

    private static func isWordChar(_ c: Character) -> Bool {
        CategoryText.isAlnum(c) || c == "'" || c == "\u{2019}" || c == "-"
    }

    /// Lowercases the first letter of the first word, unless that word is "I" (or I'm, I'll),
    /// an acronym, has inner capitals, or is one of the dictionary words. Anything that does
    /// not start with an uppercase letter is returned as is.
    public static func lowercaseFirstWord(_ text: String, dictionaryWords: [String]) -> String {
        let cs = Array(text)
        var i = 0
        while i < cs.count && CategoryText.isWS(cs[i]) { i += 1 }
        if i >= cs.count || !cs[i].isUppercase { return text }
        var end = i
        while end < cs.count && isWordChar(cs[end]) { end += 1 }
        let wordChars = cs[i..<end]
        let word = String(wordChars)
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I\u{2019}") { return text }
        if wordChars.filter({ $0.isUppercase }).count >= 2 { return text }
        if isDictionaryWord(word, dictionaryWords) { return text }
        return String(cs[0..<i]) + String(cs[i]).lowercased() + String(cs[(i + 1)...])
    }

    /// Whether the word is a dictionary word, or the first word of a multi-word entry. Case-insensitive.
    private static func isDictionaryWord(_ word: String, _ dictionaryWords: [String]) -> Bool {
        var core = word
        while core.hasSuffix("'") || core.hasSuffix("\u{2019}") || core.hasSuffix("-") { core.removeLast() }
        let lower = word.lowercased()
        let lowerCore = core.lowercased()
        for entry in dictionaryWords {
            let first = (CategoryText.splitWords(entry).first ?? "").lowercased()
            if !first.isEmpty && (first == lower || first == lowerCore) { return true }
        }
        return false
    }

    /// Capitalises the first letter of the first word when that word is plain lowercase
    /// ("thanks"). A word with any capital ("iPhone") or in the dictionary is left as is.
    public static func capitalizeFirstWord(_ text: String, dictionaryWords: [String]) -> String {
        let cs = Array(text)
        var i = 0
        while i < cs.count && CategoryText.isWS(cs[i]) { i += 1 }
        if i >= cs.count { return text }
        let first = cs[i]
        if !first.isLetter || String(first).uppercased() == String(first) { return text }
        var end = i
        while end < cs.count && isWordChar(cs[end]) { end += 1 }
        let word = String(cs[i..<end])
        if cs[i..<end].contains(where: { $0.isUppercase }) { return text }
        if isDictionaryWord(word, dictionaryWords) { return text }
        return String(cs[0..<i]) + String(first).uppercased() + String(cs[(i + 1)...])
    }

    private static func endsInOpeningQuote(_ cs: [Character]) -> Bool {
        guard let last = cs.last, last == "\"" || last == "'" else { return false }
        if cs.count < 2 { return true }
        let prev = cs[cs.count - 2]
        return CategoryText.isWS(prev) || openers.contains(prev) || prev == "=" || prev == "|"
    }

    /// Whether one space must go between the text before the cursor and the dictation.
    public static func needsLeadingSpace(textBeforeCursor: String, dictation: String) -> Bool {
        let before = Array(textBeforeCursor)
        guard let first = dictation.first, let last = before.last else { return false }
        if CategoryText.isWS(first) || attachFirst.contains(first) { return false }
        if CategoryText.isWS(last) || openers.contains(last) || noSpaceAfter.contains(last) { return false }
        if endsInOpeningQuote(before) { return false }
        return true
    }

    /// Fits the dictation to the text before the cursor.
    /// `textBeforeCursor` nil means unknown: the dictation is returned unchanged.
    /// `lowercase: false` (Coding) keeps the first word as dictated.
    public static func apply(textBeforeCursor: String?, dictation: String,
                             dictionaryWords: [String], lowercase: Bool = true) -> String {
        guard let textBeforeCursor else { return dictation }
        if dictation.isEmpty { return dictation }
        var out = dictation
        if lowercase && isMidSentence(textBeforeCursor) {
            out = lowercaseFirstWord(out, dictionaryWords: dictionaryWords)
        }
        if needsLeadingSpace(textBeforeCursor: textBeforeCursor, dictation: out) { out = " " + out }
        return out
    }
}
