import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct DictionaryStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-\(UUID().uuidString).json")
    }

    @Test func testAddPersistsAndIsNewestFirst() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Karko AI")
        store.add(word: "Supabase")
        #expect(store.all().map(\.word) == ["Supabase", "Karko AI"])

        let reopened = DictionaryStore(fileURL: url)
        #expect(reopened.all().map(\.word) == ["Supabase", "Karko AI"])
    }

    @Test func testAddDeDupesCaseInsensitiveAndMovesToFront() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Karko")
        store.add(word: "Vercel")
        store.add(word: "karko")
        #expect(store.all().count == 2)
        #expect(store.all().first?.word == "karko")
    }

    @Test func testAddClearsMatchingPendingSuggestion() {
        // Manually adding a word that is also a pending suggestion must resolve
        // the suggestion; a stale chip would linger forever otherwise (suggest()
        // skips terms matching entries, and accepting it just re-adds the word).
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["Karko"])
        #expect(store.pendingSuggestions() == ["Karko"])
        store.add(word: "karko")
        #expect(store.pendingSuggestions().isEmpty)
    }

    @Test func testReAddingWordWithoutAliasKeepsExistingAlias() {
        // Accepting a suggestion calls add(word:) with no alias; that must not
        // wipe a "sounds like" the user set on the same word earlier.
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Karko", soundsLike: "carco")
        store.add(word: "Karko")
        #expect(store.all().count == 1)
        #expect(store.all().first?.soundsLike == "carco")
    }

    @Test func testBiasListPersonalFirstThenBaseCapped() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Zzzpersonal")
        let list = store.biasList(budget: 5)
        #expect(list.first == "Zzzpersonal")
        #expect(list.count == 5)
    }

    @Test func testBiasListDeDupesAgainstBase() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "supabase") // also in base vocab
        let list = store.biasList(budget: 100)
        let occurrences = list.filter { $0.lowercased() == "supabase" }.count
        #expect(occurrences == 1)
        #expect(list.first == "supabase")
    }

    @Test func testSuggestExcludesPersonalDismissedAndDuplicates() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Existing")
        store.suggest(["Existing", "Newterm", "Newterm"])
        #expect(store.pendingSuggestions() == ["Newterm"])
    }

    @Test func testAcceptMovesToPersonal() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["Karko"])
        store.accept("Karko")
        #expect(store.pendingSuggestions().isEmpty)
        #expect(store.all().first?.word == "Karko")
    }

    @Test func testDismissPreventsResuggestion() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["Junk"])
        store.dismiss("Junk")
        store.suggest(["Junk"])
        #expect(store.pendingSuggestions().isEmpty)
    }

    @Test func testCorruptFileRecoversToEmptyWithBackup() throws {
        let url = tempFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
        }
        try Data("{ not json".utf8).write(to: url)
        let store = DictionaryStore(fileURL: url)
        #expect(store.all().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("bak").path))
    }

    // MARK: - New smart-dedupe tests

    /// "Karko's" must not be suggested when "Karko" is already saved.
    @Test func testSuggestRejectsPossessiveVariantOfSavedWord() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Karko")
        store.suggest(["Karko's"])
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// "Karkos" must not be suggested when "Karko" is already saved.
    @Test func testSuggestRejectsPluralVariantOfSavedWord() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Karko")
        store.suggest(["Karkos"])
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// "Claude-Code" must not be suggested when "Claude Code" is already saved.
    @Test func testSuggestRejectsHyphenVariantOfSavedWord() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Claude Code")
        store.suggest(["Claude-Code"])
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// "Karko." must not be suggested when "Karko" is already saved.
    @Test func testSuggestRejectsTrailingPunctuationVariant() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Karko")
        store.suggest(["Karko."])
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// A BaseVocabulary term must not be re-suggested (pick "Supabase" from the list).
    @Test func testSuggestRejectsBaseVocabularyTerm() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["Supabase"])
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// A BaseVocabulary plural "Supabases" also rejected.
    @Test func testSuggestRejectsBaseVocabularyPluralVariant() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["Supabases"])
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// Repeat suggestion bumps count; highest count term sorts first.
    @Test func testRepeatSuggestionBumpsRankToFirst() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["TermX"])   // count 1
        store.suggest(["TermY"])   // count 1
        store.suggest(["TermX"])   // count 2 for TermX
        let suggestions = store.pendingSuggestions()
        #expect(suggestions.first == "TermX")
    }

    @Test func testPendingSuggestionEvidenceExposesCountsForMigration() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["TermX"])
        store.suggest(["TermY"])
        store.suggest(["TermX"])

        #expect(store.pendingSuggestionEvidence().first?.term == "TermX")
        #expect(store.pendingSuggestionEvidence().first?.evidenceCount == 2)
        #expect(store.pendingSuggestionEvidence().last?.evidenceCount == 1)
    }

    /// Quality filter: 2-char term rejected.
    @Test func testSuggestRejectsTwoCharTerm() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["ab"])
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// Quality filter: numeric-only term rejected.
    @Test func testSuggestRejectsNumericOnlyTerm() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["123"])
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// Quality filter: 5-word phrase rejected.
    @Test func testSuggestRejectsFiveWordPhrase() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["one two three four five"])
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// Legacy JSON without pendingCounts decodes with entries intact.
    @Test func testLegacyJSONWithoutPendingCountsDecodes() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // Minimal valid JSON matching old Persisted structure (no pendingCounts field).
        let legacy = """
        {
            "entries": [
                {"id": "00000000-0000-0000-0000-000000000001", "word": "LegacyWord"}
            ],
            "dismissed": [],
            "pending": ["PendingTerm"]
        }
        """
        try Data(legacy.utf8).write(to: url)
        let store = DictionaryStore(fileURL: url)
        #expect(store.all().map(\.word) == ["LegacyWord"])
        #expect(store.pendingSuggestions() == ["PendingTerm"])
    }

    /// dismiss() cap: after 200 dismissed words adding one more drops the oldest.
    @Test func testDismissedCapAt200() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        // Dismiss 200 unique words.
        for i in 0..<200 {
            let term = "word\(String(format: "%04d", i))"
            store.suggest([term])
            store.dismiss(term)
        }
        // Now dismiss one more.
        store.suggest(["newcomer"])
        store.dismiss("newcomer")
        // Total dismissed should remain 200.
        // We verify indirectly: "newcomer" is dismissed so won't re-appear,
        // and the first word ("word0000") should have been dropped, meaning
        // suggesting it again should succeed.
        store.suggest(["word0000"])
        #expect(store.pendingSuggestions() == ["word0000"])
    }

    /// accept() removes via matches (possessive form accepts the base word).
    @Test func testAcceptViaMatchesRemovesPending() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["TermA"])
        store.accept("terma") // canonical match, different case
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// dismiss() removes via matches (hyphen variant dismisses space variant).
    @Test func testDismissViaMatchesRemovesPending() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.suggest(["Claude Code"])
        store.dismiss("Claude-Code") // canonical matches
        #expect(store.pendingSuggestions().isEmpty)
        // Re-suggesting the space variant should also be blocked.
        store.suggest(["Claude Code"])
        #expect(store.pendingSuggestions().isEmpty)
    }

    /// add(word:) dedupes via matches (possessive in entries deduped by base).
    @Test func testAddDedupesByCanonical() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Karko")
        store.add(word: "Karkos") // canonical "karkos" matches "karko" via plural
        #expect(store.all().count == 1)
    }

    /// biasList dedupes by canonical key.
    @Test func testBiasListDedupesByCanonical() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = DictionaryStore(fileURL: url)
        store.add(word: "Claude Code")
        // "Claude Code" canonically matches "Claude-Code" if it were in base,
        // but more importantly, adding both variants should yield one entry in bias list.
        store.add(word: "Claude-Code") // deduped by add()
        let list = store.biasList(budget: 100)
        let count = list.filter { TermMatcher.matches($0, "Claude Code") }.count
        #expect(count == 1)
    }
}
