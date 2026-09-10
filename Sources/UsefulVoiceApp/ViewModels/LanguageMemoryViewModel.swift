import Foundation
import SwiftUI
import UsefulVoiceCore

@MainActor
final class LanguageMemoryViewModel: ObservableObject {
    @Published var terms: [MemoryTerm] = []
    @Published var replacements: [ReplacementRule] = []
    @Published var snippets: [MemorySnippet] = []
    @Published var suggestions: [MemorySuggestion] = []
    @Published var query = ""

    /// A persistent problem with the backing file, if any.
    ///
    /// Unlike a save error this does not clear itself: it means the store could not
    /// read the file at launch and has therefore refused every write since, so the
    /// user's edits are being held in memory only. It must stay visible until the
    /// app restarts with a readable file.
    @Published var loadIssue: String?

    /// The most recent write failure, cleared once a write succeeds.
    @Published var saveIssue: String?

    private let store: LanguageMemoryStore

    init(store: LanguageMemoryStore) {
        self.store = store
        loadIssue = store.loadOutcome.userFacingMessage
        saveIssue = store.lastSaveError
        // Report write failures into the UI instead of letting them vanish. Before
        // this, the store discarded the error entirely and the page kept saying
        // "Saved" while nothing reached disk.
        store.onSaveFailure { [weak self] message in
            Task { @MainActor in
                self?.saveIssue = message
            }
        }
        refresh()
    }

    /// The single message the page should show, load problems taking precedence.
    var statusMessage: String? { loadIssue ?? saveIssue }

    /// Acknowledge a write failure. A load problem cannot be dismissed, because the
    /// store is still refusing to write and the condition is still true.
    func dismissSaveIssue() {
        saveIssue = nil
        store.clearSaveError()
    }

    var filteredTerms: [MemoryTerm] {
        filter(terms) { [$0.phrase, $0.notes] + $0.aliases + $0.pronunciations }
    }

    var filteredReplacements: [ReplacementRule] {
        filter(replacements) { [$0.match, $0.replacement] }
    }

    var filteredSnippets: [MemorySnippet] {
        filter(snippets) { [$0.trigger, $0.expansion] + $0.tags }
    }

    var filteredSuggestions: [MemorySuggestion] {
        filter(suggestions) { [$0.observed, $0.proposed] }
    }

    func refresh() {
        terms = store.terms()
        replacements = store.replacements()
        snippets = store.snippets()
        suggestions = store.suggestions()
    }

    func addTerm(phrase: String,
                 pronunciations: [String] = [],
                 aliases: [String] = [],
                 priority: MemoryPriority = .high,
                 language: MemoryLanguage = .auto,
                 notes: String = "") {
        _ = store.upsertTerm(MemoryTerm(
            phrase: phrase,
            pronunciations: pronunciations,
            aliases: aliases,
            language: language,
            priority: priority,
            notes: notes
        ))
        refresh()
    }

    func updateTerm(_ term: MemoryTerm) {
        var copy = term
        copy.updatedAt = Date()
        _ = store.upsertTerm(copy)
        refresh()
    }

    func removeTerm(id: UUID) {
        store.removeTerm(id: id)
        refresh()
    }

    func addReplacement(match: String,
                        replacement: String,
                        mode: ReplacementMatchMode = .wordBoundaryPhrase,
                        language: MemoryLanguage = .auto) {
        _ = store.upsertReplacement(ReplacementRule(
            match: match,
            replacement: replacement,
            matchMode: mode,
            language: language
        ))
        refresh()
    }

    func updateReplacement(_ replacement: ReplacementRule) {
        var copy = replacement
        copy.updatedAt = Date()
        _ = store.upsertReplacement(copy)
        refresh()
    }

    func removeReplacement(id: UUID) {
        store.removeReplacement(id: id)
        refresh()
    }

    func setReplacementEnabled(_ id: UUID, isEnabled: Bool) {
        guard var replacement = replacements.first(where: { $0.id == id }) else { return }
        replacement.isEnabled = isEnabled
        updateReplacement(replacement)
    }

    func addSnippet(trigger: String,
                    expansion: String,
                    tags: [String] = [],
                    language: MemoryLanguage = .auto) {
        _ = store.upsertSnippet(MemorySnippet(
            trigger: trigger,
            expansion: expansion,
            language: language,
            tags: tags
        ))
        refresh()
    }

    func updateSnippet(_ snippet: MemorySnippet) {
        var copy = snippet
        copy.updatedAt = Date()
        _ = store.upsertSnippet(copy)
        refresh()
    }

    func removeSnippet(id: UUID) {
        store.removeSnippet(id: id)
        refresh()
    }

    func setSnippetEnabled(_ id: UUID, isEnabled: Bool) {
        guard var snippet = snippets.first(where: { $0.id == id }) else { return }
        snippet.isEnabled = isEnabled
        updateSnippet(snippet)
    }

    func acceptSuggestion(_ id: UUID, as kind: MemorySuggestionKind) {
        store.acceptSuggestion(id: id, as: kind)
        refresh()
    }

    func dismissSuggestion(_ id: UUID) {
        store.dismissSuggestion(id: id)
        refresh()
    }

    @discardableResult
    func learnCorrection(observed: String, corrected: String) -> LanguageMemoryLearnResult {
        let result = store.learnFromEdit(original: observed, corrected: corrected)
        refresh()
        return result
    }

    /// Preview the pairs that would be learned without writing them.
    func previewLearnCorrection(observed: String, corrected: String) -> [CorrectionPair] {
        let existing = terms.map(\.phrase) + replacements.map(\.replacement)
        return LanguageMemoryLearningPolicy.entries(
            observed: observed,
            corrected: corrected,
            existingDictionary: existing
        ).pairs
    }

    func recordUsage(termIDs: [UUID], replacementRuleIDs: [UUID], snippetIDs: [UUID] = []) {
        store.recordUsage(termIDs: termIDs, replacementRuleIDs: replacementRuleIDs,
                          snippetIDs: snippetIDs)
        refresh()
    }

    func exportSnapshot() -> LanguageMemorySnapshot {
        store.exportSnapshot()
    }

    func exportSnapshotJSON() -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(store.exportSnapshot()) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func importSnapshotJSON(_ json: String) -> LanguageMemoryImportResult? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = json.data(using: .utf8),
              let snapshot = try? decoder.decode(LanguageMemorySnapshot.self, from: data)
        else { return nil }
        let result = store.importSnapshot(snapshot)
        refresh()
        return result
    }

    func exportTermsCSV() -> String {
        LanguageMemoryCSV.exportTerms(store.terms())
    }

    func exportReplacementsCSV() -> String {
        LanguageMemoryCSV.exportReplacements(store.replacements())
    }

    func importTermsCSV(_ csv: String) -> LanguageMemoryImportResult {
        let imported = LanguageMemoryCSV.importTerms(csv)
        let result = store.importSnapshot(LanguageMemorySnapshot(terms: imported.terms))
        refresh()
        return LanguageMemoryImportResult(
            inserted: result.inserted,
            updated: result.updated,
            duplicates: result.duplicates,
            invalid: result.invalid + imported.invalid
        )
    }

    func importReplacementsCSV(_ csv: String) -> LanguageMemoryImportResult {
        let imported = LanguageMemoryCSV.importReplacements(csv)
        let result = store.importSnapshot(LanguageMemorySnapshot(replacements: imported.replacements))
        refresh()
        return LanguageMemoryImportResult(
            inserted: result.inserted,
            updated: result.updated,
            duplicates: result.duplicates,
            invalid: result.invalid + imported.invalid
        )
    }

    private func filter<T>(_ values: [T], fields: (T) -> [String]) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return values }
        return values.filter { value in
            fields(value).contains { $0.range(of: trimmed, options: .caseInsensitive) != nil }
        }
    }
}
