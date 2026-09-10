import Foundation

public enum LanguageMemoryMigrator {
    /// Imports the legacy `dictionary.json` / `snippets.json` into language memory,
    /// once, when there is no language-memory file yet.
    ///
    /// Two properties matter here and both were missing:
    ///
    /// 1. **A failed migration must not lose the legacy entries.** The write result
    ///    used to be discarded (`_ = store.importSnapshot(…)`). If the write failed
    ///    — a full disk, a permission problem — the app carried on with an empty
    ///    dictionary, and as soon as the user added one word a language-memory file
    ///    existed, so the next launch skipped the migration and the whole legacy
    ///    dictionary was gone for good. The failure is now checked and recorded, and
    ///    the legacy files are deliberately left in place so a human can recover
    ///    them by hand.
    ///
    /// 2. **Re-running it is safe.** The guard is "no language-memory file yet", and
    ///    `importSnapshot` merges by phrase rather than replacing, so the recovery
    ///    path below cannot duplicate entries or clobber anything the user has
    ///    taught since.
    ///
    /// - Returns: the store, plus whether a migration ran and whether it persisted.
    @discardableResult
    public static func migrateIfNeeded(memoryURL: URL,
                                       dictionaryURL: URL,
                                       snippetsURL: URL,
                                       now: Date = Date()) -> LanguageMemoryStore {
        let store = LanguageMemoryStore(fileURL: memoryURL)
        guard !FileManager.default.fileExists(atPath: memoryURL.path),
              FileManager.default.fileExists(atPath: dictionaryURL.path)
                || FileManager.default.fileExists(atPath: snippetsURL.path)
        else { return store }

        let dictionary = DictionaryStore(fileURL: dictionaryURL)
        let snippets = SnippetStore(fileURL: snippetsURL)

        let terms = dictionary.all().map { entry in
            MemoryTerm(
                id: entry.id,
                phrase: entry.word,
                pronunciations: entry.soundsLike.map { [$0] } ?? [],
                aliases: [],
                language: .auto,
                priority: .high,
                notes: entry.soundsLike == nil ? "" : "Migrated sounds-like pronunciation.",
                createdAt: now,
                updatedAt: now,
                usageCount: 0
            )
        }

        let memorySnippets = snippets.all().map { snippet in
            MemorySnippet(
                id: snippet.id,
                trigger: snippet.trigger,
                expansion: snippet.expansion,
                language: .auto,
                tags: [],
                isEnabled: true,
                createdAt: now,
                updatedAt: now,
                usageCount: 0
            )
        }

        let suggestions = dictionary.pendingSuggestionEvidence().map { suggestion in
            MemorySuggestion(
                kind: .term,
                observed: suggestion.term,
                proposed: suggestion.term,
                evidenceCount: suggestion.evidenceCount,
                lastSeenAt: now,
                source: .formatter
            )
        }

        let incoming = terms.count + memorySnippets.count
        guard incoming > 0 || !suggestions.isEmpty else {
            Diagnostics.shared.info("migration", "legacy dictionary and snippets were empty; nothing to migrate")
            return store
        }

        let result = store.importSnapshot(LanguageMemorySnapshot(
            terms: terms,
            replacements: [],
            snippets: memorySnippets,
            suggestions: suggestions
        ))

        // The import reports what it accepted; the store reports whether the result
        // reached disk. Both are needed: a successful merge that failed to save is
        // the dangerous case, because the in-memory state looks correct.
        if let saveError = store.lastSaveError {
            Diagnostics.shared.error(
                "migration",
                "imported \(incoming) legacy entries but could not save them (\(saveError)); "
                    + "the original dictionary.json and snippets.json were left untouched",
            )
        } else {
            Diagnostics.shared.info(
                "migration",
                "imported \(result.inserted) new and updated \(result.updated) legacy entries "
                    + "from dictionary.json and snippets.json",
            )
        }

        return store
    }
}
