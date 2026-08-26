import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct LanguageMemoryMigratorTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("language-memory-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func testMigratesDictionaryAndSnippetsWithoutDeletingLegacyFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dictionaryURL = dir.appendingPathComponent("dictionary.json")
        let snippetsURL = dir.appendingPathComponent("snippets.json")
        let memoryURL = dir.appendingPathComponent("language-memory.json")

        let dictionary = DictionaryStore(fileURL: dictionaryURL)
        dictionary.add(word: "Karko AI", soundsLike: "car co ai")
        dictionary.suggest(["Helsinki"])
        dictionary.suggest(["Helsinki"])

        let snippets = SnippetStore(fileURL: snippetsURL)
        snippets.add(trigger: "my sig", expansion: "Wasim")

        let store = LanguageMemoryMigrator.migrateIfNeeded(
            memoryURL: memoryURL,
            dictionaryURL: dictionaryURL,
            snippetsURL: snippetsURL,
            now: Date(timeIntervalSince1970: 1)
        )

        #expect(store.terms().first?.phrase == "Karko AI")
        #expect(store.terms().first?.pronunciations == ["car co ai"])
        #expect(store.snippets().first?.trigger == "my sig")
        #expect(store.suggestions().first?.observed == "Helsinki")
        #expect(store.suggestions().first?.evidenceCount == 2)
        #expect(FileManager.default.fileExists(atPath: dictionaryURL.path))
        #expect(FileManager.default.fileExists(atPath: snippetsURL.path))
    }
}
