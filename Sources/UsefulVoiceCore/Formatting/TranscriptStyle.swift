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
    /// word "version" or an all-caps product code is a name, not a quantity.
    static func english(_ text: String) -> String {
        let words = "one|two|three|four|five|six|seven|eight|nine|ten"
        var result = replacing(#"\b([Vv]ersion)(\s+)(\#(words))\b"#, in: text) {
            "\($0[1])\($0[2])\(englishNumbers[$0[3]] ?? $0[3])"
        }
        result = replacing(#"\b([A-Z]{2,5})([- ])(\#(words))\b"#, in: result) {
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
    private static let ordinalEndings = [
        "das": "e",
        "den": "en", "dem": "en", "des": "en",
        "am": "en", "im": "en", "zum": "en", "beim": "en", "vom": "en", "zur": "en",
    ]
    private static let months: Set<String> = [
        "januar", "jänner", "februar", "märz", "april", "mai", "juni", "juli", "august",
        "september", "oktober", "november", "dezember",
    ]
    /// A digit before one of these is a measurement or a clock time, so it stays.
    private static let units: Set<String> = [
        "uhr", "euro", "cent", "dollar", "franken", "pfund", "prozent", "grad",
        "gigabyte", "megabyte", "kilobyte", "terabyte", "gb", "mb", "kb", "tb",
        "kilometer", "km", "meter", "m", "zentimeter", "cm", "millimeter", "mm",
        "kilogramm", "kg", "gramm", "g", "liter", "l", "ml", "watt", "volt",
    ]
    /// A digit or decimal after one of these is a date ("am 3.5.") or a range.
    private static let dateLeadIns: Set<String> = ["am", "bis", "ab", "vom", "seit", "zum", "dem"]

    static func german(_ text: String) -> String {
        germanSmallNumbers(germanDecimals(text))
    }

    /// "3.5" -> "3,5". Left alone after a capitalised word ("Version 3.5",
    /// "iOS 17.4") and after a date lead-in ("am 3.5").
    private static func germanDecimals(_ text: String) -> String {
        replacing(#"(?<![\w.,])(\d+)\.(\d{1,2})(?![\w.,])"#, in: text, using: { groups, context in
            let prev = context.previousWord
            if let prev, prev.first?.isUppercase == true || prev.contains(where: \.isNumber) { return nil }
            if let prev, dateLeadIns.contains(prev.lowercased()) { return nil }
            return "\(groups[1]),\(groups[2])"
        })
    }

    /// "2 Fragen" -> "zwei Fragen", "das 1. Kapitel" -> "das erste Kapitel".
    private static func germanSmallNumbers(_ text: String) -> String {
        replacing(#"(?<![\w.,:/+\-–%€$£#@])(\d)(\.)?(?![\w:/%°€$£+\-–]|[.,]\d)"#, in: text, using: { groups, context in
            let digit = Int(groups[1]) ?? 0
            let ordinal = !groups[2].isEmpty
            let before = context.before.trimmingCharacters(in: .whitespaces)
            let after = context.after
            // Lists and ranges of digits ("1, 2, 3", "2 3", "5 - 7") stay digits.
            if before.last?.isNumber == true || before.hasSuffix(",") && before.dropLast().last?.isNumber == true { return nil }
            let afterTrimmed = after.drop(while: { $0 == " " })
            if let first = afterTrimmed.first, first.isNumber || "-–/".contains(first) { return nil }
            if afterTrimmed.hasPrefix(",") && afterTrimmed.dropFirst().drop(while: { $0 == " " }).first?.isNumber == true { return nil }

            let atSentenceStart = before.isEmpty || ".!?".contains(before.last!)

            if ordinal {
                // Needs a following word; "3." at the end of a sentence is ambiguous.
                guard after.first == " ", let next = context.nextWord,
                      let ending = context.previousWord.flatMap({ ordinalEndings[$0.lowercased()] }),
                      let stem = germanOrdinalStems[digit] else { return nil }
                let lower = next.lowercased()
                if months.contains(lower) || ["bis", "und", "oder"].contains(lower) { return nil }
                return stem + ending
            }
            guard let word = germanCardinals[digit] else { return nil }
            if !atSentenceStart, let prev = context.previousWord, prev.first?.isUppercase == true { return nil }
            if let next = context.nextWord, units.contains(next.lowercased()) { return nil }
            return atSentenceStart ? word.prefix(1).uppercased() + word.dropFirst() : word
        })
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
