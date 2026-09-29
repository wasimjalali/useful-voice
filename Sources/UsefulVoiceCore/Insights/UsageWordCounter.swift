import Foundation

/// Counts words the way a person would.
///
/// * A word is a run of letters and digits. An apostrophe or hyphen between two of them
///   stays inside the word ("don't", "well-known"), and so does a dot or comma between two
///   digits ("3.5", "1,000"). Other punctuation, symbols and emoji are never words.
/// * Chinese, Japanese and Thai are not written with spaces, so one space-free run of
///   those characters is counted as ceil(characters / 2) words. Two characters is a fair
///   average word length in those scripts, which keeps the count and words per minute in
///   the same range as spaced languages without needing a dictionary segmenter.
///   Korean is written with spaces and counts like any other language.
public enum UsageWordCounter {
    public static func count(_ text: String) -> Int {
        let scalars = Array(text.unicodeScalars)
        var words = 0
        var inWord = false
        var cjkRun = 0

        func endCJK() {
            words += (cjkRun + 1) / 2
            cjkRun = 0
        }

        for (i, s) in scalars.enumerated() {
            if isCJK(s) {
                inWord = false
                cjkRun += 1
                continue
            }
            if cjkRun > 0 { endCJK() }

            if isLetterOrDigit(s) {
                if !inWord { words += 1; inWord = true }
            } else if inWord, i + 1 < scalars.count, joins(s, previous: scalars[i - 1], next: scalars[i + 1]) {
                continue
            } else {
                inWord = false
            }
        }
        if cjkRun > 0 { endCJK() }
        return words
    }

    private static func isLetterOrDigit(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(s)
    }

    private static func joins(_ s: Unicode.Scalar, previous: Unicode.Scalar, next: Unicode.Scalar) -> Bool {
        guard isLetterOrDigit(next), !isCJK(next) else { return false }
        switch s {
        case "'", "\u{2019}", "-":
            return isLetterOrDigit(previous)
        case ".", ",":
            return isDigit(previous) && isDigit(next)
        default:
            return false
        }
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.decimalDigits.contains(s)
    }

    private static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x309F, // Hiragana
             0x30A0...0x30FF, // Katakana
             0x3400...0x4DBF, // Han extension A
             0x4E00...0x9FFF, // Han
             0xF900...0xFAFF, // Han compatibility
             0x20000...0x2FA1F, // Han extensions B to F
             0x0E00...0x0E7F: // Thai
            return true
        default:
            return false
        }
    }
}
