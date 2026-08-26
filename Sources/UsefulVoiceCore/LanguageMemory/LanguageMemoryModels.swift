import Foundation

public enum MemoryLanguage: String, Codable, CaseIterable, Sendable {
    case auto, en, de

    public init(languagePin: LanguagePin) {
        switch languagePin {
        case .auto: self = .auto
        case .en: self = .en
        case .de: self = .de
        }
    }
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
