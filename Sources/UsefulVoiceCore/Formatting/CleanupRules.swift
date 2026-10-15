import Foundation

/// Deterministic English cleanup rules.
/// `windows/src/core/formatting/cleanupRules.ts` mirrors this file rule for rule.
///
/// Deepgram only formats. This is the "rules" step of the cleanup order (vocabulary,
/// rules, local model, user rules): it removes filler sounds and collapses stutters,
/// and nothing else. It deletes, it never adds, reorders or re-cases a word the speaker
/// said. The cleanup guidance it follows is the published SpeakoFlow rules layer
/// (https://speakoflow.com/blog/dictation-cleanup-rules-and-llm, MIT), made stricter:
/// a missed "um" is invisible, a deleted word is a bug report, so every rule leaves the
/// text alone when it is unsure.
///
/// Fillers. A token is a filler only when it is exactly one of `fillers` (lowercase or
/// Capitalised, never ALL CAPS: "ER" is the emergency room) with at most a comma, a full
/// stop or an ellipsis after it. "uh-huh", "um.txt", "(um)" and "Hmm?" are not touched.
/// "like", "you know", "I mean" and "sort of" are real words as often as fillers, so they
/// stay. Deleting a filler tidies only the punctuation it leaves behind:
///   - its own trailing comma goes with it: "Well, um, I think" -> "Well, I think";
///   - a comma before it goes when the filler ends the text or the sentence ("went home,
///     um." -> "went home.") or when the word before is one that never takes a comma
///     ("the, um, store" -> "the store");
///   - a filler that ends a sentence ("I went, um.") hands its full stop to the word before.
/// Sentence-initial capital: when the deleted filler was Capitalised and started a
/// sentence ("Um, so we"), the next word gets the capital back ("So we"). That restores the
/// sentence casing the speaker's first word carried; it does not re-case a word they said.
/// A filler that was already lowercase hands over nothing. The capital only moves onto a
/// plain lowercase word (letters and apostrophes, optional trailing punctuation): "iPhone",
/// "app.ts" and "git-flow" are left as they were. A plain lowercase identifier such as
/// "npm" does get the capital ("Um, npm install" -> "Npm install"), which is the known cost
/// of restoring sentence casing without a dictionary.
///
/// Stutters. A run of the same word, case-insensitively, collapses to its first
/// occurrence: three or more in a row (except emphasis words: "no no no", "very very
/// very"), or two in a row when the word is a function word that never legitimately
/// doubles ("the the", "I I", "to to"). "had had", "that that", "is is" and "no no" are
/// grammatical or emphatic, so pairs of those stay. A comma between the repeats is part of
/// the stutter ("I, I think" -> "I think"), a full stop is not.
///
/// Whitespace is only ever removed together with the token it belonged to. Text with no
/// filler or stutter comes back byte for byte. Text that is nothing but fillers becomes "".
/// English only: other languages have real words that look like these fillers ("um" is
/// Portuguese for "a").
public enum CleanupRules {
    public static func apply(to text: String, language: String?) -> String {
        guard let code = language?.lowercased() else { return text }
        if code == "en" || code.hasPrefix("en-") { return english(text) }
        return text
    }

    private static let fillers: Set<String> = ["um", "umm", "uhm", "uh", "uhh", "erm", "er", "hmm", "hmmm"]

    /// Words that never take a comma after them, so "the, um, store" loses both commas.
    private static let noCommaAfter: Set<String> = [
        "the", "a", "an", "to", "of", "in", "on", "at", "for", "with", "by", "from", "into", "onto",
        "over", "than", "my", "your", "his", "her", "our", "their", "its", "this", "that", "these",
        "those", "and", "or", "but", "because", "if", "when", "as", "which", "is", "are", "was",
        "were", "be", "i", "we", "you", "they", "he", "she", "it",
    ]

    /// Function words whose doubling is always a stutter.
    private static let doubleStutter: Set<String> = [
        "the", "a", "an", "i", "we", "you", "they", "he", "she", "to", "of", "in", "on", "at", "for",
        "with", "by", "from", "and", "or", "my", "your", "our", "their", "his", "her", "its", "if", "as",
        "i'm", "i've", "i'll", "i'd", "we're", "it's", "don't", "can't", "didn't", "won't",
    ]

    /// Words repeated three or more times on purpose.
    private static let emphasis: Set<String> = [
        "no", "yes", "very", "so", "bye", "ha", "never", "more", "really", "hey", "oh", "wow", "go",
        "please", "sorry", "okay", "ok", "again", "yeah", "blah", "la", "na",
    ]

    private struct Token {
        var space: String
        var text: String
    }

    private static func english(_ text: String) -> String {
        let (tokens, trailing) = splitTokens(text)
        if tokens.isEmpty { return text }
        let collapsed = collapseStutters(removeFillers(tokens))
        if collapsed.isEmpty { return "" }
        return collapsed.map { $0.space + $0.text }.joined() + trailing
    }

    // MARK: Characters (unicode scalars; the TypeScript mirror uses code points)

    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "\n" || s == "\r" || s == "\u{00A0}"
    }

    private static func isAsciiUpper(_ s: Unicode.Scalar) -> Bool { s.value >= 0x41 && s.value <= 0x5A }

    private static func isAsciiLower(_ s: Unicode.Scalar) -> Bool { s.value >= 0x61 && s.value <= 0x7A }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    private static func isApostrophe(_ s: Unicode.Scalar) -> Bool { s == "'" || s == "\u{2019}" }

    private static func lowerScalar(_ s: Unicode.Scalar) -> Unicode.Scalar {
        isAsciiUpper(s) ? Unicode.Scalar(UInt8(s.value + 32)) : s
    }

    private static func upperScalar(_ s: Unicode.Scalar) -> Unicode.Scalar {
        isAsciiLower(s) ? Unicode.Scalar(UInt8(s.value - 32)) : s
    }

    private static func string(_ scalars: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    private static func lowerAscii(_ s: String) -> String {
        string(s.unicodeScalars.map(lowerScalar))
    }

    private static func capitalizeFirst(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        if !scalars.isEmpty { scalars[0] = upperScalar(scalars[0]) }
        return string(scalars)
    }

    private static func containsNewline(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    private static func lastScalar(_ s: String) -> Unicode.Scalar? { s.unicodeScalars.last }

    private static func dropLastScalar(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        if !scalars.isEmpty { scalars.removeLast() }
        return string(scalars)
    }

    private static func splitTokens(_ text: String) -> ([Token], String) {
        var tokens: [Token] = []
        var space = String.UnicodeScalarView()
        var word = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if isSpace(s) {
                if !word.isEmpty {
                    tokens.append(Token(space: String(space), text: String(word)))
                    space = String.UnicodeScalarView()
                    word = String.UnicodeScalarView()
                }
                space.append(s)
            } else {
                word.append(s)
            }
        }
        if !word.isEmpty {
            tokens.append(Token(space: String(space), text: String(word)))
            return (tokens, "")
        }
        return (tokens, String(space))
    }

    // MARK: Fillers

    private struct Filler {
        var capitalised: Bool
        var trail: String
    }

    private static func parseFiller(_ text: String) -> Filler? {
        let chars = Array(text.unicodeScalars)
        var end = chars.count
        while end > 0 && (chars[end - 1] == "," || chars[end - 1] == "." || chars[end - 1] == "\u{2026}") {
            end -= 1
        }
        if end == 0 { return nil }
        let trail = string(chars[end...])
        let core = Array(chars[0..<end])
        guard core.allSatisfy({ isAsciiLower($0) || isAsciiUpper($0) }) else { return nil }
        let word = string(core)
        let lower = lowerAscii(word)
        guard fillers.contains(lower) else { return nil }
        let capitalised = isAsciiUpper(core[0])
        guard word == lower || word == capitalizeFirst(lower) else { return nil }
        guard trail.isEmpty || trail == "," || trail == "." || trail == "..." || trail == "\u{2026}" else {
            return nil
        }
        return Filler(capitalised: capitalised, trail: trail)
    }

    /// The last character after any closing quote or bracket.
    private static func lastMeaningful(_ text: String) -> Unicode.Scalar? {
        let chars = Array(text.unicodeScalars)
        var i = chars.count
        while i > 0 && ("\"'])\u{201D}\u{2019}".unicodeScalars.contains(chars[i - 1])) { i -= 1 }
        return i > 0 ? chars[i - 1] : nil
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = lastMeaningful(text) else { return false }
        return last == "." || last == "!" || last == "?"
    }

    private static func endsWithStop(_ text: String) -> Bool {
        guard let last = lastScalar(text) else { return false }
        return ".!?\u{2026}:;".unicodeScalars.contains(last)
    }

    private static func bareWord(_ text: String) -> String {
        var out: [Unicode.Scalar] = []
        for s in text.unicodeScalars where isLetter(s) || isApostrophe(s) {
            out.append(s == "\u{2019}" ? "'" : s)
        }
        return lowerAscii(string(out))
    }

    private static func removeFillers(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var pendingCapital = false
        var carriedSpace: String?
        for (i, tok) in tokens.enumerated() {
            guard let filler = parseFiller(tok.text) else {
                var kept = tok
                if let carried = carriedSpace { kept.space = carried }
                carriedSpace = nil
                if pendingCapital { kept.text = capitaliseIfPlain(kept.text) }
                pendingCapital = false
                out.append(kept)
                continue
            }

            let isLast = i == tokens.count - 1
            let hasPrev = !out.isEmpty
            let prevIndex = out.count - 1
            let atSentenceStart = !hasPrev || endsSentence(out[prevIndex].text) || containsNewline(tok.space)
            var terminal = ""
            if filler.trail == "." || (isLast && (filler.trail == "..." || filler.trail == "\u{2026}")) {
                terminal = filler.trail
            }

            if hasPrev {
                let endsComma = lastScalar(out[prevIndex].text) == ","
                if !terminal.isEmpty {
                    if endsComma {
                        out[prevIndex].text = dropLastScalar(out[prevIndex].text) + terminal
                    } else if !endsWithStop(out[prevIndex].text) {
                        out[prevIndex].text += terminal
                    }
                } else if endsComma && (isLast || noCommaAfter.contains(bareWord(out[prevIndex].text))) {
                    out[prevIndex].text = dropLastScalar(out[prevIndex].text)
                }
            }
            if atSentenceStart && filler.capitalised && terminal.isEmpty { pendingCapital = true }
            if carriedSpace == nil && (!hasPrev || containsNewline(tok.space)) { carriedSpace = tok.space }
        }
        return out
    }

    /// "so," -> "So,". Anything that is not a plain lowercase word ("iPhone", "app.ts", "3d") is returned as is.
    private static func capitaliseIfPlain(_ text: String) -> String {
        var chars = Array(text.unicodeScalars)
        var end = chars.count
        while end > 0 && !isLetter(chars[end - 1]) && !isApostrophe(chars[end - 1]) { end -= 1 }
        let core = chars[0..<end]
        if core.isEmpty { return text }
        if !core.allSatisfy({ isAsciiLower($0) || isApostrophe($0) }) { return text }
        let first = chars[0]
        if !isAsciiLower(first) { return text }
        chars[0] = upperScalar(first)
        return string(chars)
    }

    // MARK: Stutters

    private struct Shape {
        var lead: String
        var core: String
        var trail: String
    }

    /// Splits "(the," into lead "(", core "the", trail ","; nil unless the core is letters and apostrophes.
    private static func shape(_ text: String) -> Shape? {
        let chars = Array(text.unicodeScalars)
        var start = 0
        while start < chars.count && !isLetter(chars[start]) { start += 1 }
        var end = chars.count
        while end > start && !isLetter(chars[end - 1]) { end -= 1 }
        if start >= end { return nil }
        let core = chars[start..<end]
        if !core.allSatisfy({ isLetter($0) || isApostrophe($0) }) { return nil }
        return Shape(lead: string(chars[0..<start]), core: string(core), trail: string(chars[end...]))
    }

    private static func stutterKey(_ core: String) -> String {
        lowerAscii(string(core.unicodeScalars.map { $0 == "\u{2019}" ? "'" : $0 }))
    }

    private static func collapseStutters(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            guard let first = shape(tok.text) else {
                out.append(tok)
                i += 1
                continue
            }
            let key = stutterKey(first.core)
            var j = i + 1
            var lastShape = first
            while j < tokens.count {
                guard let s = shape(tokens[j].text), s.lead.isEmpty, stutterKey(s.core) == key else { break }
                if !lastShape.trail.isEmpty && lastShape.trail != "," { break }
                lastShape = s
                j += 1
            }
            let run = j - i
            let collapse = (run >= 3 && !emphasis.contains(key)) || (run >= 2 && doubleStutter.contains(key))
            if collapse {
                out.append(Token(space: tok.space, text: first.lead + first.core + lastShape.trail))
            } else {
                out.append(contentsOf: tokens[i..<j])
            }
            i = j
        }
        return out
    }
}
