import Foundation

public enum LanguageMemoryMigrator {
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

        _ = store.importSnapshot(LanguageMemorySnapshot(
            terms: terms,
            replacements: [],
            snippets: memorySnippets,
            suggestions: suggestions
        ))

        return store
    }
}
