import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct ScratchpadStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchpad-\(UUID().uuidString).json")
    }

    @Test func testAddPersistsPinnedFirstThenRecent() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)
        let first = store.add(title: "First", body: "one", tags: ["a"],
                              createdAt: Date(timeIntervalSince1970: 1))!
        _ = store.add(title: "Second", body: "two", tags: [],
                      createdAt: Date(timeIntervalSince1970: 2))!
        store.setPinned(id: first.id, isPinned: true)

        #expect(store.all().map(\.title) == ["First", "Second"])

        let reopened = ScratchpadStore(fileURL: url)
        #expect(reopened.all().map(\.title) == ["First", "Second"])
    }

    @Test func testSearchMatchesTitleBodyAndTags() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)
        _ = store.add(title: "Launch", body: "ship the app", tags: ["release"],
                      createdAt: Date())
        #expect(store.search("ship").count == 1)
        #expect(store.search("release").count == 1)
        #expect(store.search("missing").isEmpty)
    }

    @Test func testCaptureDictationCreatesDedicatedNote() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)
        _ = store.add(title: "Existing", body: "Keep this separate", tags: [],
                      createdAt: Date(timeIntervalSince1970: 1))

        let note = store.captureDictation(
            "  New transcript  ",
            createdAt: Date(timeIntervalSince1970: 2)
        )

        #expect(note?.title == "Dictation")
        #expect(note?.body == "New transcript")
        #expect(store.all().map(\.title) == ["Dictation", "Existing"])
        #expect(store.all().last?.body == "Keep this separate")
    }

    @Test func testDuplicateAndExportMarkdown() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)
        let note = store.add(title: "Plan", body: "one", tags: ["work"],
                             createdAt: Date(timeIntervalSince1970: 1))!
        let copy = store.duplicate(id: note.id, now: Date(timeIntervalSince1970: 2))

        #expect(copy?.title == "Plan copy")
        #expect(store.exportMarkdown(id: note.id) == "# Plan\n\none\n\n#work")
    }

    @Test func testNoteStatsDoNotAffectPersistence() {
        let note = ScratchpadNote(title: "Stats", body: "one two\nthree", tags: [])
        #expect(note.wordCount == 3)
        #expect(note.characterCount == "one two\nthree".count)
        #expect(ScratchpadNote.wordCount(in: "  one   two\tthree  ") == 3)
    }

    @Test func testExportsWorkspaceMarkdownAndJSON() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)
        _ = store.add(title: "First", body: "one", tags: ["work"],
                      createdAt: Date(timeIntervalSince1970: 1))!
        _ = store.add(title: "Second", body: "two", tags: [],
                      createdAt: Date(timeIntervalSince1970: 2))!

        #expect(store.exportAllMarkdown().contains("# Second\n\ntwo\n\n---\n\n# First"))
        let json = store.exportAllJSON()
        #expect(json.contains("\"version\""))
        #expect(json.contains("\"First\""))
        #expect(json.contains("\"Second\""))
    }

    @Test func testImportsWorkspaceJSONAndUpdatesByID() {
        let sourceURL = tempFile()
        let targetURL = tempFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let source = ScratchpadStore(fileURL: sourceURL)
        _ = source.add(title: "First", body: "one", tags: ["#work", "work"],
                       createdAt: Date(timeIntervalSince1970: 1))!
        _ = source.add(title: "Second", body: "two", tags: [],
                       createdAt: Date(timeIntervalSince1970: 2))!

        let target = ScratchpadStore(fileURL: targetURL)
        let first = target.importJSON(source.exportAllJSON())
        let second = target.importJSON(source.exportAllJSON())

        #expect(first == ScratchpadImportResult(inserted: 2, updated: 0, invalid: []))
        #expect(second == ScratchpadImportResult(inserted: 0, updated: 2, invalid: []))
        #expect(target.all().map(\.title) == ["Second", "First"])
        #expect(target.all().last?.tags == ["work"])
    }

    @Test func testImportRejectsInvalidJSON() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)

        #expect(store.importJSON("not json") == nil)
    }

    @Test func testCorruptFileRecoversWithBackup() throws {
        let url = tempFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
        }
        try Data("nope".utf8).write(to: url)
        let store = ScratchpadStore(fileURL: url)
        #expect(store.all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }
}
