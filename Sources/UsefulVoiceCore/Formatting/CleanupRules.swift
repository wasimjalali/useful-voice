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
/// Fillers. A token is a filler candidate only when it is exactly one of `fillers` (lowercase
/// or Capitalised, never ALL CAPS: "ER" is the emergency room) with at most a comma, a full
/// stop or an ellipsis after it. "uh-huh", "um.txt", "(um)" and "Hmm?" are not touched.
/// "like", "you know", "I mean" and "sort of" are real words as often as fillers, so they
/// stay. A candidate is deleted only in two places:
///   - mid-sentence, when it is lowercase ("so um I need" -> "so I need"). A Capitalised one
///     mid-sentence is a name or a mention ("Dr. Er will see you", "Ask Er about it"), so it
///     stays, and so does one right after a mention word ("The word um is", "I said hmm and");
///   - at a real sentence start (text start, a new line, or after . ! ? that is not an
///     abbreviation such as "Dr." or "etc."), when a comma follows it ("Um, so we") or the next
///     word is not capitalised ("Uh so we"). "Um Kulthum" and "Um I think" stay. A
///     sentence-initial "hmm" always stays ("Hmm, interesting question.").
/// A filler followed by "huh" or "hmm" is a backchannel, not a hesitation: "uh huh", "um hmm",
/// "mm hmm" and "Uh, huh?" stay whole.
/// Deleting a filler tidies only the punctuation it leaves behind:
///   - its own trailing comma goes with it: "Well, um, I think" -> "Well, I think";
///   - a comma before it goes when the filler ends the text or the sentence ("went home,
///     um." -> "went home."), when the word before is one that never takes a comma
///     ("the, um, store" -> "the store"), and when the filler sits between two commas that
///     only bracket it ("I think, um, we should" -> "I think we should"). That last comma stays
///     when it closes a real opening: after a sentence's first word ("Well,"), after a discourse
///     word ("okay,", "actually,"), after an opening that starts with a greeting or answer word
///     ("Dear John,", "Thanks Sam,", "Yes sir,"), after an intro phrase ("For example,", "As a
///     result,", "In 2020,"), before a conjunction ("Friday, um, or Monday") and in a list
///     ("apples, um, pears,");
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
/// Stutters. Only a closed list of function words ever collapses, to its first occurrence:
/// two in a row when the word never legitimately doubles ("the the", "I I", "to to"), three
/// or more in a row for a few more ("it it it", "that that that", "is is is").
/// Every other word is left alone however often it repeats: numbers ("five five five", "nine
/// nine nine"), emphasis and idiom ("Stop stop stop", "Knock knock knock", "Ho ho ho", "Well
/// well well", "My my", "so so so tired"), and a laugh ("he he he"). A missed stutter is
/// harmless; a lost word is not. "had had", "that that" and "is is" are grammatical, so pairs
/// of those stay. A comma between the repeats is part of the stutter ("I, I think" -> "I
/// think"); a full stop or a line break is not.
///
/// Whitespace is only ever removed together with the token it belonged to. Text with no
/// filler or stutter comes back byte for byte. Text that is nothing but filler candidates
/// becomes "" ("Um.", "Um, uh, er."), unless one of them is protected: a sentence-initial
/// "hmm" or a backchannel ("Hmm.", "Um hmm.", "Hmm hmm" stay).
///
/// For the caller: the result can be "" (and `CleanupGuard` accepts an empty output for an
/// empty input), so whenever the cleaned text is empty, History and the clipboard must keep
/// the raw transcript instead of an empty entry.
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

    /// Function words whose doubling is always a stutter. "my" is not one: "My my, look at that."
    /// Neither is "he": "he he he" is a laugh.
    private static let doubleStutter: Set<String> = [
        "the", "a", "an", "i", "we", "you", "they", "she", "to", "of", "in", "on", "at", "for",
        "with", "by", "from", "and", "or", "your", "our", "their", "his", "her", "its", "if", "as",
        "i'm", "i've", "i'll", "i'd", "we're", "it's", "don't", "can't", "didn't", "won't",
    ]

    /// Function words that collapse from three repeats on (the pairs list collapses from two).
    /// "so" is not one: "so so so tired" is emphasis.
    private static let tripleStutter: Set<String> = doubleStutter.union(["it", "that", "is", "but", "was", "this"])

    /// A comma before a bracketed filler stays after these words ("Well, um, I think").
    private static let keepCommaBefore: Set<String> = [
        "well", "so", "okay", "ok", "yes", "yeah", "no", "oh", "right", "now", "sure", "anyway",
        "actually", "however", "also", "alright", "hi", "hello", "hey", "thanks", "honestly", "basically",
    ]

    /// A comma before a bracketed filler stays when one of these follows it ("Friday, um, or Monday").
    private static let conjunctions: Set<String> = [
        "and", "or", "but", "so", "then", "because", "which", "who", "where", "when", "while",
        "although", "though", "unless", "if",
    ]

    /// An opening that starts with one of these is closed by its comma ("Dear John,", "Yes sir,").
    private static let greetingStarts: Set<String> = [
        "dear", "hi", "hello", "hey", "thanks", "yes", "no", "ok", "okay", "sure", "sorry", "well",
    ]

    /// Intro phrases whose comma closes them ("For example, um, the build").
    private static let introPhrases: Set<String> = [
        "as a result", "for example", "for instance", "in addition", "in fact", "of course", "by the way",
        "on the other hand", "at the moment", "in general",
    ]

    /// "In 2020,", "By 5,": one of these plus a number is an intro phrase.
    private static let numberIntro: Set<String> = ["in", "by", "since", "until"]

    private static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty",
        "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand",
    ]

    /// Words after which a filler is being mentioned, not used: "the word um", "I said hmm".
    private static let mention: Set<String> = [
        "word", "words", "said", "say", "says", "saying", "type", "typed", "write", "wrote", "spell",
        "spelled", "term", "called", "named",
    ]

    /// A full stop after these does not end the sentence. Compared lowercase, whole token.
    private static let abbreviations: Set<String> = [
        "dr.", "mr.", "mrs.", "ms.", "st.", "prof.", "sr.", "jr.", "vs.", "etc.", "mt.", "e.g.", "i.e.",
    ]

    /// "uh huh", "um hmm", "mm hmm": the first word with one of the second is a backchannel.
    private static let backchannelFirst: Set<String> = ["uh", "um", "uhm", "mm", "mhm", "hm", "hmm"]
    private static let backchannelSecond: Set<String> = ["huh", "hmm", "hmmm", "hm", "mhm"]

    private struct Token {
        var space: String
        var text: String
    }

    private static func english(_ text: String) -> String {
        let (tokens, trailing) = splitTokens(text)
        if tokens.isEmpty { return text }
        let (cleaned, keptProtected) = removeFillers(tokens)
        // Text that is nothing but fillers ("Um.", "Um, uh, er.") was never meant to be typed,
        // unless one of them is protected ("Hmm.", "Um hmm.").
        if !keptProtected && tokens.allSatisfy({ parseFiller($0.text) != nil }) { return "" }
        let collapsed = collapseStutters(cleaned)
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

    private static func isUpperLetter(_ s: Unicode.Scalar) -> Bool {
        let category = s.properties.generalCategory
        return category == .uppercaseLetter || category == .titlecaseLetter
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
        /// Lowercase filler word.
        var word: String
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
        return Filler(capitalised: capitalised, trail: trail, word: lower)
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
        guard last == "." || last == "!" || last == "?" else { return false }
        return !abbreviations.contains(lowerAscii(text))
    }

    /// The word lowercased with trailing , . ! ? and ellipsis removed; nil unless plain ASCII letters.
    private static func plainCore(_ text: String) -> String? {
        let chars = Array(text.unicodeScalars)
        var end = chars.count
        while end > 0 && ",.!?\u{2026}".unicodeScalars.contains(chars[end - 1]) { end -= 1 }
        let core = chars[0..<end]
        if core.isEmpty || !core.allSatisfy({ isAsciiLower($0) || isAsciiUpper($0) }) { return nil }
        return lowerAscii(string(core))
    }

    private static func startsCapitalised(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return isUpperLetter(first)
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

    /// Indices of tokens in a backchannel pair ("uh huh", "um hmm"), which are never fillers.
    private static func backchannelIndices(_ tokens: [Token]) -> Set<Int> {
        var backchannel = Set<Int>()
        if tokens.count >= 2 {
            for i in 0..<(tokens.count - 1) {
                if let a = plainCore(tokens[i].text), let b = plainCore(tokens[i + 1].text),
                   backchannelFirst.contains(a), backchannelSecond.contains(b) {
                    backchannel.insert(i)
                    backchannel.insert(i + 1)
                }
            }
        }
        return backchannel
    }

    /// The tokens without deletable fillers, and whether a protected filler candidate was kept:
    /// one in a backchannel ("um hmm") or a sentence-initial "hmm".
    private static func removeFillers(_ tokens: [Token]) -> (tokens: [Token], keptProtected: Bool) {
        let backchannel = backchannelIndices(tokens)
        var keptProtected = false

        var out: [Token] = []
        var pendingCapital = false
        var carriedSpace: String?
        // A word that follows a deleted sentence-initial filler starts the sentence in its place.
        var startCarried = false
        for (i, tok) in tokens.enumerated() {
            let hasPrev = !out.isEmpty
            let prevIndex = out.count - 1
            // The next word that is not itself a filler candidate: "Uh, um so we" decides on "so".
            var n = i + 1
            while n < tokens.count && parseFiller(tokens[n].text) != nil { n += 1 }
            let next: Token? = n < tokens.count ? tokens[n] : nil
            let atSentenceStart = startCarried || !hasPrev || endsSentence(out[prevIndex].text)
                || containsNewline(tok.space)
            let candidate = parseFiller(tok.text)
            var parsed = backchannel.contains(i) ? nil : candidate
            if let f = parsed, !deletable(f, atSentenceStart: atSentenceStart, prev: hasPrev ? out[prevIndex] : nil, next: next) {
                parsed = nil
            }
            guard let filler = parsed else {
                if let c = candidate, backchannel.contains(i) || (atSentenceStart && c.word.hasPrefix("hm")) {
                    keptProtected = true
                }
                var kept = tok
                if let carried = carriedSpace { kept.space = carried }
                carriedSpace = nil
                if pendingCapital { kept.text = capitaliseIfPlain(kept.text) }
                pendingCapital = false
                startCarried = false
                out.append(kept)
                continue
            }

            let isLast = i == tokens.count - 1
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
                } else if endsComma
                    && (isLast
                        || (noCommaAfter.contains(bareWord(out[prevIndex].text)) && !thankYouOpening(out))
                        || (filler.trail == "," && bracketOnly(out, next: next))) {
                    out[prevIndex].text = dropLastScalar(out[prevIndex].text)
                }
            }
            if atSentenceStart && filler.capitalised && terminal.isEmpty { pendingCapital = true }
            startCarried = atSentenceStart
            if carriedSpace == nil && (!hasPrev || containsNewline(tok.space)) { carriedSpace = tok.space }
        }
        return (out, keptProtected)
    }

    /// Whether a filler candidate is a hesitation to delete (see the header comment).
    private static func deletable(_ filler: Filler, atSentenceStart: Bool, prev: Token?, next: Token?) -> Bool {
        if atSentenceStart {
            // "Hmm, interesting question." is as often a reaction as a hesitation.
            if filler.word.hasPrefix("hm") { return false }
            if filler.trail == "," { return true }
            guard let next = next else { return false }
            return !startsCapitalised(next.text)
        }
        if filler.capitalised { return false }
        if let prev = prev, lastScalar(prev.text) != ",", mention.contains(bareWord(prev.text)) { return false }
        return true
    }

    /// "Thank you," alone at the start of a sentence: its comma stays although "you" never takes one.
    private static func thankYouOpening(_ out: [Token]) -> Bool {
        let n = out.count
        guard n >= 2, bareWord(out[n - 1].text) == "you", bareWord(out[n - 2].text) == "thank" else { return false }
        return n == 2 || endsSentence(out[n - 3].text) || containsNewline(out[n - 2].space)
    }

    /// True when the comma before a ", um," filler was only there to bracket it, so it goes too.
    /// It stays when it closes a real opening (see the header comment), before a conjunction and
    /// in a list.
    private static func bracketOnly(_ out: [Token], next: Token?) -> Bool {
        guard let prev = out.last else { return false }
        var start = out.count - 1
        while start > 0 && !endsSentence(out[start - 1].text) && !containsNewline(out[start].space) { start -= 1 }
        if start == out.count - 1 { return false }
        if keepCommaBefore.contains(bareWord(prev.text)) { return false }
        if closesOpening(Array(out[start...])) { return false }
        guard let next = next else { return false }
        if conjunctions.contains(bareWord(next.text)) { return false }
        if lastScalar(next.text) == "," { return false }
        return true
    }

    /// Whether the words from the sentence start to the comma are an opening the comma closes:
    /// one that starts with a greeting or answer word, a known intro phrase, or "in" / "by" /
    /// "since" / "until" plus a number.
    private static func closesOpening(_ segment: [Token]) -> Bool {
        let words = segment.map { bareWord($0.text) }
        guard let first = words.first else { return false }
        if greetingStarts.contains(first) { return true }
        if first == "thank" && words.count > 1 && words[1] == "you" { return true }
        if introPhrases.contains(words.joined(separator: " ")) { return true }
        if numberIntro.contains(first) && segment.count > 1
            && segment.dropFirst().allSatisfy({ isNumberToken($0.text) }) {
            return true
        }
        return false
    }

    /// "2020," "3.5" or a spoken number word such as "twenty".
    private static func isNumberToken(_ text: String) -> Bool {
        let chars = Array(text.unicodeScalars)
        var end = chars.count
        while end > 0 && ",.!?".unicodeScalars.contains(chars[end - 1]) { end -= 1 }
        let core = chars[0..<end]
        if core.isEmpty { return false }
        if core.first.map({ $0.value >= 0x30 && $0.value <= 0x39 }) == true
            && core.allSatisfy({ ($0.value >= 0x30 && $0.value <= 0x39) || $0 == "," || $0 == "." }) {
            return true
        }
        return numberWords.contains(lowerAscii(string(core)))
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
                guard let s = shape(tokens[j].text), s.lead.isEmpty, stutterKey(s.core) == key,
                      !containsNewline(tokens[j].space) else { break }
                if !lastShape.trail.isEmpty && lastShape.trail != "," { break }
                lastShape = s
                j += 1
            }
            let run = j - i
            let collapse = (run >= 3 && tripleStutter.contains(key)) || (run >= 2 && doubleStutter.contains(key))
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
