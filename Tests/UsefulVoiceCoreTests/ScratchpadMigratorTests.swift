import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct ScratchpadMigratorTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchpad-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func testMigratesNotesAndLeavesLegacyFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let notesURL = dir.appendingPathComponent("notes.json")
        let scratchpadURL = dir.appendingPathComponent("scratchpad.json")
        let notes = NotesStore(fileURL: notesURL)
        notes.add(text: "First note", createdAt: Date(timeIntervalSince1970: 1))
        notes.add(text: "Second note", createdAt: Date(timeIntervalSince1970: 2))

        let store = ScratchpadMigrator.migrateIfNeeded(
            scratchpadURL: scratchpadURL,
            notesURL: notesURL
        )

        #expect(store.all().map(\.title) == ["Second note", "First note"])
        #expect(FileManager.default.fileExists(atPath: notesURL.path))
    }
}
