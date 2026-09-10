import Foundation

public enum MemoryBiasBuilder {
    /// Builds the Deepgram keyterm list (correct spellings only).
    ///
    /// Important: never send misheard forms / pronunciations as keyterms.
    /// Keyterms bias the model *toward* those strings in the output, so
    /// "sounds like" values would make mistakes more likely.
    /// - Parameter budget: maximum number of keyterm strings to return.
    @discardableResult
    public static func biasList(terms: [MemoryTerm],
                                baseVocabulary: [String],
                                budget: Int,
                                language: MemoryLanguage = .auto,
                                replacements: [ReplacementRule] = [],
                                snippets: [MemorySnippet] = []) -> [String] {
        biasSelection(terms: terms,
                      baseVocabulary: baseVocabulary,
                      budget: budget,
                      language: language,
                      replacements: replacements,
                      snippets: snippets).terms
    }

    /// Same ranking and de-duplication rules as `biasList`, but also enforces
    /// Deepgram's per-request keyterm token ceiling and reports what was dropped.
    ///
    /// Exceeding the API limit is a hard request failure, which would break
    /// dictation entirely for anyone with a large dictionary, so the selection
    /// must be bounded *before* the request is built rather than truncated by
    /// the server.
    public static func boundedSelection(terms: [MemoryTerm],
                                        baseVocabulary: [String],
                                        budget: Int,
                                        language: MemoryLanguage = .auto,
                                        replacements: [ReplacementRule] = [],
                                        snippets: [MemorySnippet] = [])
        -> KeytermSelection {
        biasSelection(terms: terms,
                      baseVocabulary: baseVocabulary,
                      budget: budget,
                      language: language,
                      replacements: replacements,
                      snippets: snippets)
    }

    private static func biasSelection(terms: [MemoryTerm],
                                      baseVocabulary: [String],
                                      budget: Int,
                                      language: MemoryLanguage,
                                      replacements: [ReplacementRule],
                                      snippets: [MemorySnippet]) -> KeytermSelection {
        guard budget > 0 else { return KeytermSelection(terms: []) }

        let sortedTerms = terms
            .filter { term in
                term.language == .auto || language == .auto || term.language == language
            }
            .sorted { lhs, rhs in
                let leftRank = priorityRank(lhs.priority)
                let rightRank = priorityRank(rhs.priority)
                if leftRank != rightRank { return leftRank < rightRank }
                if lhs.usageCount != rhs.usageCount { return lhs.usageCount > rhs.usageCount }
                return lhs.updatedAt > rhs.updatedAt
            }

        var seen = Set<String>()
        var result: [String] = []
        var spentTokens = 0
        var dropped = 0
        var rejected = 0
        var duplicates = 0

        // A term is admitted only when it fits BOTH the count budget and the
        // Deepgram token budget. A term that does not fit is dropped, never
        // truncated: a half-term keyterm would bias the model toward a wrong
        // string.
        //
        // Every kind of rejection is counted, including unusable input and
        // duplicates. A silent `return` here under-reported what was left out,
        // so the UI could not tell a user that their dictionary no longer fits.
        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard KeytermBudget.isSendableKeyterm(trimmed) else {
                rejected += 1
                return
            }
            let key = TermMatcher.canonical(trimmed)
            guard !key.isEmpty else {
                rejected += 1
                return
            }
            guard !seen.contains(key) else {
                duplicates += 1
                return
            }
            guard result.count < budget else {
                dropped += 1
                return
            }

            let cost = KeytermBudget.estimatedTokens(for: trimmed)
            guard spentTokens + cost <= KeytermBudget.tokenBudget else {
                dropped += 1
                return
            }

            seen.insert(key)
            result.append(trimmed)
            spentTokens += cost
        }

        // 1. Personal dictionary phrases (correct forms only).
        for term in sortedTerms {
            append(term.phrase)
            // Aliases are alternate correct spellings (e.g. "GPT-4" / "GPT4").
            // Pronunciations are misheard forms and must not become keyterms.
            for alias in term.aliases { append(alias) }
        }

        // 2. Auto-correction targets (what we want the model to produce).
        let sortedReplacements = replacements
            .filter { $0.isEnabled && languageMatches($0.language, language) }
            .sorted { $0.usageCount > $1.usageCount }
        for rule in sortedReplacements {
            append(rule.replacement)
        }

        // 3. Snippet triggers so spoken shortcuts survive STT.
        for snippet in snippets where snippet.isEnabled && languageMatches(snippet.language, language) {
            append(snippet.trigger)
        }

        // 4. Shipped base vocabulary fills remaining budget.
        for word in baseVocabulary {
            append(word)
        }

        return KeytermSelection(terms: result,
                                estimatedTokens: spentTokens,
                                droppedCount: dropped,
                                limit: KeytermBudget.tokenBudget,
                                rejectedCount: rejected,
                                duplicateCount: duplicates)
    }

    private static func priorityRank(_ priority: MemoryPriority) -> Int {
        switch priority {
        case .always: return 0
        case .high: return 1
        case .normal: return 2
        }
    }

    private static func languageMatches(_ ruleLanguage: MemoryLanguage,
                                        _ current: MemoryLanguage) -> Bool {
        ruleLanguage == .auto || current == .auto || ruleLanguage == current
    }
}

/// The keyterms chosen for one transcription request, plus what had to be left
/// out. `droppedCount` exists so the UI can tell the user their dictionary has
/// outgrown the provider's limit instead of silently ignoring entries.
public struct KeytermSelection: Equatable, Sendable {
    public let terms: [String]
    public let estimatedTokens: Int
    /// Entries that were valid but did not fit the count or token budget.
    public let droppedCount: Int
    public let limit: Int
    /// Entries Deepgram cannot use as keyterms at all (too long, no
    /// alphanumerics, control characters).
    public let rejectedCount: Int
    /// Entries skipped because an equivalent term was already selected.
    public let duplicateCount: Int

    public init(terms: [String],
                estimatedTokens: Int = 0,
                droppedCount: Int = 0,
                limit: Int = 0,
                rejectedCount: Int = 0,
                duplicateCount: Int = 0) {
        self.terms = terms
        self.estimatedTokens = estimatedTokens
        self.droppedCount = droppedCount
        self.limit = limit
        self.rejectedCount = rejectedCount
        self.duplicateCount = duplicateCount
    }

    /// True when the dictionary could not be fully applied. Only capacity is a
    /// problem the user can act on, so rejects and duplicates do not count.
    public var isOverCapacity: Bool { droppedCount > 0 }

    /// Everything that did not make it into the request, for the Settings
    /// diagnostic that explains why a term is not being sent.
    public var omittedCount: Int { droppedCount + rejectedCount }
}
