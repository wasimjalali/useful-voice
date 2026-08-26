import Foundation

/// Local-first store for personal terms, deterministic replacements, snippets,
/// and suggestions. Used from the main actor by the app layer.
public final class LanguageMemoryStore {
    private let fileURL: URL
    private var state: LanguageMemorySnapshot

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else {
            state = LanguageMemorySnapshot()
            return
        }

        if let persisted = try? Self.decoder.decode(LanguageMemoryPersisted.self, from: data) {
            state = persisted.snapshot
        } else if let snapshot = try? Self.decoder.decode(LanguageMemorySnapshot.self, from: data) {
            state = snapshot
        } else {
            Self.backUpCorruptFile(fileURL)
            state = LanguageMemorySnapshot()
        }
    }

    public func snapshot() -> LanguageMemorySnapshot { state }
    public func terms() -> [MemoryTerm] { state.terms }
    public func replacements() -> [ReplacementRule] { state.replacements }
    public func snippets() -> [MemorySnippet] { state.snippets }
    public func suggestions() -> [MemorySuggestion] { state.suggestions }

    public func recordUsage(termIDs: [UUID] = [],
                            replacementRuleIDs: [UUID] = [],
                            snippetIDs: [UUID] = [],
                            at date: Date = Date()) {
        let termIDs = Set(termIDs)
        let replacementRuleIDs = Set(replacementRuleIDs)
        let snippetIDs = Set(snippetIDs)
        guard !termIDs.isEmpty || !replacementRuleIDs.isEmpty || !snippetIDs.isEmpty else { return }

        var changed = false
        for index in state.terms.indices where termIDs.contains(state.terms[index].id) {
            state.terms[index].usageCount += 1
            state.terms[index].updatedAt = date
            changed = true
        }
        for index in state.replacements.indices where replacementRuleIDs.contains(state.replacements[index].id) {
            state.replacements[index].usageCount += 1
            state.replacements[index].updatedAt = date
            changed = true
        }
        for index in state.snippets.indices where snippetIDs.contains(state.snippets[index].id) {
            state.snippets[index].usageCount += 1
            state.snippets[index].updatedAt = date
            changed = true
        }
        if changed { save() }
    }

    @discardableResult
    public func upsertTerm(_ term: MemoryTerm) -> MemoryTerm {
        let normalized = normalizedTerm(term)
        guard !TermMatcher.canonical(normalized.phrase).isEmpty else { return normalized }

        if let index = state.terms.firstIndex(where: {
            $0.id == normalized.id || TermMatcher.matches($0.phrase, normalized.phrase)
        }) {
            let existing = state.terms[index]
            // Keep a stable ID so usage tracking and history links still match.
            let keepID = existing.id == normalized.id || TermMatcher.matches(existing.phrase, normalized.phrase)
                ? existing.id
                : normalized.id
            let merged = MemoryTerm(
                id: keepID,
                phrase: normalized.phrase,
                pronunciations: trimmedUnique(existing.pronunciations + normalized.pronunciations),
                aliases: trimmedUnique(existing.aliases + normalized.aliases),
                language: normalized.language,
                priority: strongerPriority(existing.priority, normalized.priority),
                notes: normalized.notes.isEmpty ? existing.notes : normalized.notes,
                createdAt: existing.createdAt,
                updatedAt: normalized.updatedAt,
                usageCount: max(existing.usageCount, normalized.usageCount)
            )
            state.terms[index] = merged
            removeSuggestions(matching: merged.phrase)
            save()
            return merged
        } else {
            state.terms.insert(normalized, at: 0)
            removeSuggestions(matching: normalized.phrase)
            save()
            return normalized
        }
    }

    /// Learn from an observed → corrected edit (Library teaching + word-level
    /// auto-learn). Creates deterministic auto-corrections and high-priority
    /// dictionary terms so the same mistake is fixed next time.
    @discardableResult
    public func learnFromEdit(original: String,
                              corrected: String,
                              language: MemoryLanguage = .auto,
                              now: Date = Date()) -> LanguageMemoryLearnResult {
        let existing = state.terms.map(\.phrase)
            + state.replacements.map(\.replacement)
        let result = LanguageMemoryLearningPolicy.entries(
            observed: original,
            corrected: corrected,
            language: language,
            existingDictionary: existing,
            now: now
        )
        for entry in result.entries {
            switch entry {
            case .term(let term):
                _ = upsertTerm(term)
            case .replacement(let rule):
                _ = upsertReplacement(rule)
            }
        }
        return result
    }

    @discardableResult
    public func upsertReplacement(_ rule: ReplacementRule) -> ReplacementRule {
        let normalized = normalizedReplacement(rule)
        guard !TermMatcher.canonical(normalized.match).isEmpty,
              !normalized.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return normalized }

        if let index = state.replacements.firstIndex(where: {
            $0.id == normalized.id || TermMatcher.matches($0.match, normalized.match)
        }) {
            state.replacements[index] = normalized
        } else {
            state.replacements.insert(normalized, at: 0)
        }
        removeSuggestions(matching: normalized.match)
        save()
        return normalized
    }

    @discardableResult
    public func upsertSnippet(_ snippet: MemorySnippet) -> MemorySnippet {
        let normalized = normalizedSnippet(snippet)
        guard !TermMatcher.canonical(normalized.trigger).isEmpty,
              !normalized.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return normalized }

        if let index = state.snippets.firstIndex(where: {
            $0.id == normalized.id || TermMatcher.matches($0.trigger, normalized.trigger)
        }) {
            state.snippets[index] = normalized
        } else {
            state.snippets.insert(normalized, at: 0)
        }
        removeSuggestions(matching: normalized.trigger)
        save()
        return normalized
    }

    public func removeTerm(id: UUID) {
        state.terms.removeAll { $0.id == id }
        save()
    }

    public func removeReplacement(id: UUID) {
        state.replacements.removeAll { $0.id == id }
        save()
    }

    public func removeSnippet(id: UUID) {
        state.snippets.removeAll { $0.id == id }
        save()
    }

    public func acceptSuggestion(id: UUID, as kind: MemorySuggestionKind) {
        guard let suggestion = state.suggestions.first(where: { $0.id == id }) else { return }
        switch kind {
        case .term:
            upsertTerm(MemoryTerm(phrase: suggestion.proposed, priority: .high,
                                  updatedAt: suggestion.lastSeenAt))
        case .replacement:
            upsertReplacement(ReplacementRule(match: suggestion.observed,
                                              replacement: suggestion.proposed,
                                              matchMode: .wordBoundaryPhrase,
                                              updatedAt: suggestion.lastSeenAt))
        case .snippetCandidate:
            upsertSnippet(MemorySnippet(trigger: suggestion.observed,
                                        expansion: suggestion.proposed,
                                        updatedAt: suggestion.lastSeenAt))
        }
        dismissSuggestion(id: id)
    }

    public func dismissSuggestion(id: UUID) {
        state.suggestions.removeAll { $0.id == id }
        save()
    }

    public func suggest(_ observedTerms: [String],
                        source: MemorySuggestionSource = .formatter,
                        now: Date = Date()) {
        let incoming = MemorySuggestionEngine.termSuggestions(
            from: observedTerms,
            snapshot: state,
            source: source,
            now: now
        )

        for suggestion in incoming {
            if let index = state.suggestions.firstIndex(where: {
                TermMatcher.matches($0.observed, suggestion.observed) && $0.kind == suggestion.kind
            }) {
                state.suggestions[index].evidenceCount += suggestion.evidenceCount
                state.suggestions[index].lastSeenAt = now
            } else {
                state.suggestions.append(suggestion)
            }
        }
        state.suggestions.sort {
            if $0.evidenceCount != $1.evidenceCount { return $0.evidenceCount > $1.evidenceCount }
            return $0.lastSeenAt > $1.lastSeenAt
        }
        if state.suggestions.count > 20 {
            state.suggestions = Array(state.suggestions.prefix(20))
        }
        save()
    }

    public func importSnapshot(_ snapshot: LanguageMemorySnapshot) -> LanguageMemoryImportResult {
        var inserted = 0
        var updated = 0
        var duplicates = 0
        var invalid: [String] = []

        for term in snapshot.terms {
            guard !TermMatcher.canonical(term.phrase).isEmpty else {
                invalid.append(term.phrase)
                continue
            }
            let existed = state.terms.contains { TermMatcher.matches($0.phrase, term.phrase) }
            _ = upsertTerm(term)
            if existed { updated += 1 } else { inserted += 1 }
        }

        for rule in snapshot.replacements {
            guard !TermMatcher.canonical(rule.match).isEmpty,
                  !rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                invalid.append(rule.match)
                continue
            }
            let existed = state.replacements.contains { TermMatcher.matches($0.match, rule.match) }
            _ = upsertReplacement(rule)
            if existed { updated += 1 } else { inserted += 1 }
        }

        for snippet in snapshot.snippets {
            guard !TermMatcher.canonical(snippet.trigger).isEmpty,
                  !snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                invalid.append(snippet.trigger)
                continue
            }
            let existed = state.snippets.contains { TermMatcher.matches($0.trigger, snippet.trigger) }
            _ = upsertSnippet(snippet)
            if existed { updated += 1 } else { inserted += 1 }
        }

        for suggestion in snapshot.suggestions {
            guard !TermMatcher.canonical(suggestion.observed).isEmpty else {
                invalid.append(suggestion.observed)
                continue
            }
            if state.suggestions.contains(where: { TermMatcher.matches($0.observed, suggestion.observed) }) {
                duplicates += 1
            } else {
                state.suggestions.append(suggestion)
                inserted += 1
            }
        }

        save()
        return LanguageMemoryImportResult(
            inserted: inserted,
            updated: updated,
            duplicates: duplicates,
            invalid: invalid
        )
    }

    public func exportSnapshot() -> LanguageMemorySnapshot { state }

    private func normalizedTerm(_ term: MemoryTerm) -> MemoryTerm {
        var copy = term
        copy.phrase = copy.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.pronunciations = trimmedUnique(copy.pronunciations)
        copy.aliases = trimmedUnique(copy.aliases)
        return copy
    }

    private func normalizedReplacement(_ rule: ReplacementRule) -> ReplacementRule {
        var copy = rule
        copy.match = copy.match.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.replacement = copy.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    private func normalizedSnippet(_ snippet: MemorySnippet) -> MemorySnippet {
        var copy = snippet
        copy.trigger = copy.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.expansion = copy.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.tags = trimmedUnique(copy.tags)
        return copy
    }

    private func trimmedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TermMatcher.canonical(trimmed)
            guard !trimmed.isEmpty, seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    private func removeSuggestions(matching phrase: String) {
        state.suggestions.removeAll {
            TermMatcher.matches($0.observed, phrase) || TermMatcher.matches($0.proposed, phrase)
        }
    }

    private func strongerPriority(_ a: MemoryPriority, _ b: MemoryPriority) -> MemoryPriority {
        let rank: (MemoryPriority) -> Int = {
            switch $0 {
            case .always: return 0
            case .high: return 1
            case .normal: return 2
            }
        }
        return rank(a) <= rank(b) ? a : b
    }

    private func save() {
        let persisted = LanguageMemoryPersisted(
            version: LanguageMemoryPersisted.currentVersion,
            snapshot: state
        )
        guard let data = try? Self.encoder.encode(persisted) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func backUpCorruptFile(_ url: URL) {
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
