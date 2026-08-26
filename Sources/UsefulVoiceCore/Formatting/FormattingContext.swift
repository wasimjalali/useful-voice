import Foundation

/// Everything the formatter needs about one dictation besides the raw text.
public struct FormattingContext: Sendable {
    public let appBundleID: String?
    public let dictionaryWords: [String]
    public let language: LanguagePin
    public let snippets: [Snippet]
    public let replacementRules: [ReplacementRule]

    public init(appBundleID: String?,
                dictionaryWords: [String],
                language: LanguagePin,
                snippets: [Snippet] = [],
                replacementRules: [ReplacementRule] = []) {
        self.appBundleID = appBundleID
        self.dictionaryWords = dictionaryWords
        self.language = language
        self.snippets = snippets
        self.replacementRules = replacementRules
    }
}

/// How a dictation's text was produced. Recorded per dictation so History can
/// show whether the text was cleaned up (formatted) or left raw.
public enum FormattingMode: String, Equatable, Sendable {
    case raw        // pure transcription: raw toggle, formatter off, or fallback
    case formatted  // smart formatting cleaned it up
}

extension FormattingMode: Codable {
    /// Lenient decode so older history.json still loads: the removed "prompt"
    /// mode (Prompt Mode, deleted) and any unknown value map to .raw instead of
    /// failing the whole history load.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FormattingMode(rawValue: raw) ?? .raw
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What the formatter returns: polished text plus up to a few newly guessed terms.
public struct FormattingResult: Equatable, Sendable {
    public let text: String
    public let newTerms: [String]
    /// How this text was produced; the pipeline copies it onto the record.
    public let mode: FormattingMode
    /// Deterministic Language Memory replacements applied around formatting.
    public let replacementRuleIDs: [UUID]
    /// Language Memory terms found in the raw/intermediate/final text.
    public let memoryHitIDs: [UUID]
    /// Spoken snippets deterministically expanded around formatting.
    public let snippetIDs: [UUID]

    public init(text: String, newTerms: [String],
                mode: FormattingMode = .formatted,
                replacementRuleIDs: [UUID] = [],
                memoryHitIDs: [UUID] = [],
                snippetIDs: [UUID] = []) {
        self.text = text
        self.newTerms = newTerms
        self.mode = mode
        self.replacementRuleIDs = replacementRuleIDs
        self.memoryHitIDs = memoryHitIDs
        self.snippetIDs = snippetIDs
    }
}
