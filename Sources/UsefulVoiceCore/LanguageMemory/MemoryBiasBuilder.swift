import Foundation

public enum MemoryBiasBuilder {
    /// Builds the Deepgram keyterm list (correct spellings only).
    ///
    /// Important: never send misheard forms / pronunciations as keyterms.
    /// Keyterms bias the model *toward* those strings in the output, so
    /// "sounds like" values would make mistakes more likely.
    public static func biasList(terms: [MemoryTerm],
                                baseVocabulary: [String],
                                budget: Int,
                                language: MemoryLanguage = .auto,
                                replacements: [ReplacementRule] = [],
                                snippets: [MemorySnippet] = []) -> [String] {
        guard budget > 0 else { return [] }

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

        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, result.count < budget else { return }
            let key = TermMatcher.canonical(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            result.append(trimmed)
        }

        // 1. Personal dictionary phrases (correct forms only).
        for term in sortedTerms {
            append(term.phrase)
            // Aliases are alternate correct spellings (e.g. "GPT-4" / "GPT4").
            // Pronunciations are misheard forms and must not become keyterms.
            for alias in term.aliases { append(alias) }
            if result.count == budget { return result }
        }

        // 2. Auto-correction targets (what we want the model to produce).
        let sortedReplacements = replacements
            .filter { $0.isEnabled && languageMatches($0.language, language) }
            .sorted { $0.usageCount > $1.usageCount }
        for rule in sortedReplacements {
            append(rule.replacement)
            if result.count == budget { return result }
        }

        // 3. Snippet triggers so spoken shortcuts survive STT.
        for snippet in snippets where snippet.isEnabled && languageMatches(snippet.language, language) {
            append(snippet.trigger)
            if result.count == budget { return result }
        }

        // 4. Shipped base vocabulary fills remaining budget.
        for word in baseVocabulary {
            append(word)
            if result.count == budget { return result }
        }

        return result
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
