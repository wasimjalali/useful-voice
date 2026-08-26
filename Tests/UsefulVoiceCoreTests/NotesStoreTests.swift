import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct NotesStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString).json")
    }

    @Test func testAddPersistsNewestFirst() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = NotesStore(fileURL: url)
        store.add(text: "first", createdAt: Date(timeIntervalSince1970: 1))
        store.add(text: "second", createdAt: Date(timeIntervalSince1970: 2))
        #expect(store.all().map(\.text) == ["second", "first"])

        let reopened = NotesStore(fileURL: url)
        #expect(reopened.all().map(\.text) == ["second", "first"])
    }

    @Test func testAddIgnoresBlank() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = NotesStore(fileURL: url)
        #expect(store.add(text: "   ", createdAt: Date()) == nil)
        #expect(store.all().isEmpty)
    }

    @Test func testRemove() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = NotesStore(fileURL: url)
        let note = store.add(text: "keep me", createdAt: Date())!
        store.remove(id: note.id)
        #expect(store.all().isEmpty)
    }

    @Test func testUpdateChangesTextKeepsPositionAndTimestamp() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = NotesStore(fileURL: url)
        store.add(text: "first", createdAt: Date(timeIntervalSince1970: 1))
        let second = store.add(text: "second", createdAt: Date(timeIntervalSince1970: 2))!
        store.update(id: second.id, text: "second edited")

        let edited = store.all().first { $0.id == second.id }
        #expect(edited?.text == "second edited")
        #expect(edited?.createdAt == Date(timeIntervalSince1970: 2))
        // Newest-first order is preserved; the edited note stays on top.
        #expect(store.all().map(\.text) == ["second edited", "first"])

        let reopened = NotesStore(fileURL: url)
        #expect(reopened.all().first { $0.id == second.id }?.text == "second edited")
    }

    @Test func testUpdateIgnoresBlank() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = NotesStore(fileURL: url)
        let note = store.add(text: "keep me", createdAt: Date())!
        store.update(id: note.id, text: "   ")
        #expect(store.all().first?.text == "keep me")
    }

    @Test func testCorruptRecoversWithBackup() throws {
        let url = tempFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
        }
        try Data("not json".utf8).write(to: url)
        let store = NotesStore(fileURL: url)
        #expect(store.all().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: url.appendingPathExtension("bak").path))
    }
}
