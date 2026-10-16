import Foundation
@testable import UsefulVoiceCore

/// The Language Memory matcher exactly as it was before the index (main at bb754d9):
/// every rule runs its regex over the whole text, every term candidate likewise.
///
/// Kept verbatim as the oracle for the differential tests, and as the "before" side of
/// the benchmark. Only the names changed, plus its own regex cache (see
/// `wordBoundaryRegex(for:)`). Do not "improve" this file: its value is that it is the
/// old behaviour.
enum LegacyLanguageMemory {
    /// The old `wordBoundaryRegex(for:)`, with its own cache keyed on the phrase's bytes.
    /// (The production cache used to be keyed on the `String`, which treats NFC and NFD
    /// spellings of a phrase as one key; see `LanguageMemoryMatcher.cache`. The oracle must
    /// not depend on which spelling reached the cache first, so it compiles by bytes.)
    private final class RegexCache: @unchecked Sendable {
        let lock = NSLock()
        var regexes: [[UInt8]: NSRegularExpression] = [:]
    }
    private static let regexCache = RegexCache()

    static func wordBoundaryRegex(for phrase: String) -> NSRegularExpression? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= LanguageMemoryMatcher.maxPhraseLength else { return nil }
        let key = Array(trimmed.utf8)
        regexCache.lock.lock()
        defer { regexCache.lock.unlock() }
        if let cached = regexCache.regexes[key] { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        let pattern = #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        regexCache.regexes[key] = regex
        return regex
    }

    static func containsWordBoundaryPhrase(_ phrase: String, in text: String) -> Bool {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let regex = wordBoundaryRegex(for: phrase) else { return false }
        return regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }

    static func matchingTermIDs(_ terms: [MemoryTerm],
                                in text: String,
                                language: MemoryLanguage = .auto) -> [UUID] {
        let filtered = terms.filter { term in
            term.language == .auto || language == .auto || term.language == language
        }
        var result: [UUID] = []

        for term in filtered {
            let candidates = [term.phrase] + term.aliases + term.pronunciations
            guard candidates.contains(where: { containsWordBoundaryPhrase($0, in: text) }) else {
                continue
            }
            if !result.contains(term.id) {
                result.append(term.id)
            }
        }

        return result
    }

    static func applyRules(_ rules: [ReplacementRule],
                           to text: String,
                           language: MemoryLanguage) -> ReplacementResult {
        var output = text
        var applied: [UUID] = []

        for rule in rules where rule.isEnabled && languageMatches(rule.language, language) {
            let match = rule.match.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !match.isEmpty else { continue }

            let before = output
            switch rule.matchMode {
            case .exactPhrase:
                output = output.replacingOccurrences(of: match, with: rule.replacement)
            case .caseInsensitivePhrase:
                output = output.replacingOccurrences(
                    of: match,
                    with: rule.replacement,
                    options: [.caseInsensitive]
                )
            case .wordBoundaryPhrase:
                guard let regex = wordBoundaryRegex(for: match) else { continue }
                let range = NSRange(output.startIndex..<output.endIndex, in: output)
                output = regex.stringByReplacingMatches(
                    in: output,
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement)
                )
            }

            if output != before {
                applied.append(rule.id)
            }
        }

        return ReplacementResult(text: output, appliedRuleIDs: applied)
    }

    static func applySnippets(_ snippets: [MemorySnippet],
                              to text: String,
                              language: MemoryLanguage) -> SnippetExpansionResult {
        var output = text
        var applied: [UUID] = []

        for snippet in snippets where snippet.isEnabled && languageMatches(snippet.language, language) {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let expansion = snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !expansion.isEmpty else { continue }

            let before = output
            guard let regex = wordBoundaryRegex(for: trigger) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: expansion)
            )
            if output != before {
                applied.append(snippet.id)
            }
        }

        return SnippetExpansionResult(text: output, appliedSnippetIDs: applied)
    }

    static func applyDeterministic(to text: String,
                                   snapshot: LanguageMemorySnapshot,
                                   language: MemoryLanguage) -> LanguageMemoryProcessingResult {
        let rules = DictionaryCorrector.effectiveRules(from: snapshot, language: language)
        let firstReplacement = applyRules(rules, to: text, language: language)
        let snippet = applySnippets(snapshot.snippets, to: firstReplacement.text, language: language)
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
            finalReplacement = applyRules(remainingRules, to: snippet.text, language: language)
        }
        var seenTexts = Set<[UInt8]>()
        let distinctTexts = [text, firstReplacement.text, snippet.text, finalReplacement.text]
            .filter { seenTexts.insert(Array($0.utf8)).inserted }
        let memoryHitIDs = mergedIDs(distinctTexts.map {
            matchingTermIDs(snapshot.terms, in: $0, language: language)
        })

        return LanguageMemoryProcessingResult(
            text: finalReplacement.text,
            replacementRuleIDs: mergedIDs([
                firstReplacement.appliedRuleIDs,
                finalReplacement.appliedRuleIDs,
            ]),
            memoryHitIDs: memoryHitIDs,
            snippetIDs: mergedIDs([snippet.appliedSnippetIDs])
        )
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

    private static func languageMatches(_ a: MemoryLanguage, _ b: MemoryLanguage) -> Bool {
        a == .auto || b == .auto || a == b
    }
}
