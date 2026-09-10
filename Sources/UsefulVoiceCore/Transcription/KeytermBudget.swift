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
        let byLength = Int((Double(trimmed.count) / 5.0).rounded(.up))

        // Punctuation and internal separators are usually their own tokens.
        let separators = trimmed.filter { !$0.isLetter && !$0.isNumber }.count
        let base = max(words, byLength) + separators

        return max(1, base)
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
