import Foundation

/// Number style for Deepgram Smart Format output.
///
/// Deepgram decides most formatting (punctuation, casing, dates, money), and this
/// only closes the gaps it cannot. `numerals=true` used to be sent to get digits,
/// but it turned every spoken number into digits, so "the first numbers" became
/// "the 1st numbers". Without it English already writes small numbers and
/// ordinals as words, so English needs nothing beyond keeping version and model
/// numbers as digits. German Smart Format digitises regardless, so German small
/// numbers and ordinals are put back into words here.
///
/// Every rule leaves the text alone when it is unsure: a wrong digit is better
/// than a wrong word. Nothing here adds, drops or reorders what was said.
/// `windows/src/core/formatting/transcriptStyle.ts` mirrors this file rule for rule.
public enum TranscriptStyle {
    public static func apply(to text: String, language: String?) -> String {
        guard let code = language?.lowercased() else { return text }
        if code == "en" || code.hasPrefix("en-") { return english(text) }
        if code == "de" || code.hasPrefix("de-") { return german(text) }
        return text
    }

    // MARK: English

    private static let englishNumbers = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]

    /// "version two" -> "version 2", "GPT-five" -> "GPT-5". The number after the
    /// word "version" or a hyphenated all-caps product code is a name, not a
    /// quantity. "version" only counts when it is the only "version <number>" in the
    /// text and the number ends the phrase ("version two is out"), so pairs and lists
    /// ("version one to version two", "version one, two and three"), "version one
    /// users" and "the version one would expect" are left as spoken. "one" is also the
    /// pronoun, so it needs punctuation after it. A bare acronym followed by a number
    /// ("the API one more time") is never touched.
    static func english(_ text: String) -> String {
        let words = "one|two|three|four|five|six|seven|eight|nine|ten"
        let others = "two|three|four|five|six|seven|eight|nine|ten"
        var result = text
        let versions = #"\b[Vv]ersion\s+(?:\#(words))\b"#
        if let count = try? NSRegularExpression(pattern: versions)
            .numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)), count == 1 {
            let notAList = #"(?!\s*,?\s*(?:and|or)\s+(?:\#(words))\b)(?!\s*,\s*(?:\#(words))\b)"#
            result = replacing(#"\b([Vv]ersion)(\s+)(\#(others))\#(notAList)(?=\s*(?:[.,;:!?)]|$)|\s+(?:is|was)\b)"#, in: result) {
                "\($0[1])\($0[2])\(englishNumbers[$0[3]] ?? $0[3])"
            }
            result = replacing(#"\b([Vv]ersion)(\s+)(one)\#(notAList)(?=\s*(?:[.,;:!?)]|$))"#, in: result) {
                "\($0[1])\($0[2])\(englishNumbers[$0[3]] ?? $0[3])"
            }
        }
        result = replacing(#"\b(?!(?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN)-)([A-Z]{3,5})(-)(\#(words))\b(?!-)"#, in: result) {
            "\($0[1])\($0[2])\(englishNumbers[$0[3]] ?? $0[3])"
        }
        return result
    }

    // MARK: German

    private static let germanCardinals = [
        2: "zwei", 3: "drei", 4: "vier", 5: "fünf", 6: "sechs", 7: "sieben", 8: "acht", 9: "neun",
    ]
    private static let germanOrdinalStems = [
        1: "erst", 2: "zweit", 3: "dritt", 4: "viert", 5: "fünft",
        6: "sechst", 7: "siebt", 8: "acht", 9: "neunt",
    ]
    /// Words after which an ordinal has a certain ending. Only the unambiguous
    /// articles are listed: "der" and "die" can be masculine, feminine or plural,
    /// and a wrong ending would change a word the speaker said.
    /// "am", "vom" and "den" are left out on purpose: "am 3." and "Dienstag, den 3." are
    /// dates that often end a sentence ("den 5. Kommst du?"), and a date is not an
    /// ordinal to spell out.
    private static let ordinalEndings = [
        "das": "e",
        "dem": "en", "des": "en",
        "im": "en", "zum": "en", "beim": "en", "zur": "en",
    ]
    private static let months: Set<String> = [
        "januar", "jänner", "februar", "märz", "april", "mai", "juni", "juli", "august",
        "september", "oktober", "november", "dezember",
        "jan", "feb", "mär", "apr", "jun", "jul", "aug", "sep", "sept", "okt", "nov", "dez",
    ]
    /// A digit before one of these is a measurement, a price or a clock time, so it stays.
    private static let units: Set<String> = [
        "uhr", "euro", "cent", "dollar", "franken", "pfund", "prozent", "grad",
        "gigabyte", "megabyte", "kilobyte", "terabyte", "gb", "mb", "kb", "tb",
        "kilometer", "km", "meter", "m", "zentimeter", "cm", "millimeter", "mm",
        "kilogramm", "kg", "gramm", "g", "liter", "l", "ml", "watt", "volt",
        "kwh", "ps", "h", "std", "min", "mio", "mrd", "x", "chf", "eur", "usd", "gbp", "tsd", "pkt",
    ]
    /// The only words after which "3.5" becomes "3,5". Deliberately not "Uhr": "10.30 Uhr"
    /// is a time. A decimal anywhere else could be a section number or a version.
    private static let decimalUnits: Set<String> = units.subtracting(["uhr", "x", "h"]).union([
        "stunden", "minuten", "sekunden", "tage", "tagen", "wochen", "monate", "monaten",
        "jahre", "jahren", "millionen", "milliarden", "tonnen", "kilo", "prozentpunkte",
    ])
    /// A decimal after one of these is a date, a clock time, a range or a comparison
    /// ("am 3.5.", "von 2.5 auf 3.5 Prozent"), so it stays.
    private static let dateOrRangeLeadIns: Set<String> = [
        "am", "bis", "ab", "vom", "seit", "zum", "dem", "um", "gegen", "von", "zwischen", "x",
        "auf", "zu", "und", "oder",
    ]
    /// A small cardinal becomes a word only after one of these, which clearly take a
    /// quantity ("habe 2 Katzen", "in 2 Wochen"). After anything else it could be a
    /// product ("iOS 9", "iPad 2"), a label ("die 7"), a street number, a version or
    /// one half of a range, and the digit stays. Determiners are left out on purpose.
    private static let quantityLeadIns: Set<String> = [
        "habe", "hast", "hat", "haben", "habt", "hatte", "hatten", "sind", "waren", "gibt", "gab",
        "brauche", "brauchst", "braucht", "brauchen", "nur", "noch", "schon", "bereits", "mit", "für",
        "in", "nach", "vor", "seit", "über", "etwa", "ungefähr", "fast", "knapp", "genau", "sogar",
    ]
    /// A bare number before one of these is half of a range, score, sum or comparison.
    private static let rangeFollowers: Set<String> = [
        "bis", "von", "gegen", "zu", "auf", "und", "oder", "statt", "anstatt", "vor", "nach",
        "mal", "plus", "minus", "durch", "kommt",
    ]
    /// A word that starts the next sentence. An ordinal followed by one is a date or a
    /// number that ended a sentence ("im 5. Das merkt man."), not "im fünften Das".
    private static let sentenceStarters: Set<String> = [
        "das", "der", "die", "er", "sie", "es", "wir", "ihr", "ich", "du", "man", "dann", "danach",
        "dort", "hier", "also", "aber", "doch", "jetzt", "heute", "morgen", "später", "zuerst",
        "wenn", "weil", "dass", "ob", "wie", "was", "wer", "wo", "wann", "warum", "nun", "nur",
        "noch", "schon", "ja", "nein", "vielleicht", "leider", "bitte", "danke", "ok", "okay",
        "gut", "dabei", "davor", "zuletzt", "zum", "im", "am", "in",
    ]
    private static let symbolsAfter = Set("%€$£°§+×*=÷-–/:")
    private static let symbolsBefore = Set("€$£§#№-–—/+×*=÷:")

    static func german(_ text: String) -> String {
        germanSmallNumbers(germanDecimals(text))
    }

    /// "3.5 Gigabyte" -> "3,5 Gigabyte". Only before a unit or quantity word, and not
    /// after a capitalised word, digit or hyphen ("Version 3.5", "GPT-4.5").
    private static func germanDecimals(_ text: String) -> String {
        replacing(#"(?<![\w.,\-])(\d+)\.(\d{1,2})(?![\w.,])"#, in: text, using: { groups, context in
            guard let next = context.nextWord, decimalUnits.contains(next.lowercased()) else { return nil }
            let prev = context.previousWord
            if let prev, prev.first?.isUppercase == true || prev.contains(where: \.isNumber) { return nil }
            if let prev, dateOrRangeLeadIns.contains(prev.lowercased()) { return nil }
            return "\(groups[1]),\(groups[2])"
        })
    }

    private static let smallNumberPattern =
        #"(?<![\w.,:/+\-–%€$£#@])(\d)(\.)?(?![\w:/%°€$£+\-–]|[.,]\d|\.\p{L})"#

    /// "2 Fragen" -> "zwei Fragen", "das 1. Kapitel" -> "das erste Kapitel".
    ///
    /// All or nothing per sentence: if any single digit in a sentence cannot be turned
    /// into a word safely, none of that sentence's single digits are. That is what
    /// keeps lists, ranges, scores and "die 3 ... die 4" from coming out half converted.
    private static func germanSmallNumbers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: smallNumberPattern),
              let boundary = try? NSRegularExpression(pattern: #"(?<!\d)[.!?]+(?=\s|$)"#) else {
            assertionFailure("invalid small-number pattern")
            return text
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: full)
        guard !matches.isEmpty else { return text }
        // A full stop right after a digit is an ordinal dot, not a sentence end.
        let boundaries = boundary.matches(in: text, range: full).map { $0.range.location + $0.range.length }

        struct Decision { let range: NSRange; let replacement: String?; let chunk: Int }
        var decisions: [Decision] = []
        var converted = Set<Int>()
        for match in matches {
            let chunk = boundaries.filter { $0 <= match.range.location }.count
            let context = MatchContext(
                before: ns.substring(to: match.range.location),
                after: ns.substring(from: match.range.location + match.range.length))
            let replacement = smallNumberWord(
                digit: Int(ns.substring(with: match.range(at: 1))) ?? 0,
                ordinal: match.range(at: 2).location != NSNotFound,
                context: context,
                afterConvertedNumber: converted.contains(chunk))
            if replacement != nil { converted.insert(chunk) }
            decisions.append(Decision(range: match.range, replacement: replacement, chunk: chunk))
        }
        let blocked = Set(decisions.filter { $0.replacement == nil }.map(\.chunk))
        var result = ns
        for decision in decisions.reversed() where !blocked.contains(decision.chunk) {
            if let replacement = decision.replacement {
                result = result.replacingCharacters(in: decision.range, with: replacement) as NSString
            }
        }
        return result as String
    }

    /// The word for one digit, or nil when it must stay a digit.
    private static func smallNumberWord(digit: Int, ordinal: Bool, context: MatchContext,
                                        afterConvertedNumber: Bool) -> String? {
        let before = context.before.trimmingCharacters(in: .whitespaces)
        let after = context.after
        let afterTrimmed = after.drop(while: { $0 == " " })

        // Lists, ranges, sums and scores of digits stay digits.
        if before.last?.isNumber == true { return nil }
        if before.hasSuffix(","), before.dropLast().last?.isNumber == true { return nil }
        if let last = before.last, symbolsBefore.contains(last) { return nil }
        if let first = afterTrimmed.first, first.isNumber || symbolsAfter.contains(first) { return nil }
        if afterTrimmed.hasPrefix(","), afterTrimmed.dropFirst().drop(while: { $0 == " " }).first?.isNumber == true { return nil }

        // "14 und 5", "11 oder 3": one half of a pair of numbers, whatever their length.
        if before.range(of: #"\d[\d.,:]*\s*(und|oder)$"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }

        // Sentence start counts only at the very start of the text or after "!" or "?".
        // After a full stop the previous word may be an abbreviation ("inkl. 3",
        // "Hauptstr. 3", "ca. 3"), so a digit there stays.
        let atSentenceStart = before.isEmpty || before.last == "!" || before.last == "?"

        if ordinal {
            // Needs a following word; "3." at the end of a sentence is ambiguous.
            guard after.first == " ", let next = context.nextWord,
                  let ending = context.previousWord.flatMap({ ordinalEndings[$0.lowercased()] }),
                  let stem = germanOrdinalStems[digit] else { return nil }
            let lower = next.lowercased()
            if months.contains(lower) || sentenceStarters.contains(lower) || ["bis", "und", "oder"].contains(lower) { return nil }
            // "gegen den 1. FC Köln": an all-capitals word is a name, not a noun.
            if next.count > 1, next == next.uppercased() { return nil }
            return stem + ending
        }
        guard let word = germanCardinals[digit] else { return nil }
        if !atSentenceStart {
            guard let prev = context.previousWord else { return nil }
            let lower = prev.lowercased()
            // "und" and "oder" continue a quantity only after one that already converted.
            let continuesQuantity = ["und", "oder"].contains(lower) && afterConvertedNumber
            guard quantityLeadIns.contains(lower) || continuesQuantity else { return nil }
        }
        if let next = context.nextWord, units.contains(next.lowercased()) || rangeFollowers.contains(next.lowercased()) { return nil }
        return atSentenceStart ? word.prefix(1).uppercased() + word.dropFirst() : word
    }

    // MARK: Regex helper

    /// Text around one match, for rules that depend on the neighbouring words.
    struct MatchContext {
        let before: String
        let after: String

        var previousWord: String? {
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let last = trimmed.last, last.isLetter || last.isNumber else { return nil }
            let word = trimmed.reversed().prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" })
            return String(word.reversed())
        }

        var nextWord: String? {
            let word = after.drop(while: { $0 == " " }).prefix(while: { $0.isLetter })
            return word.isEmpty ? nil : String(word)
        }
    }

    private static func replacing(_ pattern: String, in text: String,
                                  using transform: ([String]) -> String?) -> String {
        replacing(pattern, in: text, using: { groups, _ in transform(groups) })
    }

    /// Replaces every match with `transform`'s result; a nil result keeps the
    /// match as it was. Matches are rewritten back to front so ranges stay valid.
    private static func replacing(_ pattern: String, in text: String,
                                  using transform: ([String], MatchContext) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            assertionFailure("invalid pattern \(pattern)")
            return text
        }
        let ns = text as NSString
        var result = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            let context = MatchContext(
                before: ns.substring(to: match.range.location),
                after: ns.substring(from: match.range.location + match.range.length))
            if let replacement = transform(groups, context) {
                result = result.replacingCharacters(in: match.range, with: replacement) as NSString
            }
        }
        return result as String
    }
}
