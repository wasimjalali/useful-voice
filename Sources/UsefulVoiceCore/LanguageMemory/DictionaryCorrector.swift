import Foundation

/// Builds the effective local correction rules that run after transcription.
///
/// Combines:
/// 1. Explicit user auto-corrections (replacements)
/// 2. Synthetic rules from dictionary term aliases and pronunciations
///    ("sounds like X" → exact dictionary spelling)
/// 3. Case-normalization of known dictionary phrases (so "claude code"
///    becomes "Claude Code" once the term is saved)
///
/// Longest match first so multi-word phrases win over shorter fragments.
public enum DictionaryCorrector {
    public static func effectiveRules(from snapshot: LanguageMemorySnapshot,
                                      language: MemoryLanguage) -> [ReplacementRule] {
        var rules: [ReplacementRule] = []
        var seen = Set<String>()

        func append(_ rule: ReplacementRule) {
            guard rule.isEnabled else { return }
            guard languageMatches(rule.language, language) else { return }
            let match = rule.match.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !match.isEmpty, !replacement.isEmpty else { return }

            // Dedupe by match + mode so explicit rules win over synthetics
            // for the same heard phrase.
            let key = "\(rule.matchMode.rawValue)|\(TermMatcher.canonical(match))"
            guard seen.insert(key).inserted else { return }
            rules.append(ReplacementRule(
                id: rule.id,
                match: match,
                replacement: replacement,
                matchMode: rule.matchMode,
                language: rule.language,
                isEnabled: true,
                createdAt: rule.createdAt,
                updatedAt: rule.updatedAt,
                usageCount: rule.usageCount
            ))
        }

        // Explicit user rules first (they claim the seen-key).
        for rule in snapshot.replacements {
            append(rule)
        }

        // Synthetic rules from personal dictionary terms.
        for term in snapshot.terms where languageMatches(term.language, language) {
            let phrase = term.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { continue }

            for hint in term.aliases + term.pronunciations {
                let heard = hint.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip empty and identical strings. Everything else becomes a
                // local fix so "sounds like" and alternate spellings actually
                // correct the transcript after STT.
                guard !heard.isEmpty, heard != phrase else { continue }
                append(ReplacementRule(
                    match: heard,
                    replacement: phrase,
                    matchMode: .wordBoundaryPhrase,
                    language: term.language
                ))
            }

            // Case-normalize the exact dictionary phrase when STT returns
            // the right words with the wrong casing.
            append(ReplacementRule(
                match: phrase,
                replacement: phrase,
                matchMode: .caseInsensitivePhrase,
                language: term.language
            ))
        }

        // Longest match first; stable for equal length.
        return rules.sorted {
            if $0.match.count != $1.match.count { return $0.match.count > $1.match.count }
            return $0.match.localizedCaseInsensitiveCompare($1.match) == .orderedAscending
        }
    }

    private static func languageMatches(_ ruleLanguage: MemoryLanguage,
                                        _ current: MemoryLanguage) -> Bool {
        ruleLanguage == .auto || current == .auto || ruleLanguage == current
    }
}
