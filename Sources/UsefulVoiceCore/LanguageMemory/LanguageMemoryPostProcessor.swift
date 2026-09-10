import Foundation

public struct LanguageMemoryProcessingResult: Equatable, Sendable {
    public let text: String
    public let replacementRuleIDs: [UUID]
    public let memoryHitIDs: [UUID]
    public let snippetIDs: [UUID]

    public init(text: String,
                replacementRuleIDs: [UUID],
                memoryHitIDs: [UUID],
                snippetIDs: [UUID]) {
        self.text = text
        self.replacementRuleIDs = replacementRuleIDs
        self.memoryHitIDs = memoryHitIDs
        self.snippetIDs = snippetIDs
    }
}

public enum LanguageMemoryPostProcessor {
    public static func applyDeterministic(to text: String,
                                          snapshot: LanguageMemorySnapshot,
                                          language: MemoryLanguage) -> LanguageMemoryProcessingResult {
        // Effective rules include explicit auto-corrections plus synthetic
        // fixes derived from dictionary aliases, pronunciations and casing.
        let rules = DictionaryCorrector.effectiveRules(from: snapshot, language: language)
        let firstReplacement = ReplacementEngine.apply(
            rules,
            to: text,
            language: language
        )
        let snippet = SnippetExpansionEngine.apply(
            snapshot.snippets,
            to: firstReplacement.text,
            language: language
        )
        // Second pass catches text introduced by snippet expansions. Rules that
        // already fired are skipped: re-running them is not idempotent when a
        // rule's replacement still contains its own match, and the result was
        // visible corruption — alias "Karko" -> phrase "Karko AI" turned "Karko"
        // into "Karko AI AI", and "Useful" -> "Useful Voice" became "Useful Voice
        // Voice". A rule matches a literal phrase, so re-applying it to text it
        // already produced can only duplicate.
        let appliedInFirstPass = Set(firstReplacement.appliedRuleIDs)
        let remainingRules = rules.filter { !appliedInFirstPass.contains($0.id) }
        let finalReplacement = ReplacementEngine.apply(
            remainingRules,
            to: snippet.text,
            language: language
        )
        let memoryHitIDs = matchingTermIDs(
            terms: snapshot.terms,
            language: language,
            texts: [text, firstReplacement.text, snippet.text, finalReplacement.text]
        )

        return LanguageMemoryProcessingResult(
            text: finalReplacement.text,
            replacementRuleIDs: mergedIDs(
                firstReplacement.appliedRuleIDs,
                finalReplacement.appliedRuleIDs
            ),
            memoryHitIDs: memoryHitIDs,
            snippetIDs: mergedIDs(snippet.appliedSnippetIDs)
        )
    }

    public static func rawResult(for text: String,
                                 snapshot: LanguageMemorySnapshot,
                                 language: MemoryLanguage) -> FormattingResult {
        rawResult(from: applyDeterministic(
            to: text,
            snapshot: snapshot,
            language: language
        ))
    }

    public static func rawResult(from processed: LanguageMemoryProcessingResult) -> FormattingResult {
        FormattingResult(
            text: processed.text,
            newTerms: [],
            mode: .raw,
            replacementRuleIDs: processed.replacementRuleIDs,
            memoryHitIDs: processed.memoryHitIDs,
            snippetIDs: processed.snippetIDs
        )
    }

    public static func formattedResult(prepared: LanguageMemoryProcessingResult,
                                       formatted: FormattingResult,
                                       snapshot: LanguageMemorySnapshot,
                                       language: MemoryLanguage) -> FormattingResult {
        let final = applyDeterministic(
            to: formatted.text,
            snapshot: snapshot,
            language: language
        )

        return FormattingResult(
            text: final.text,
            newTerms: formatted.newTerms,
            mode: formatted.mode,
            replacementRuleIDs: mergedIDs(
                prepared.replacementRuleIDs,
                final.replacementRuleIDs
            ),
            memoryHitIDs: mergedIDs(
                prepared.memoryHitIDs,
                final.memoryHitIDs
            ),
            snippetIDs: mergedIDs(
                prepared.snippetIDs,
                final.snippetIDs
            )
        )
    }

    private static func matchingTermIDs(terms: [MemoryTerm],
                                        language: MemoryLanguage,
                                        texts: [String]) -> [UUID] {
        mergedIDs(texts.map {
            LanguageMemoryMatcher.matchingTermIDs(terms, in: $0, language: language)
        })
    }

    private static func mergedIDs(_ groups: [UUID]...) -> [UUID] {
        mergedIDs(groups)
    }

    private static func mergedIDs(_ groups: [[UUID]]) -> [UUID] {
        groups.reduce(into: [UUID]()) { result, ids in
            for id in ids where !result.contains(id) {
                result.append(id)
            }
        }
    }
}
