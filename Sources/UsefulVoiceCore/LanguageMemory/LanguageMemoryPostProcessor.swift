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
        // Second pass catches text introduced by snippet expansions — and a
        // match a LATER rule creates for an EARLIER one: rules apply
        // sequentially over the evolving text, so when "the cat -> a cat" has
        // already missed before "teh -> the" produces "the cat", only a second
        // pass resolves it. Rules that already fired are skipped: re-running
        // them is not idempotent when a rule's replacement still contains its
        // own match, and the result was visible corruption — alias "Karko" ->
        // phrase "Karko AI" turned "Karko" into "Karko AI AI", and "Useful" ->
        // "Useful Voice" became "Useful Voice Voice".
        //
        // Pass two is skipped only when it is a guaranteed deterministic
        // replay of pass one — pass one fired NO rules (so `remainingRules`
        // would be all of `rules` again) AND the text it would see is
        // byte-identical to what pass one saw. Fired-but-net-zero output does
        // NOT qualify: a cycle like "the cat sat here" -> "a dog sat" ->
        // "the cat sat here" leaves the input text restored, but a rule that
        // was evaluated against the intermediate text state can match the
        // restored text in pass two. Byte-level comparison matters too —
        // canonical `==` folds NFC/NFD while the ICU matchers do not.
        let finalReplacement: ReplacementResult
        let passTwoIsDeterministicReplay =
            firstReplacement.appliedRuleIDs.isEmpty
            && snippet.text.utf8.elementsEqual(firstReplacement.text.utf8)
            && firstReplacement.text.utf8.elementsEqual(text.utf8)
        if passTwoIsDeterministicReplay {
            finalReplacement = ReplacementResult(text: snippet.text, appliedRuleIDs: [])
        } else {
            let appliedInFirstPass = Set(firstReplacement.appliedRuleIDs)
            let remainingRules = rules.filter { !appliedInFirstPass.contains($0.id) }
            finalReplacement = ReplacementEngine.apply(
                remainingRules,
                to: snippet.text,
                language: language
            )
        }
        // Pass one, snippet expansion and pass two often leave the text
        // untouched, so the four variants are frequently the same string.
        // Matching terms once per distinct text — not once per stage — keeps
        // the result identical without re-scanning identical inputs. Dedupe is
        // keyed on UTF-8 bytes, not `==`: canonical equality folds NFC/NFD
        // forms that the ICU word-boundary matchers treat as different text.
        var seenTexts = Set<[UInt8]>()
        let distinctTexts = [text, firstReplacement.text, snippet.text, finalReplacement.text]
            .filter { seenTexts.insert(Array($0.utf8)).inserted }
        let memoryHitIDs = matchingTermIDs(
            terms: snapshot.terms,
            language: language,
            texts: distinctTexts
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
        var seen = Set<UUID>()
        var result: [UUID] = []
        for ids in groups {
            for id in ids where seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }
}
