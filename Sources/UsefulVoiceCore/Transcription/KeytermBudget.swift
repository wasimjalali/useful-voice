import Foundation

/// Deepgram's `keyterm` prompting has a hard per-request token limit. Exceeding
/// it is not a soft failure: the API rejects the whole request with
/// `Keyterm limit exceeded. The maximum number of tokens across all keyterms is 500.`
/// so a large personal dictionary would break *every* dictation.
/// https://developers.deepgram.com/docs/keyterm#key-term-limits
///
/// The token count is measured by Deepgram's own tokenizer, which we cannot run
/// locally, so we estimate and stay well under the ceiling.
public enum KeytermBudget {
    /// Deepgram's documented hard ceiling: 500 tokens across all keyterms.
    public static let hardTokenLimit = 500

    /// Reserve headroom. Real tokenization differs from our estimate (punctuation,
    /// unusual casing, digits, non-ASCII), and Deepgram's guidance is to stay
    /// "well under" the limit and focus on the top 20-50 terms.
    public static let safetyMarginTokens = 100

    /// The token budget we are willing to spend on keyterms in one request.
    public static var tokenBudget: Int { hardTokenLimit - safetyMarginTokens }

    /// Upper bound on how many keyterm strings we send regardless of token cost.
    /// Keeps the query string (and therefore the request URL) short: every term
    /// is URL-encoded into the request line, and servers commonly reject request
    /// URIs beyond a few kilobytes.
    public static let maxTerms = 100

    /// Conservative per-term token estimate.
    ///
    /// Deepgram tokenizes words into subword units, so the estimate must never
    /// undercount. We take the larger of "word count" and a character-length
    /// ratio: technical terms (`Kubernetes`, `TypeScript`, `fine-tune`) and
    /// hyphenated or CamelCase strings frequently split into several subword
    /// tokens. Digits also split aggressively (`GPT-4` -> `GPT`, `-`, `4`).
    public static func estimatedTokens(for term: String) -> Int {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let words = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        // ~5 characters per subword token is the conservative end of common BPE
        // vocabularies for Latin script; round up so we never undercount.
        // Non-Latin scripts split far more aggressively per character — kana,
        // Han and Hangul cost roughly one token each — so the previous flat
        // ~5-chars-per-token assumption undercounted them by roughly 5x. CJK is
        // reachable via the `auto` language pin, so a CJK dictionary could
        // exceed the ceiling while the estimate still looked safe. Weigh each
        // Unicode scalar (a code point, not a grapheme cluster) by script.
        var lengthTokens = 0
        for scalar in trimmed.unicodeScalars {
            lengthTokens += Self.tokenWeight(scalar)
        }
        let byLength = Int((Double(lengthTokens) / 5.0).rounded(.up))

        // Punctuation and internal separators are usually their own tokens.
        let separators = trimmed.filter { !$0.isLetter && !$0.isNumber }.count
        let base = max(words, byLength) + separators

        return max(1, base)
    }

    /// How many BPE tokens one Unicode scalar plausibly costs, in units of
    /// "average Latin characters per token" (~5 for the conservative end of
    /// common vocabularies). Dividing by 5 afterwards keeps one consistent
    /// currency.
    private static func tokenWeight(_ scalar: Unicode.Scalar) -> Int {
        let code = scalar.value
        // Han, Hiragana, Katakana, Hangul: roughly one token per character.
        if (code >= 0x3040 && code <= 0x30FF)      // kana
            || (code >= 0x3400 && code <= 0x4DBF)  // CJK ext A
            || (code >= 0x4E00 && code <= 0x9FFF)  // CJK unified
            || (code >= 0xF900 && code <= 0xFAFF)  // CJK compat
            || (code >= 0xAC00 && code <= 0xD7AF)  // Hangul syllables
            || (code >= 0x1100 && code <= 0x11FF) { // Hangul jamo
            return 5
        }
        // Cyrillic, Greek, Arabic, Hebrew, Thai, Devanagari, Myanmar etc.:
        // split more than Latin.
        if code >= 0x0370 && code <= 0x0FFF { return 3 }
        if code >= 0x0E00 && code <= 0x109F { return 3 }
        return 1
    }

    /// Total estimated cost of a keyterm list.
    public static func estimatedTokens(for terms: [String]) -> Int {
        terms.reduce(0) { $0 + estimatedTokens(for: $1) }
    }

    /// True when a list would exceed the budget we are willing to spend. Used by
    /// tests and by the settings diagnostics to catch a regression early.
    public static func exceedsBudget(_ terms: [String]) -> Bool {
        terms.count > maxTerms || estimatedTokens(for: terms) > tokenBudget
    }

    /// A single keyterm string so long that it can never be worth sending: it
    /// would consume the entire budget on its own and is almost certainly a
    /// pasted paragraph rather than a dictionary term.
    public static let maxTermLength = 64

    /// Rejects pathological entries before they reach a request: empty strings,
    /// strings that are only punctuation, control characters (which would break
    /// the query string or the API's parsing), and absurdly long values.
    public static func isSendableKeyterm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxTermLength else { return false }
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return !trimmed.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }
}
