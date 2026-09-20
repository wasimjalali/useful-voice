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

    /// A bulk import previously wrote the whole snapshot once per item (~O(n²)
    /// bytes for n items). It must now mutate in memory and persist exactly once.
    @Test func testBulkImportPersistsExactlyOnceAndRoundTrips() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)

        var outcomes: [Bool] = []
        store.saveObserver = { outcomes.append($0) }

        var terms: [MemoryTerm] = []
        var rules: [ReplacementRule] = []
        var snippets: [MemorySnippet] = []
        for index in 0..<40 {
            terms.append(MemoryTerm(phrase: "imported term \(index)"))
        }
        for index in 0..<30 {
            rules.append(ReplacementRule(match: "observed \(index)", replacement: "corrected \(index)"))
        }
        for index in 0..<30 {
            snippets.append(MemorySnippet(trigger: "trigger \(index)", expansion: "expansion \(index)"))
        }
        let result = store.importSnapshot(LanguageMemorySnapshot(
            terms: terms, replacements: rules, snippets: snippets
        ))

        #expect(result.inserted == 100)
        #expect(result.invalid.isEmpty)
        #expect(outcomes == [true])

        let reopened = LanguageMemoryStore(fileURL: url)
        #expect(reopened.terms().count == 40)
        #expect(reopened.replacements().count == 30)
        #expect(reopened.snippets().count == 30)
        #expect(Set(reopened.terms().map(\.phrase)) == Set(terms.map(\.phrase)))
    }

    /// Re-importing the same snapshot must leave the persisted state unchanged:
    /// merges are idempotent, IDs stay stable, and duplicates are counted rather
    /// than appended. Compare decoded snapshots, not bytes.
    @Test func testReimportIsIdempotent() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)
        // Whole-second dates survive the ISO8601 encoder's second-precision
        // format exactly, so the decoded file can be compared to the in-memory
        // snapshot field-for-field.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = LanguageMemorySnapshot(
            terms: [
                MemoryTerm(phrase: "Sadaa", createdAt: stamp, updatedAt: stamp),
                MemoryTerm(phrase: "Useful Voice", createdAt: stamp, updatedAt: stamp),
            ],
            replacements: [ReplacementRule(match: "sada", replacement: "Sadaa",
                                           createdAt: stamp, updatedAt: stamp)],
            snippets: [MemorySnippet(trigger: "sig", expansion: "Best,\nWasim",
                                     createdAt: stamp, updatedAt: stamp)],
            // Neither side may match an imported phrase, or the upserts'
            // `removeSuggestions(matching:)` would drop it on the second pass.
            suggestions: [MemorySuggestion(kind: .term, observed: "wrds",
                                           proposed: "words", lastSeenAt: stamp)]
        )

        let first = store.importSnapshot(snapshot)
        #expect(first.inserted == 5)
        let afterFirst = store.snapshot()

        var outcomes: [Bool] = []
        store.saveObserver = { outcomes.append($0) }
        let second = store.importSnapshot(snapshot)

        #expect(second.inserted == 0)
        #expect(second.updated == 4)
        #expect(second.duplicates == 1)
        #expect(outcomes == [true])
        #expect(store.snapshot() == afterFirst)

        let reopened = LanguageMemoryStore(fileURL: url)
        #expect(reopened.snapshot() == afterFirst)
    }

    /// `learnFromEdit` produces several entries (phrase-level + word-level
    /// corrections); all of them must persist in a single write.
    @Test func testLearnFromEditPersistsExactlyOnce() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)

        var outcomes: [Bool] = []
        store.saveObserver = { outcomes.append($0) }

        let learned = store.learnFromEdit(
            original: "Please open cloud code",
            corrected: "Please open Claude Code",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(!learned.entries.isEmpty)
        #expect(outcomes == [true])

        let reopened = LanguageMemoryStore(fileURL: url)
        #expect(reopened.snapshot() == store.snapshot())
    }

    /// An edit with nothing to learn must not touch the file at all — the same
    /// "no write when nothing was learned" behaviour the per-upsert writes gave.
    @Test func testLearnFromEditWithoutEntriesDoesNotPersist() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)

        var outcomes: [Bool] = []
        store.saveObserver = { outcomes.append($0) }

        let learned = store.learnFromEdit(original: "   ", corrected: "   ")
        #expect(learned.entries.isEmpty)
        #expect(outcomes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// One-off upserts keep their immediate persist semantics: each call writes.
    @Test func testOneOffUpsertsStillPersistImmediately() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LanguageMemoryStore(fileURL: url)

        var outcomes: [Bool] = []
        store.saveObserver = { outcomes.append($0) }

        store.upsertTerm(MemoryTerm(phrase: "Claude Code"))
        store.upsertReplacement(ReplacementRule(match: "cloud code", replacement: "Claude Code"))
        store.upsertSnippet(MemorySnippet(trigger: "sig", expansion: "Best,\nWasim"))

        #expect(outcomes == [true, true, true])
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
