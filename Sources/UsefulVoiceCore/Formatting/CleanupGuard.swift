import Foundation

/// Accept or reject the local cleanup model's output.
/// `windows/src/core/formatting/cleanupGuard.ts` mirrors this file rule for rule.
///
/// The model only ever reads the rules-cleaned text, and its answer is advisory: when
/// this says reject, the caller keeps the rules-only text. A timeout, an error or no
/// output at all is rejected by the caller before it gets here. Both texts are NFC
/// normalised first, so canonically equivalent strings compare equal in both cores, and
/// both cores use the same whitespace list (`isSpace`). Checks run in this order:
///   1. reasoning: the output holds a `<think>` tag (thinking was meant to be off);
///   2. wrapper: the output adds a tag, a code fence, a chat token, a quote wrap or a
///      preamble ("Here is the cleaned text:") that the input does not have;
///   3. empty: the output has no letters or digits for an input that has some;
///   4. length: the output is far longer than the input;
///   5. no word change: the output has exactly the input's words, differing only in case,
///      punctuation, spacing or layout. Deepgram already formats, so a model earns its place by
///      changing words. Format-only edits are kept as the rules-only text;
///   6. changed number: spoken numbers become digits on both sides ("forty two" -> 42, "a dozen"
///      -> 12, "two point five" -> 2.5, "third" -> 3), then the digit runs must match. The same digit
///      sequence split differently is fine ("five five five, zero one" -> "555-01"); a changed,
///      dropped or invented number is not;
///   7. negation: every not/n't, no, never, nor (and none, nothing, nobody, neither, nowhere) the
///      speaker said must survive, and none may be invented. "do not" -> "don't" is fine;
///   8. dropped content: more than `maxDropShare` of the input's content words are gone;
///   9. added content: new content words beyond `maxAddedShare` of the output's;
///  10. duplicated: input words repeated beyond what the speaker said (same allowance);
///  11. reordered: the content words (and numbers, when they had to be matched one by one) are
///      not in the speaker's order.
///
/// Words are compared as a multiset, lowercase, apostrophes dropped ("don't" -> "dont").
/// "Content words" leave out function words, filler-like words ("like", "you know"),
/// self-correction cue words ("wait", "sorry", "mean") and spoken-symbol words ("at", "dot",
/// "point", "dollars", the "p m" of a spoken time).
///
/// Self-corrections. A real correction pattern ("Monday, no wait, Tuesday", "four thousand,
/// sorry, forty thousand", "X, I mean Y", "X, actually, Y", "X, or rather Y", "Thursday, no,
/// Friday", "make that", "scratch that") with content on both sides marks a corrected span:
/// the cue plus as many content words or numbers before it as the repair after it has, and
/// never more than 4. A cue that starts a sentence ("Wait, Tuesday.") reaches back into the
/// previous sentence only when that sentence has at most 4 content words or numbers. Only
/// that span may vanish without counting as a drop, a dropped number or a dropped negation. A
/// cue word anywhere else ("Sorry, I'm late", "I mean what I said") widens nothing.
///
/// The limits were set before the first eval run and not tuned on the held-out set. See
/// `evals/results/2026-10-16-cleanup.md`.
public enum CleanupGuard {
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        case reasoning, wrapper, empty, tooLong, noWordChange, changedNumber, negation
        case droppedContent, addedContent, duplicated, reordered
    }

    public enum Verdict: Equatable, Sendable {
        case accept(String)
        case reject(Reason)
    }

    public struct Limits: Equatable, Sendable {
        /// Largest share of the input's content words (outside a corrected span) the output may lose.
        public var maxDropShare: Double
        /// Share of the output's content words that may be new or repeated (rounded down).
        public var maxAddedShare: Double
        /// Output length limit as a multiple of the input length, plus `lengthSlack` scalars.
        public var maxLengthRatio: Double
        public var lengthSlack: Int
        /// Reject an output whose words are the input's words, in order.
        public var requireWordChange: Bool

        public init(
            maxDropShare: Double, maxAddedShare: Double, maxLengthRatio: Double, lengthSlack: Int,
            requireWordChange: Bool
        ) {
            self.maxDropShare = maxDropShare
            self.maxAddedShare = maxAddedShare
            self.maxLengthRatio = maxLengthRatio
            self.lengthSlack = lengthSlack
            self.requireWordChange = requireWordChange
        }

        public static let standard = Limits(
            maxDropShare: 0.15, maxAddedShare: 0.1, maxLengthRatio: 1.5, lengthSlack: 16, requireWordChange: true)
    }

    public static func evaluate(
        rulesText: String, modelOutput: String, limits: Limits = .standard
    ) -> Verdict {
        let inputText = rulesText.precomposedStringWithCanonicalMapping
        let output = trimSpace(modelOutput.precomposedStringWithCanonicalMapping)
        let lowered = lowerAscii(output)
        if scalarsContain(lowered, "<think>") || scalarsContain(lowered, "</think>") { return .reject(.reasoning) }
        if hasWrapper(input: inputText, output: output) { return .reject(.wrapper) }

        let rawIn = scan(inputText)
        let rawOut = scan(output)
        if rawIn.isEmpty { return output.isEmpty ? .accept("") : .reject(.addedContent) }
        if rawOut.isEmpty { return .reject(.empty) }

        let maxLength = Int((Double(inputText.unicodeScalars.count) * limits.maxLengthRatio).rounded(.down))
            + limits.lengthSlack
        if output.unicodeScalars.count > maxLength { return .reject(.tooLong) }

        if limits.requireWordChange && rawIn.map(\.text) == rawOut.map(\.text) { return .reject(.noWordChange) }

        let input = withNumbers(rawIn)
        let out = withNumbers(rawOut)
        let exempt = correctedSpans(input)

        let numbers = compareNumbers(input, exempt: exempt, out: out)
        if numbers == .mismatch { return .reject(.changedNumber) }

        if !negationsKept(input, exempt: exempt, out: out) { return .reject(.negation) }

        var inTotal: [String: Int] = [:]
        var inRequired: [String: Int] = [:]
        for (i, t) in input.enumerated() where isContent(t) {
            inTotal[t.text, default: 0] += 1
            if !exempt[i] { inRequired[t.text, default: 0] += 1 }
        }
        var outCount: [String: Int] = [:]
        for t in out where isContent(t) { outCount[t.text, default: 0] += 1 }

        var required = 0
        var dropped = 0
        for (word, n) in inRequired {
            required += n
            dropped += max(0, n - outCount[word, default: 0])
        }
        if dropped > 0 && Double(dropped) / Double(required) > limits.maxDropShare { return .reject(.droppedContent) }

        var outContent = 0
        var added = 0
        var repeated = 0
        for (word, n) in outCount {
            outContent += n
            let said = inTotal[word, default: 0]
            if said == 0 { added += n } else { repeated += max(0, n - said) }
        }
        let allowance = Int((limits.maxAddedShare * Double(outContent)).rounded(.down))
        if added > allowance { return .reject(.addedContent) }
        if added + repeated > allowance { return .reject(.duplicated) }

        let withNums = numbers == .oneByOne
        let inSeq = input.filter { isContent($0) || (withNums && $0.kind == .num) }.map(\.text)
        let outSeq = out.filter { (isContent($0) && inTotal[$0.text] != nil) || (withNums && $0.kind == .num) }
            .map(\.text)
        if !isSubsequence(outSeq, of: inSeq) { return .reject(.reordered) }

        return .accept(output)
    }

    private static func isSubsequence(_ small: [String], of big: [String]) -> Bool {
        var i = 0
        for word in big where i < small.count && word == small[i] { i += 1 }
        return i == small.count
    }

    // MARK: Characters (unicode scalars; the TypeScript mirror uses code points)

    /// Unicode White_Space, plus the zero-width space and the byte order mark.
    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        let c = s.value
        return (c >= 0x09 && c <= 0x0D) || c == 0x20 || c == 0x85 || c == 0xA0 || c == 0x1680
            || (c >= 0x2000 && c <= 0x200B) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F
            || c == 0x3000 || c == 0xFEFF
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

    private static func isAsciiLetter(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x41 && s.value <= 0x5A) || (s.value >= 0x61 && s.value <= 0x7A)
    }

    private static func isApostrophe(_ s: Unicode.Scalar) -> Bool { s == "'" || s == "\u{2019}" }

    private static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func lowerAscii(_ s: String) -> String {
        string(s.unicodeScalars.map { $0.value >= 0x41 && $0.value <= 0x5A ? Unicode.Scalar($0.value + 32)! : $0 })
    }

    private static func trimSpace(_ s: String) -> String {
        let chars = Array(s.unicodeScalars)
        var start = 0
        var end = chars.count
        while start < end && isSpace(chars[start]) { start += 1 }
        while end > start && isSpace(chars[end - 1]) { end -= 1 }
        return string(chars[start..<end])
    }

    // MARK: Wrappers

    private static let wrapperWords = wordSet("""
        here heres cleaned corrected cleanup output result revised rewritten edited formatted transcript \
        transcription normalized normalised text version sure certainly
        """)

    private static func hasWrapper(input: String, output: String) -> Bool {
        for tag in tags(output) where !scalarsContain(input, tag) { return true }
        for marker in ["```", "<|", "|>", "[INST]", "[/INST]"]
        where scalarsContain(output, marker) && !scalarsContain(input, marker) {
            return true
        }
        let outChars = Array(output.unicodeScalars)
        if outChars.count > 1, let first = outChars.first, let last = outChars.last,
           first == "\"" || first == "\u{201C}", last == "\"" || last == "\u{201D}" {
            let inFirst = trimSpace(input).unicodeScalars.first
            if inFirst != "\"" && inFirst != "\u{201C}" { return true }
        }
        let inWords = scan(input).map(\.text)
        let outWords = scan(output).map(\.text)
        // A leading "Sure," / "Certainly," / "Here is" the speaker did not start with.
        let lead = outWords.first ?? ""
        let second = outWords.count > 1 ? outWords[1] : ""
        if lead == "sure" || lead == "certainly" || lead == "heres" || (lead == "here" && second == "is"),
           inWords.first != lead {
            return true
        }
        // A preamble ending in a colon on the first line ("Cleaned text:", "Here is the result:").
        if let colon = outChars.firstIndex(of: ":"), colon > 0 {
            let prefix = outChars[0..<colon]
            if !prefix.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "." || $0 == "!" || $0 == "?" }) {
                let words = scan(string(prefix)).map(\.text)
                if words.contains(where: { wrapperWords.contains($0) }) && !containsRun(inWords, words) { return true }
            }
        }
        return false
    }

    /// Substring test on unicode scalars, as the TypeScript mirror's `includes` works on code
    /// units. `String.contains` compares graphemes, so "<b>" followed by a combining mark would
    /// not count as containing "<b>" there.
    private static func scalarsContain(_ text: String, _ needle: String) -> Bool {
        let hay = Array(text.unicodeScalars)
        let run = Array(needle.unicodeScalars)
        if run.isEmpty { return true }
        if run.count > hay.count { return false }
        for i in 0...(hay.count - run.count) where hay[i..<(i + run.count)].elementsEqual(run) { return true }
        return false
    }

    private static func containsRun(_ big: [String], _ run: [String]) -> Bool {
        if run.isEmpty { return true }
        if run.count > big.count { return false }
        for i in 0...(big.count - run.count) where Array(big[i..<(i + run.count)]) == run { return true }
        return false
    }

    /// Every "<name ...>", "</name>" or "<name/>" in the text, by a hand scanner both cores share.
    private static func tags(_ text: String) -> [String] {
        let chars = Array(text.unicodeScalars)
        func at(_ k: Int) -> Unicode.Scalar? { k < chars.count ? chars[k] : nil }
        var out: [String] = []
        var i = 0
        while i < chars.count {
            defer { i += 1 }
            guard chars[i] == "<" else { continue }
            var j = i + 1
            if at(j) == "/" { j += 1 }
            guard let c = at(j), isAsciiLetter(c) else { continue }
            while let c = at(j), isAsciiLetter(c) || isDigit(c) || c == "_" || c == ":" || c == "-" { j += 1 }
            guard let stop = at(j), stop == ">" || stop == "/" || isSpace(stop) else { continue }
            while let c = at(j), c != ">" && c != "<" { j += 1 }
            guard at(j) == ">" else { continue }
            out.append(string(chars[i...j]))
            i = j
        }
        return out
    }

    // MARK: Tokens

    private enum Kind { case word, num }

    private struct Tok {
        var kind: Kind
        /// Lowercase word without apostrophes, or a digit string ("40000", "2.5", "0123").
        var text: String
        var commaBefore: Bool
        var commaAfter: Bool
        /// First token of a sentence: text start, or after . ! ? or a line break.
        var sentenceStart: Bool
    }

    /// Words and digit runs. "40,000" is one run (the comma is a thousands separator), "2.5" keeps
    /// its point, "555-0123" is two runs. "1st" drops its suffix, and ":00" after an hour is dropped
    /// ("5:00" is "5"), so formatting a number never invents one.
    private static func scan(_ text: String) -> [Tok] {
        let chars = Array(text.unicodeScalars)
        func at(_ k: Int) -> Unicode.Scalar? { k >= 0 && k < chars.count ? chars[k] : nil }
        func digitAt(_ k: Int) -> Bool { at(k).map(isDigit) ?? false }
        func letterAt(_ k: Int) -> Bool { at(k).map(isLetter) ?? false }
        var out: [Tok] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if !isLetter(ch) && !isDigit(ch) {
                i += 1
                continue
            }
            let start = i
            var value: [Unicode.Scalar] = []
            let kind: Kind
            if isDigit(ch) {
                kind = .num
                while i < chars.count {
                    let c = chars[i]
                    if isDigit(c) {
                        value.append(c)
                        i += 1
                    } else if c == ",", digitAt(i + 1), digitAt(i + 2), digitAt(i + 3), !digitAt(i + 4) {
                        i += 1
                    } else if c == ".", digitAt(i + 1) {
                        value.append(c)
                        i += 1
                    } else {
                        break
                    }
                }
            } else {
                kind = .word
                while i < chars.count {
                    let c = chars[i]
                    if isLetter(c) {
                        value.append(c)
                        i += 1
                    } else if isApostrophe(c), letterAt(i + 1), !value.isEmpty {
                        i += 1
                    } else {
                        break
                    }
                }
            }
            var text = string(value)
            if kind == .word {
                text = lowerAscii(text)
                // "1st", "22nd", "3rd", "4th" written straight after the digits.
                if out.last?.kind == .num, digitAt(start - 1), ordinalSuffix.contains(text) { continue }
            }
            if kind == .num, value.allSatisfy({ $0 == "0" }), at(start - 1) == ":" { continue }
            var k = start - 1
            var sawBreak = false
            while let c = at(k), isSpace(c) {
                if c == "\n" || c == "\r" { sawBreak = true }
                k -= 1
            }
            let before = at(k)
            out.append(Tok(
                kind: kind, text: text, commaBefore: before == ",", commaAfter: at(i) == ",",
                sentenceStart: k < 0 || sawBreak || before == "." || before == "!" || before == "?"))
        }
        return out
    }

    private static func wordSet(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    private static let ordinalSuffix: Set<String> = ["st", "nd", "rd", "th"]

    // MARK: Spoken numbers

    private enum NumKind { case unit, teen, tens, hundred, scale, dozen }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000]
    private static let unitOrdinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]
    private static let teenOrdinals: [String: Int] = [
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
    ]
    private static let tensOrdinals: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70,
        "eightieth": 80, "ninetieth": 90,
    ]
    private static let scaleOrdinals: [String: Int] = [
        "thousandth": 1000, "millionth": 1_000_000, "billionth": 1_000_000_000,
    ]

    private static func numberKind(_ word: String) -> (kind: NumKind, value: Int, ordinal: Bool)? {
        if let v = units[word] { return (.unit, v, false) }
        if let v = teens[word] { return (.teen, v, false) }
        if let v = tens[word] { return (.tens, v, false) }
        if word == "hundred" { return (.hundred, 100, false) }
        if let v = scales[word] { return (.scale, v, false) }
        if word == "dozen" { return (.dozen, 12, false) }
        if let v = unitOrdinals[word] { return (.unit, v, true) }
        if let v = teenOrdinals[word] { return (.teen, v, true) }
        if let v = tensOrdinals[word] { return (.tens, v, true) }
        if word == "hundredth" { return (.hundred, 100, true) }
        if let v = scaleOrdinals[word] { return (.scale, v, true) }
        return nil
    }

    private static let aMultiplied: Set<String> = ["hundred", "thousand", "million", "billion", "dozen"]

    /// Replaces each run of number words with one digit token: "forty two" -> "42", "a dozen" -> "12".
    private static func withNumbers(_ tokens: [Tok]) -> [Tok] {
        func tok(_ k: Int) -> Tok? { k >= 0 && k < tokens.count ? tokens[k] : nil }
        var out: [Tok] = []
        var i = 0
        while i < tokens.count {
            let first = tokens[i]
            let startsWithA = first.kind == .word && first.text == "a" && aMultiplied.contains(tok(i + 1)?.text ?? "")
            if first.kind != .word || (!startsWithA && numberKind(first.text) == nil) {
                out.append(first)
                i += 1
                continue
            }
            var total = 0
            var current = 0
            var last: NumKind?
            var fraction = ""
            var j = i
            while let t = tok(j), t.kind == .word {
                if j == i && startsWithA {
                    current = 1
                    last = .unit
                    j += 1
                    continue
                }
                if t.text == "and" && (last == .hundred || last == .scale) {
                    if let next = tok(j + 1), next.kind == .word, let after = numberKind(next.text),
                       after.kind == .unit || after.kind == .teen || after.kind == .tens {
                        j += 1
                        continue
                    }
                    break
                }
                if t.text == "point", last != nil, last != .dozen {
                    var k = j + 1
                    var digits = ""
                    while let d = tok(k), d.kind == .word, let u = units[d.text] {
                        digits += String(u)
                        k += 1
                    }
                    if digits.isEmpty { break }
                    fraction = digits
                    j = k
                    break
                }
                guard let n = numberKind(t.text) else { break }
                var ok = false
                switch n.kind {
                case .unit:
                    ok = last == nil || last == .hundred || last == .scale || (last == .tens && current % 10 == 0)
                    if ok { current += n.value }
                case .teen, .tens:
                    ok = last == nil || last == .hundred || last == .scale
                    if ok { current += n.value }
                case .hundred:
                    if last == nil {
                        ok = true
                        current = 100
                    } else if last == .unit || last == .teen || last == .tens, current > 0, current < 100 {
                        ok = true
                        current *= 100
                    }
                case .scale:
                    if last == nil {
                        ok = true
                        total += n.value
                    } else if last == .unit || last == .teen || last == .tens || last == .hundred {
                        ok = true
                        total += current * n.value
                        current = 0
                    }
                case .dozen:
                    if last == nil {
                        ok = true
                        current = 12
                    } else if last == .unit || last == .teen || last == .tens {
                        ok = true
                        current *= 12
                    }
                }
                if !ok { break }
                last = n.kind
                j += 1
                if n.ordinal || n.kind == .dozen { break }
            }
            if j == i || (startsWithA && j == i + 1) {
                out.append(first)
                i += 1
                continue
            }
            let end = tokens[j - 1]
            let value = String(total + current) + (fraction.isEmpty ? "" : ".\(fraction)")
            out.append(Tok(
                kind: .num, text: value, commaBefore: first.commaBefore, commaAfter: end.commaAfter,
                sentenceStart: first.sentenceStart))
            i = j
        }
        return out
    }

    private enum NumberMatch { case aligned, oneByOne, mismatch }

    /// `aligned`: the numbers match in order, possibly merged or split ("5 5 5" vs "555").
    /// `oneByOne`: they match as a multiset but not in order, so the order check includes them.
    /// `mismatch`: a number was changed, dropped or invented.
    private static func compareNumbers(_ input: [Tok], exempt: [Bool], out: [Tok]) -> NumberMatch {
        let all = input.filter { $0.kind == .num }.map(\.text)
        let kept = input.indices.filter { input[$0].kind == .num && !exempt[$0] }.map { input[$0].text }
        let produced = out.filter { $0.kind == .num }.map(\.text)
        if aligned(all, produced) || aligned(kept, produced) { return .aligned }
        var pool: [String: Int] = [:]
        for v in all { pool[v, default: 0] += 1 }
        for v in produced {
            let n = pool[v, default: 0]
            if n == 0 { return .mismatch }
            pool[v] = n - 1
        }
        var need: [String: Int] = [:]
        for v in kept { need[v, default: 0] += 1 }
        var have: [String: Int] = [:]
        for v in produced { have[v, default: 0] += 1 }
        for (v, n) in need where have[v, default: 0] < n { return .mismatch }
        return .oneByOne
    }

    /// Same digits in the same order, where a group of neighbouring runs may merge into one.
    private static func aligned(_ a: [String], _ b: [String]) -> Bool {
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            let x = a[i]
            let y = b[j]
            if x == y {
                i += 1
                j += 1
                continue
            }
            var acc = x
            var k = i + 1
            while acc.count < y.count && k < a.count {
                acc += a[k]
                k += 1
            }
            if acc == y && k - i > 1 {
                i = k
                j += 1
                continue
            }
            acc = y
            k = j + 1
            while acc.count < x.count && k < b.count {
                acc += b[k]
                k += 1
            }
            if acc == x && k - j > 1 {
                j = k
                i += 1
                continue
            }
            return false
        }
        return i == a.count && j == b.count
    }

    // MARK: Negation

    private static let negations: [String: String] = {
        var map: [String: String] = [:]
        for word in wordSet("""
            not cannot dont doesnt didnt cant wont isnt arent wasnt werent hasnt havent hadnt couldnt wouldnt \
            shouldnt mustnt neednt aint shant mightnt darent
            """) {
            map[word] = "not"
        }
        for word in ["no", "never", "nor", "none", "nothing", "nobody", "neither", "nowhere"] { map[word] = word }
        return map
    }()

    private static func negationsKept(_ input: [Tok], exempt: [Bool], out: [Tok]) -> Bool {
        var total: [String: Int] = [:]
        var required: [String: Int] = [:]
        for (i, t) in input.enumerated() where t.kind == .word {
            guard let key = negations[t.text] else { continue }
            total[key, default: 0] += 1
            if !exempt[i] { required[key, default: 0] += 1 }
        }
        var have: [String: Int] = [:]
        for t in out where t.kind == .word {
            if let key = negations[t.text] { have[key, default: 0] += 1 }
        }
        for (key, n) in required where have[key, default: 0] < n { return false }
        for (key, n) in have where n > total[key, default: 0] { return false }
        return true
    }

    // MARK: Content words

    private static let stop = wordSet("""
        a an the and or but so yet of to in on at by for with from into onto over under about as than then \
        that this these those there here is are was were be been being am do does did done have has had having \
        will would shall should can could may might must i me my mine we us our you your he him his she her it its \
        they them their who whom whose which what when where why how if just also very really too quite some any \
        all each both few more most other such only own same up down out off again once now well oh okay ok yeah yes \
        im ive ill id youre youve hes shes theyre thats whats lets theres heres um uh erm hmm like know basically \
        literally honestly anyway kind sort
        """)

    private static let cues = wordSet("wait sorry scratch oops whoops rather mean actually correction")

    private static let symbols = wordSet("""
        at dot dash slash backslash underscore hash colon semicolon hyphen comma period percent dollar dollars \
        cent cents euro euros pound pounds oclock am pm point p m
        """)

    private static func isContent(_ t: Tok) -> Bool {
        t.kind == .word && !stop.contains(t.text) && !cues.contains(t.text) && !symbols.contains(t.text)
            && negations[t.text] == nil
    }

    private static func isContentOrNumber(_ t: Tok?) -> Bool {
        guard let t = t else { return false }
        return t.kind == .num || isContent(t)
    }

    // MARK: Self-corrections

    /// The cue that starts at `p`, as start..<end, or nil. See the header comment for the patterns.
    private static func cueAt(_ tokens: [Tok], _ p: Int) -> Range<Int>? {
        func tok(_ k: Int) -> Tok? { k >= 0 && k < tokens.count ? tokens[k] : nil }
        guard let t = tok(p), t.kind == .word else { return nil }
        let prev = tok(p - 1)
        let next = tok(p + 1)
        func comma(_ k: Int) -> Bool { tok(k)?.commaBefore == true }
        func commaOrStart(_ k: Int) -> Bool { comma(k) || tok(k)?.sentenceStart == true }
        switch t.text {
        case "wait":
            if let prev = prev, prev.text == "no" || prev.text == "oh", commaOrStart(p - 1) { return (p - 1)..<(p + 1) }
            return commaOrStart(p) ? p..<(p + 1) : nil
        case "sorry":
            return t.commaBefore || t.commaAfter ? p..<(p + 1) : nil
        case "mean":
            return prev?.text == "i" && comma(p - 1) ? (p - 1)..<(p + 1) : nil
        case "actually":
            return t.commaAfter && comma(p) ? p..<(p + 1) : nil
        case "rather":
            return prev?.text == "or" && comma(p - 1) ? (p - 1)..<(p + 1) : nil
        case "make", "scratch":
            return next?.text == "that" && next?.kind == .word ? p..<(p + 2) : nil
        case "no":
            return t.commaBefore && t.commaAfter ? p..<(p + 1) : nil
        default:
            return nil
        }
    }

    private static let fillerWords: Set<String> = ["um", "uh", "erm", "er", "hmm"]

    /// Marks the tokens a real self-correction replaced, so they may vanish from the output.
    private static func correctedSpans(_ tokens: [Tok]) -> [Bool] {
        func tok(_ k: Int) -> Tok? { k >= 0 && k < tokens.count ? tokens[k] : nil }
        var exempt = Array(repeating: false, count: tokens.count)
        var p = 0
        while p < tokens.count {
            guard let cue = cueAt(tokens, p) else {
                p += 1
                continue
            }
            let start = cue.lowerBound
            var end = cue.upperBound
            // "no wait, make that": back-to-back cues are one.
            while true {
                var q = end
                while let t = tok(q), fillerWords.contains(t.text) { q += 1 }
                var more = cueAt(tokens, q)
                if more == nil, let t = tok(q), t.text == "no" || t.text == "oh" { more = cueAt(tokens, q + 1) }
                guard let found = more, found.lowerBound <= q + 1 else { break }
                end = found.upperBound
            }
            // The repair: content words and numbers after the cue, up to the next comma or sentence end.
            var repair = 0
            var k = end
            while k < tokens.count {
                let t = tokens[k]
                if k > end && (t.commaBefore || t.sentenceStart) { break }
                if isContentOrNumber(t) { repair += 1 }
                k += 1
            }
            // Content before it: back to this sentence's start, or the previous sentence when the cue starts one.
            let floor = sentenceFloor(tokens, start)
            var found = 0
            var from = start
            k = start - 1
            while k >= floor && found < min(maxCorrected, max(1, repair)) {
                if isContentOrNumber(tokens[k]) {
                    found += 1
                    from = k
                }
                k -= 1
            }
            if repair > 0 && found > 0 {
                for m in from..<end { exempt[m] = true }
            }
            p = end
        }
        return exempt
    }

    /// Most content words or numbers one correction may replace.
    private static let maxCorrected = 4

    /// Where the corrected span may start: this sentence's start, or, for a cue that starts a
    /// sentence, the previous sentence's start when that sentence is short (at most 4 content
    /// words or numbers). A longer previous sentence is out of reach.
    private static func sentenceFloor(_ tokens: [Tok], _ start: Int) -> Int {
        var k = start
        let cueStartsSentence = k < tokens.count && tokens[k].sentenceStart
        if cueStartsSentence { k -= 1 }
        while k > 0 && !tokens[k].sentenceStart { k -= 1 }
        let floor = max(0, k)
        if cueStartsSentence && tokens[floor..<start].filter({ isContentOrNumber($0) }).count > maxCorrected {
            return start
        }
        return floor
    }
}
