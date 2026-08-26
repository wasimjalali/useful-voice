import Foundation

/// Pure, stateless helpers for normalising and comparing dictionary terms.
/// All functions are free of side effects and safe to call from any context.
public enum TermMatcher {

    // Characters considered punctuation for the purposes of stripping
    // leading/trailing boundaries, including curly quotes.
    private static let punctuationCharacters: CharacterSet = {
        var cs = CharacterSet(charactersIn: ".,;:!?\"'()[]{}")
        // Curly single quotes U+2018 / U+2019 and curly double quotes U+201C / U+201D
        cs.insert(charactersIn: "\u{2018}\u{2019}\u{201C}\u{201D}")
        return cs
    }()

    /// Returns a normalised, canonical form of `term`:
    /// 1. Trim leading/trailing whitespace.
    /// 2. Strip leading and trailing punctuation (see `punctuationCharacters`).
    /// 3. Strip a trailing possessive (`'s` or curly-apostrophe `s`),
    ///    case-insensitive.
    /// 4. Collapse every internal run of whitespace or hyphens into a single space.
    /// 5. Lowercase the result.
    public static func canonical(_ term: String) -> String {
        var s = term.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading/trailing punctuation characters iteratively.
        while let first = s.unicodeScalars.first,
              punctuationCharacters.contains(first) {
            s = String(s.dropFirst())
        }
        while let last = s.unicodeScalars.last,
              punctuationCharacters.contains(last) {
            s = String(s.dropLast())
        }

        // Strip a trailing possessive ('s or curly-apostrophe s), case-insensitive.
        // The apostrophe itself was already stripped above if it was the *last*
        // character; here we handle the pattern <word>'s or <word>\u{2019}s.
        let possessiveSuffixes = ["'s", "\u{2019}s"]
        for suffix in possessiveSuffixes {
            if s.lowercased().hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count))
                break
            }
        }

        // Strip any punctuation again that got exposed after possessive removal.
        while let first = s.unicodeScalars.first,
              punctuationCharacters.contains(first) {
            s = String(s.dropFirst())
        }
        while let last = s.unicodeScalars.last,
              punctuationCharacters.contains(last) {
            s = String(s.dropLast())
        }

        // Collapse internal runs of whitespace or hyphens into a single space.
        // Build a new string by treating [-\s]+ as a single separator.
        var result = ""
        var inSeparator = false
        for ch in s {
            if ch == "-" || ch.isWhitespace {
                if !inSeparator && !result.isEmpty {
                    result.append(" ")
                    inSeparator = true
                }
            } else {
                result.append(ch)
                inSeparator = false
            }
        }
        // Trim any trailing separator that may have been appended.
        result = result.trimmingCharacters(in: .whitespaces)

        return result.lowercased()
    }

    /// Returns `true` when `a` and `b` are considered the same term.
    /// Two terms match when their canonicals are equal, or when one canonical
    /// equals the other plus a trailing `"s"` or `"es"` (plural tolerance).
    public static func matches(_ a: String, _ b: String) -> Bool {
        let ca = canonical(a)
        let cb = canonical(b)
        if ca == cb { return true }
        // Plural tolerance: one is the other + "s" or + "es".
        for (longer, shorter) in [(ca, cb), (cb, ca)] {
            if longer == shorter + "s" { return true }
            if longer == shorter + "es" { return true }
        }
        return false
    }
}
