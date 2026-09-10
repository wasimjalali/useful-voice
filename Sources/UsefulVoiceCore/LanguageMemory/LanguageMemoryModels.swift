import Foundation

/// The language a dictionary term or replacement is scoped to.
///
/// This is **persisted** in `language-memory.json`, so it is deliberately more
/// permissive than `LanguagePin`: an unknown code decodes to a usable value
/// instead of throwing and taking the whole store down with it. A store that
/// fails to decode is refused for writing (see `StoreLoadOutcome`), so throwing
/// here would turn one unrecognised language into an unwritable dictionary.
public struct MemoryLanguage: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public static let auto = MemoryLanguage(rawValue: "auto")
    public static let en = MemoryLanguage(rawValue: "en")
    public static let de = MemoryLanguage(rawValue: "de")

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(languagePin: LanguagePin) {
        self = MemoryLanguage(rawValue: languagePin.rawValue)
    }

    /// A language for an imported value, falling back to auto when unknown.
    ///
    /// The fallback is not cosmetic. A term scoped to a language the model cannot
    /// transcribe would be sent to the provider and either error or trigger the
    /// documented fallback to a lower model — which does not support `keyterm`, so
    /// the dictionary stops working. Auto keeps such a term usable instead.
    public static func validated(_ raw: String) -> MemoryLanguage {
        MemoryLanguage(languagePin: LanguagePin(code: raw))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: (try? container.decode(String.self)) ?? "auto")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Every language a term can be scoped to: auto first, then the catalogue.
    public static var allCases: [MemoryLanguage] {
        LanguagePin.allCases.map(MemoryLanguage.init(languagePin:))
    }

    /// The pin this language corresponds to.
    public var pin: LanguagePin { LanguagePin(code: rawValue) }

    public var displayName: String { pin.displayName }
}

public enum MemoryPriority: String, Codable, CaseIterable, Sendable {
    case normal, high, always
}

public enum ReplacementMatchMode: String, Codable, CaseIterable, Sendable {
    case exactPhrase, caseInsensitivePhrase, wordBoundaryPhrase
}

public enum MemorySuggestionKind: String, Codable, CaseIterable, Sendable {
    case term, replacement, snippetCandidate
}

public enum MemorySuggestionSource: String, Codable, CaseIterable, Sendable {
    case formatter, historyCorrection, manualImport, reprocess
}

public struct MemoryTerm: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var phrase: String
    public var pronunciations: [String]
    public var aliases: [String]
    public var language: MemoryLanguage
    public var priority: MemoryPriority
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date
    public var usageCount: Int

    public init(id: UUID = UUID(),
                phrase: String,
                pronunciations: [String] = [],
                aliases: [String] = [],
                language: MemoryLanguage = .auto,
                priority: MemoryPriority = .normal,
                notes: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                usageCount: Int = 0) {
        self.id = id
        self.phrase = phrase
        self.pronunciations = pronunciations
        self.aliases = aliases
        self.language = language
        self.priority = priority
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usageCount = usageCount
    }
}

public struct ReplacementRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var match: String
    public var replacement: String
    public var matchMode: ReplacementMatchMode
    public var language: MemoryLanguage
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var usageCount: Int

    public init(id: UUID = UUID(),
                match: String,
                replacement: String,
                matchMode: ReplacementMatchMode = .wordBoundaryPhrase,
                language: MemoryLanguage = .auto,
                isEnabled: Bool = true,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                usageCount: Int = 0) {
        self.id = id
        self.match = match
        self.replacement = replacement
        self.matchMode = matchMode
        self.language = language
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usageCount = usageCount
    }
}

public struct MemorySnippet: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var trigger: String
    public var expansion: String
    public var language: MemoryLanguage
    public var tags: [String]
    public var isEnabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var usageCount: Int

    public init(id: UUID = UUID(),
                trigger: String,
                expansion: String,
                language: MemoryLanguage = .auto,
                tags: [String] = [],
                isEnabled: Bool = true,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                usageCount: Int = 0) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
        self.language = language
        self.tags = tags
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usageCount = usageCount
    }
}

public struct MemorySuggestion: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: MemorySuggestionKind
    public var observed: String
    public var proposed: String
    public var evidenceCount: Int
    public var lastSeenAt: Date
    public var source: MemorySuggestionSource

    public init(id: UUID = UUID(),
                kind: MemorySuggestionKind,
                observed: String,
                proposed: String,
                evidenceCount: Int = 1,
                lastSeenAt: Date = Date(),
                source: MemorySuggestionSource = .formatter) {
        self.id = id
        self.kind = kind
        self.observed = observed
        self.proposed = proposed
        self.evidenceCount = evidenceCount
        self.lastSeenAt = lastSeenAt
        self.source = source
    }
}

public struct LanguageMemorySnapshot: Codable, Equatable, Sendable {
    public var terms: [MemoryTerm]
    public var replacements: [ReplacementRule]
    public var snippets: [MemorySnippet]
    public var suggestions: [MemorySuggestion]

    public init(terms: [MemoryTerm] = [],
                replacements: [ReplacementRule] = [],
                snippets: [MemorySnippet] = [],
                suggestions: [MemorySuggestion] = []) {
        self.terms = terms
        self.replacements = replacements
        self.snippets = snippets
        self.suggestions = suggestions
    }
}

public struct LanguageMemoryImportResult: Equatable, Sendable {
    public let inserted: Int
    public let updated: Int
    public let duplicates: Int
    public let invalid: [String]

    public init(inserted: Int, updated: Int, duplicates: Int, invalid: [String]) {
        self.inserted = inserted
        self.updated = updated
        self.duplicates = duplicates
        self.invalid = invalid
    }
}

struct LanguageMemoryPersisted: Codable {
    static let currentVersion = 1

    var version: Int
    var snapshot: LanguageMemorySnapshot
}
