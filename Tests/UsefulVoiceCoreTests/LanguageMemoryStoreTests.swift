import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct LanguageMemoryStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("language-memory-\(UUID().uuidString).json")
    }

    @Test func testUpsertPersistsAndDedupeByCanonicalPhrase() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)
        store.upsertTerm(MemoryTerm(phrase: "Claude Code"))
        store.upsertTerm(MemoryTerm(phrase: "claude-code"))

        #expect(store.terms().count == 1)

        let reopened = LanguageMemoryStore(fileURL: url)
        #expect(reopened.terms().map(\.phrase) == ["claude-code"])
    }

    @Test func testSuggestionsCanBeAcceptedAsReplacement() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)
        let suggestion = MemorySuggestion(
            kind: .replacement,
            observed: "cloud code",
            proposed: "Claude Code"
        )
        _ = store.importSnapshot(LanguageMemorySnapshot(suggestions: [suggestion]))
        store.acceptSuggestion(id: suggestion.id, as: .replacement)

        #expect(store.replacements().first?.match == "cloud code")
        #expect(store.replacements().first?.replacement == "Claude Code")
    }

    @Test func testRecordUsageIncrementsKnownTermsAndReplacementsOnlyOncePerCall() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)
        let term = store.upsertTerm(MemoryTerm(phrase: "Claude Code"))
        let otherTerm = store.upsertTerm(MemoryTerm(phrase: "Karko"))
        let rule = store.upsertReplacement(ReplacementRule(
            match: "cloud code",
            replacement: "Claude Code"
        ))
        let snippet = store.upsertSnippet(MemorySnippet(
            trigger: "my signature",
            expansion: "Best,\nWasim"
        ))
        let date = Date(timeIntervalSince1970: 123)

        store.recordUsage(
            termIDs: [term.id, term.id, UUID()],
            replacementRuleIDs: [rule.id, rule.id, UUID()],
            snippetIDs: [snippet.id, snippet.id, UUID()],
            at: date
        )

        #expect(store.terms().first { $0.id == term.id }?.usageCount == 1)
        #expect(store.terms().first { $0.id == term.id }?.updatedAt == date)
        #expect(store.terms().first { $0.id == otherTerm.id }?.usageCount == 0)
        #expect(store.replacements().first?.usageCount == 1)
        #expect(store.replacements().first?.updatedAt == date)
        #expect(store.snippets().first?.usageCount == 1)
        #expect(store.snippets().first?.updatedAt == date)

        let reopened = LanguageMemoryStore(fileURL: url)
        #expect(reopened.terms().first { $0.id == term.id }?.usageCount == 1)
        #expect(reopened.replacements().first?.usageCount == 1)
        #expect(reopened.snippets().first?.usageCount == 1)
    }

    @Test func testUpsertPersistsPausedReplacementsAndSnippets() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)
        var rule = store.upsertReplacement(ReplacementRule(
            match: "cloud code",
            replacement: "Claude Code"
        ))
        var snippet = store.upsertSnippet(MemorySnippet(
            trigger: "my signature",
            expansion: "Best,\nWasim"
        ))

        rule.isEnabled = false
        snippet.isEnabled = false
        _ = store.upsertReplacement(rule)
        _ = store.upsertSnippet(snippet)

        let reopened = LanguageMemoryStore(fileURL: url)
        #expect(reopened.replacements().first?.isEnabled == false)
        #expect(reopened.snippets().first?.isEnabled == false)
    }

    @Test func testLearningCorrectionCreatesRuleOrHighPriorityTerm() {
        let replacement = LanguageMemoryLearningPolicy.makeEntry(
            observed: "cloud code",
            corrected: "Claude Code"
        )
        if case .replacement(let rule) = replacement {
            #expect(rule.match == "cloud code")
            #expect(rule.replacement == "Claude Code")
            #expect(rule.matchMode == .wordBoundaryPhrase)
        } else {
            Issue.record("Expected a deterministic replacement")
        }

        let term = LanguageMemoryLearningPolicy.makeEntry(
            observed: "Codex",
            corrected: "Codex"
        )
        if case .term(let memoryTerm) = term {
            #expect(memoryTerm.phrase == "Codex")
            #expect(memoryTerm.priority == .high)
        } else {
            Issue.record("Expected a high-priority memory term")
        }
    }

    @Test func testLearnFromEditPersistsRuleTermAndAppliesNextTime() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)

        let learned = store.learnFromEdit(
            original: "Please open cloud code",
            corrected: "Please open Claude Code"
        )
        #expect(!learned.pairs.isEmpty)
        #expect(!store.replacements().isEmpty)
        #expect(store.terms().contains { $0.phrase == "Claude Code" || $0.phrase == "Claude" })

        let processed = LanguageMemoryPostProcessor.rawResult(
            for: "I use cloud code daily",
            snapshot: store.snapshot(),
            language: .en
        )
        #expect(processed.text.contains("Claude Code") || processed.text.contains("Claude"))
    }

    @Test func testUpsertTermMergesPronunciationsAndKeepsStableID() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)
        let first = store.upsertTerm(MemoryTerm(phrase: "Sadaa", pronunciations: ["sada"]))
        let second = store.upsertTerm(MemoryTerm(phrase: "Sadaa", pronunciations: ["sa da"]))
        #expect(store.terms().count == 1)
        #expect(second.id == first.id)
        #expect(Set(second.pronunciations) == Set(["sada", "sa da"]))
    }

    @Test func testCorruptFileRecoversWithBackup() throws {
        let url = tempFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
        }
        try Data("not json".utf8).write(to: url)
        let store = LanguageMemoryStore(fileURL: url)
        #expect(store.snapshot() == LanguageMemorySnapshot())
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }
}
