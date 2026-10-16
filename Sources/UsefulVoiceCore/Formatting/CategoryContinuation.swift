import Foundation

/// Continuation awareness: look at the text just before the cursor and fit the dictation
/// to it. `windows/src/core/formatting/categoryContinuation.ts` mirrors this rule for rule.
///
/// Mid-sentence, the first word is not capitalised, but only when it is a common sentence
/// opener ("The", "And", "We"). Any other word may be a name ("Sarah", "Dr.", "A.I."), so
/// it keeps its case. A leading space is added only when the join needs one. Unknown
/// context (nil) leaves the dictation unchanged.
public enum CategoryContinuation {
    /// The only words whose first letter is lowercased. A closed list on purpose: lowercasing
    /// an unknown capitalised word risks damaging a name. Left out because they are names too:
    /// will, may, mark, bill, hope, grace. "I" and its contractions are never lowercased.
    public static let sentenceOpeners: Set<String> = [
        "the", "a", "an", "and", "but", "or", "so", "if", "because", "while", "although", "though",
        "since", "unless", "until", "when", "where", "what", "who", "whom", "whose", "which", "why", "how",
        "that", "this", "these", "those", "it", "its", "he", "she", "we", "you", "they", "them", "him",
        "her", "us", "me", "my", "your", "our", "their", "his", "there", "here", "then", "now", "also",
        "just", "maybe", "perhaps", "still", "even", "only", "really", "very", "actually", "basically",
        "honestly", "sure", "yes", "yeah", "yep", "nope", "no", "not", "okay", "ok", "thanks", "thank",
        "sorry", "please", "can", "could", "would", "should", "do", "does", "did", "is", "are", "was",
        "were", "am", "be", "have", "has", "had", "let", "got", "get", "need", "want", "like", "love",
        "think", "feel", "see", "look", "looks", "sounds", "sound", "wait", "check", "send", "call", "come",
        "go", "going", "take", "make", "try", "tell", "ask", "give", "to", "for", "of", "in", "on", "at",
        "by", "with", "from", "about", "as", "into", "after", "before", "some", "any", "all", "each",
        "every", "both", "many", "much", "more", "most", "other", "another", "such", "oh", "ah", "hmm",
        "wow", "lol", "haha",
        "it's", "that's", "there's", "here's", "what's", "who's", "he's", "she's", "let's", "we're",
        "you're", "they're", "we'll", "you'll", "they'll", "we've", "you've", "they've", "don't",
        "doesn't", "didn't", "can't", "won't", "isn't", "aren't", "wasn't", "weren't", "couldn't",
        "wouldn't", "shouldn't", "haven't", "hasn't", "hadn't",
    ]

    private static let sentenceEnds: Set<Character> = [".", "!", "?", ":"]
    /// Closing marks that can follow the full stop that ends a sentence.
    private static let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
    private static let openers: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}", "\u{00AB}"]
    /// A cursor right after one of these has nothing to space away from: paths, mentions, prices, tags.
    private static let noSpaceAfter: Set<Character> = ["/", "\\", "@", "#", "$", "~"]
    /// In code the join is usually part of a name or a path: `foo.`, `snake_`, `--`, `key:`.
    private static let codeNoSpaceAfter: Set<Character> = [".", "_", "-", ":"]
    /// Punctuation that attaches to the text before it, so a dictation starting with it needs no space.
    private static let attachFirst: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "%", "\u{2026}", "\u{201D}", "\u{2019}", "'",
    ]
    /// What can follow a sentence opener word: the word is then a whole word, not part of "A.I." or "A/B".
    private static let afterWord: Set<Character> = [",", ";", ":", "!", "?", ")", "]", "}", "\"", "\u{201D}", "\u{2026}"]
    /// A line that holds only one of these is an empty list item: the cursor is at the start of its text.
    private static let bullets: Set<Character> = ["-", "*", "\u{2022}", "\u{2013}", ">"]

    /// A straight quote opens when it follows whitespace, an opening mark, "=" or "|", or starts the text.
    private static func isOpeningQuote(at index: Int, in cs: [Character]) -> Bool {
        if index == 0 { return true }
        let prev = cs[index - 1]
        return CategoryText.isWS(prev) || openers.contains(prev) || prev == "=" || prev == "|"
    }

    /// Whether the cursor sits in the middle of a sentence. False for empty or unknown context.
    public static func isMidSentence(_ textBeforeCursor: String?) -> Bool {
        guard let textBeforeCursor else { return false }
        let cs = Array(textBeforeCursor)
        var j = cs.count - 1
        // Whitespace before the cursor; a line break means the cursor starts a line.
        while j >= 0 && CategoryText.isWS(cs[j]) {
            if CategoryText.isNewline(cs[j]) { return false }
            j -= 1
        }
        if j < 0 { return false }
        // Look through brackets and opening single quotes: judge the text before them.
        while true {
            let c = cs[j]
            // A quotation starts its own sentence: 'He said "' then "The end." keeps its capital.
            if c == "\u{201C}" || (c == "\"" && isOpeningQuote(at: j, in: cs)) { return false }
            let opening = openers.contains(c) || ((c == "\"" || c == "'") && isOpeningQuote(at: j, in: cs))
            if !opening { break }
            j -= 1
            while j >= 0 && CategoryText.isWS(cs[j]) {
                if CategoryText.isNewline(cs[j]) { return false }
                j -= 1
            }
            if j < 0 { return false }
        }
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

    /// Lowercases the first letter of the first word, but only when that word is a common
    /// sentence opener (see `sentenceOpeners`). "I" and I'm are kept, as are acronyms, words
    /// with inner capitals ("iPhone"), words followed by a dot that is part of the word
    /// ("A.I.") and dictionary words. Everything else, including every name, is returned as is.
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
        if !endsWholeWord(cs, start: i, end: end) { return text }
        if !sentenceOpeners.contains(word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")) { return text }
        if isDictionaryWord(word, dictionaryWords) { return text }
        return String(cs[0..<i]) + String(cs[i]).lowercased() + String(cs[(i + 1)...])
    }

    private static func endsWholeWord(_ cs: [Character], start: Int, end: Int) -> Bool {
        if end >= cs.count { return true }
        let c = cs[end]
        if CategoryText.isWS(c) { return true }
        if c == "." {
            // "Yes." ends a word; "A." is an initial and "A.I." an abbreviation.
            let afterDot: Character? = end + 1 < cs.count ? cs[end + 1] : nil
            return end - start >= 2 && (afterDot == nil || CategoryText.isWS(afterDot!))
        }
        return afterWord.contains(c)
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
        return isOpeningQuote(at: cs.count - 1, in: cs)
    }

    /// Whether one space must go between the text before the cursor and the dictation.
    /// `code` is true in a code context: no space after ".", "_", "-" or ":".
    public static func needsLeadingSpace(textBeforeCursor: String, dictation: String,
                                         code: Bool = false) -> Bool {
        let before = Array(textBeforeCursor)
        guard let first = dictation.first, let last = before.last else { return false }
        if CategoryText.isWS(first) || attachFirst.contains(first) { return false }
        if CategoryText.isWS(last) || openers.contains(last) || noSpaceAfter.contains(last) { return false }
        if code && codeNoSpaceAfter.contains(last) { return false }
        if endsInOpeningQuote(before) { return false }
        return true
    }

    /// Fits the dictation to the text before the cursor.
    /// `textBeforeCursor` nil means unknown: the dictation is returned unchanged.
    /// `lowercase: false` (Coding) keeps the first word as dictated; `code: true` skips the space
    /// after ".", "_", "-" and ":".
    public static func apply(textBeforeCursor: String?, dictation: String,
                             dictionaryWords: [String], lowercase: Bool = true,
                             code: Bool = false) -> String {
        guard let textBeforeCursor else { return dictation }
        if dictation.isEmpty { return dictation }
        var out = dictation
        if lowercase && isMidSentence(textBeforeCursor) {
            out = lowercaseFirstWord(out, dictionaryWords: dictionaryWords)
        }
        if needsLeadingSpace(textBeforeCursor: textBeforeCursor, dictation: out, code: code) { out = " " + out }
        return out
    }
}
