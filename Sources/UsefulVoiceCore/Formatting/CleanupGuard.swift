import Foundation

/// Accept or reject the local cleanup model's output.
/// `windows/src/core/formatting/cleanupGuard.ts` mirrors this file rule for rule.
///
/// The model only ever reads the rules-cleaned text, and its answer is advisory: when
/// this says reject, the caller keeps the rules-only text. A timeout, an error or no
/// output at all is rejected by the caller before it gets here. Checks run in this order:
///   1. reasoning: the output holds a `<think>` tag (thinking was meant to be off);
///   2. empty: nothing came back for text that has words in it;
///   3. length: the output is far longer than the input;
///   4. no word change: the output has exactly the input's words, differing only in case,
///      punctuation, spacing or layout. Deepgram already formats, so a model earns its place by
///      changing words (a self-correction, a spoken number, email or file path). Format-only
///      edits ("Madrid and Berlin" -> "Madrid, and Berlin") are the restraint failures the
///      eval found, so the rules-only text is kept instead;
///   5. dropped content: too many of the input's content words are gone;
///   6. added content: content words appear that the speaker never said.
///
/// "Content words" are the distinct lowercase words of the text minus function words,
/// filler-like words ("like", "you know"), self-correction cues ("no wait", "I mean") and
/// spoken-symbol words ("at", "dot", "point", "dollars", the "p m" of a spoken time). Case,
/// punctuation and spacing are ignored: the guard judges content, not formatting. Numbers count as
/// one content item ("#num"), so
/// "three" -> "3" is neither a drop nor an add, but a model that invents a number, or loses
/// every number, is caught. A self-correction legitimately removes words ("Monday, no wait,
/// Tuesday"), so when the input contains a correction cue the allowed drop share is higher.
///
/// The limits below were set before the first eval run and not tuned. After that run, "point" and
/// "p m" were added to the spoken-symbol words (spoken decimals and times were being rejected) and
/// the no-word-change check was added (format-only edits were getting through). See
/// `evals/results/2026-10-16-cleanup.md`.
public enum CleanupGuard {
    public enum Reason: String, Equatable, Sendable {
        case reasoning, empty, tooLong, noWordChange, droppedContent, addedContent
    }

    public enum Verdict: Equatable, Sendable {
        case accept(String)
        case reject(Reason)
    }

    public struct Limits: Equatable, Sendable {
        /// Largest share of the input's content words the output may lose.
        public var maxDropShare: Double
        /// The same, when the input has a self-correction cue.
        public var maxDropShareWithCorrection: Double
        /// Share of the output's content words that may be new (rounded down).
        public var maxAddedShare: Double
        /// Output length limit as a multiple of the input length, plus `lengthSlack` scalars.
        public var maxLengthRatio: Double
        public var lengthSlack: Int
        /// Reject an output whose words are the input's words, in order.
        public var requireWordChange: Bool

        public init(
            maxDropShare: Double, maxDropShareWithCorrection: Double, maxAddedShare: Double,
            maxLengthRatio: Double, lengthSlack: Int, requireWordChange: Bool
        ) {
            self.maxDropShare = maxDropShare
            self.maxDropShareWithCorrection = maxDropShareWithCorrection
            self.maxAddedShare = maxAddedShare
            self.maxLengthRatio = maxLengthRatio
            self.lengthSlack = lengthSlack
            self.requireWordChange = requireWordChange
        }

        public static let standard = Limits(
            maxDropShare: 0.15, maxDropShareWithCorrection: 0.5, maxAddedShare: 0.1,
            maxLengthRatio: 1.5, lengthSlack: 16, requireWordChange: true)
    }

    public static func evaluate(
        rulesText: String, modelOutput: String, limits: Limits = .standard
    ) -> Verdict {
        let output = trimSpace(modelOutput)
        let lowered = lowerAscii(output)
        if lowered.contains("<think>") || lowered.contains("</think>") { return .reject(.reasoning) }

        let input = words(rulesText)
        if input.isEmpty { return output.isEmpty ? .accept("") : .reject(.addedContent) }
        if output.isEmpty { return .reject(.empty) }

        let maxLength = Int((Double(rulesText.unicodeScalars.count) * limits.maxLengthRatio).rounded(.down))
            + limits.lengthSlack
        if output.unicodeScalars.count > maxLength { return .reject(.tooLong) }

        let outputWords = words(output)
        if limits.requireWordChange && input.map({ $0.text }) == outputWords.map({ $0.text }) {
            return .reject(.noWordChange)
        }

        var inputAll = Set(input.map { $0.text })
        var outputAll = Set(outputWords.map { $0.text })
        let inputContent = contentSet(input)
        let outputContent = contentSet(outputWords)
        if hasNumber(input) { inputAll.insert(numberItem) }
        if hasNumber(outputWords) { outputAll.insert(numberItem) }

        if !inputContent.isEmpty {
            let dropped = inputContent.filter { !outputAll.contains($0) }.count
            let share = Double(dropped) / Double(inputContent.count)
            let limit = hasCorrectionCue(input) ? limits.maxDropShareWithCorrection : limits.maxDropShare
            if dropped > 0 && share > limit { return .reject(.droppedContent) }
        }

        let added = outputContent.filter { !inputAll.contains($0) }.count
        let allowedAdds = Int((limits.maxAddedShare * Double(outputContent.count)).rounded(.down))
        if added > allowedAdds { return .reject(.addedContent) }

        return .accept(output)
    }

    // MARK: Words

    private static let numberItem = "#num"

    private struct Word {
        var text: String
        var hasDigit: Bool
        var commaBefore: Bool
        var commaAfter: Bool
    }

    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "\n" || s == "\r" || s == "\u{00A0}"
    }

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }

    private static func isApostrophe(_ s: Unicode.Scalar) -> Bool { s == "'" || s == "\u{2019}" }

    private static func lowerScalar(_ s: Unicode.Scalar) -> Unicode.Scalar {
        s.value >= 0x41 && s.value <= 0x5A ? Unicode.Scalar(UInt8(s.value + 32)) : s
    }

    private static func lowerAscii(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map(lowerScalar)))
    }

    private static func trimSpace(_ s: String) -> String {
        let chars = Array(s.unicodeScalars)
        var start = 0
        var end = chars.count
        while start < end && isSpace(chars[start]) { start += 1 }
        while end > start && isSpace(chars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(chars[start..<end]))
    }

    /// Runs of letters and digits; apostrophes inside a word are dropped ("don't" -> "dont").
    private static func words(_ text: String) -> [Word] {
        let chars = Array(text.unicodeScalars)
        var out: [Word] = []
        var i = 0
        while i < chars.count {
            if !isLetter(chars[i]) && !isDigit(chars[i]) {
                i += 1
                continue
            }
            let start = i
            var word = String.UnicodeScalarView()
            var hasDigit = false
            while i < chars.count {
                let c = chars[i]
                if isLetter(c) || isDigit(c) {
                    word.append(c)
                    if isDigit(c) { hasDigit = true }
                    i += 1
                } else if isApostrophe(c) && i + 1 < chars.count && isLetter(chars[i + 1]) && !word.isEmpty {
                    i += 1
                } else {
                    break
                }
            }
            var k = start - 1
            while k >= 0 && isSpace(chars[k]) { k -= 1 }
            out.append(Word(
                text: lowerAscii(String(word)),
                hasDigit: hasDigit,
                commaBefore: k >= 0 && chars[k] == ",",
                commaAfter: i < chars.count && chars[i] == ","))
        }
        return out
    }

    private static func wordSet(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    private static let stop = wordSet("""
        a an the and or but nor so yet of to in on at by for with from into onto over under about as than then
        that this these those there here is are was were be been being am do does did done have has had having
        will would shall should can could may might must i me my mine we us our you your he him his she her it its
        they them their who whom whose which what when where why how if not just also very really too quite some any
        all each both few more most other such only own same up down out off again once now well oh okay ok yeah yes
        im ive ill id youre youve hes shes theyre dont doesnt didnt cant wont isnt arent wasnt werent hasnt havent
        hadnt couldnt wouldnt shouldnt thats whats lets theres heres um uh erm hmm like know basically literally
        honestly anyway kind sort
        """)

    private static let cues = wordSet("wait sorry scratch oops whoops rather mean actually correction instead")

    private static let symbols = wordSet("""
        at dot dash slash backslash underscore hash colon semicolon hyphen comma period percent dollar dollars
        cent cents euro euros pound pounds oclock am pm point p m
        """)

    private static let numberWords = wordSet("""
        zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen
        seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand
        million billion first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth
        thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth thirtieth
        """)

    private static func isNumber(_ word: Word) -> Bool { word.hasDigit || numberWords.contains(word.text) }

    private static func hasNumber(_ list: [Word]) -> Bool { list.contains(where: isNumber) }

    private static func contentSet(_ list: [Word]) -> Set<String> {
        var out = Set<String>()
        for word in list {
            if isNumber(word) {
                out.insert(numberItem)
            } else if !stop.contains(word.text) && !cues.contains(word.text) && !symbols.contains(word.text) {
                out.insert(word.text)
            }
        }
        return out
    }

    /// "no wait", "sorry", "I mean", "make that", or a "no" set off by commas ("Thursday, no, Friday").
    private static func hasCorrectionCue(_ list: [Word]) -> Bool {
        for (i, word) in list.enumerated() {
            if cues.contains(word.text) { return true }
            if word.text == "no" && (word.commaBefore || word.commaAfter) { return true }
            if word.text == "make" && i + 1 < list.count && list[i + 1].text == "that" { return true }
        }
        return false
    }
}
