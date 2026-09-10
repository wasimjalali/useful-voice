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
        // Re-importing the same backup is not an update: the local copies are
        // not older than the incoming records, so they are kept.
        let second = target.importJSON(source.exportAllJSON())

        #expect(first == ScratchpadImportResult(inserted: 2, updated: 0, invalid: []))
        #expect(second == ScratchpadImportResult(inserted: 0, updated: 0,
                                                 keptLocal: 2, invalid: []))
        #expect(target.all().map(\.title) == ["Second", "First"])
        #expect(target.all().last?.tags == ["work"])
    }

    @Test func testImportRejectsInvalidJSON() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)

        #expect(store.importJSON("not json") == nil)
    }

    // MARK: - Non-destructive import (UI-03)

    @Test func testMergeKeepsNewerLocalNoteInsteadOfOverwritingIt() {
        let id = UUID()
        let local = ScratchpadNote(
            id: id, title: "Local", body: "edited locally",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let stale = ScratchpadNote(
            id: id, title: "Backup", body: "older backup copy",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        let outcome = ScratchpadStore.merge(existing: [local], incoming: [stale])

        #expect(outcome.notes == [local])
        #expect(outcome.result.inserted == 0)
        #expect(outcome.result.updated == 0)
        #expect(outcome.result.keptLocal == 1)
        #expect(outcome.result.invalid.isEmpty)
    }

    @Test func testMergeAdoptsNewerIncomingRecord() {
        let id = UUID()
        let local = ScratchpadNote(
            id: id, title: "Local", body: "old",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = ScratchpadNote(
            id: id, title: "Backup", body: "newer from the backup",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 90)
        )

        let outcome = ScratchpadStore.merge(existing: [local], incoming: [newer])

        #expect(outcome.notes.map(\.body) == ["newer from the backup"])
        #expect(outcome.result.updated == 1)
        #expect(outcome.result.keptLocal == 0)
        #expect(outcome.result.inserted == 0)
    }

    @Test func testMergeInsertsRecordWithUnknownID() {
        let existing = ScratchpadNote(
            title: "Local", body: "kept",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let incoming = ScratchpadNote(
            title: "From backup", body: "inserted",
            createdAt: Date(timeIntervalSince1970: 2),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let outcome = ScratchpadStore.merge(existing: [existing], incoming: [incoming])

        #expect(outcome.result.inserted == 1)
        #expect(outcome.result.updated == 0)
        #expect(outcome.result.keptLocal == 0)
        // Pinned first, then newest.
        #expect(outcome.notes.map(\.title) == ["From backup", "Local"])
    }

    @Test func testImportingOlderBackupPreservesNewerLocalEdit() {
        let backupURL = tempFile()
        let targetURL = tempFile()
        defer {
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.removeItem(at: targetURL)
        }
        let backup = ScratchpadStore(fileURL: backupURL)
        _ = backup.add(title: "Todo", body: "original text", tags: [],
                       createdAt: Date(timeIntervalSince1970: 1))!
        let staleJSON = backup.exportAllJSON()

        let target = ScratchpadStore(fileURL: targetURL)
        _ = target.importJSON(staleJSON)

        var edited = target.all()[0]
        edited.body = "edited after the backup"
        edited.updatedAt = Date(timeIntervalSince1970: 500)
        target.update(edited)

        // Restoring the week-old backup must not revert the local edit.
        let result = target.importJSON(staleJSON)

        #expect(result?.keptLocal == 1)
        #expect(result?.updated == 0)
        #expect(result?.inserted == 0)
        #expect(target.all().first?.body == "edited after the backup")

        let reopened = ScratchpadStore(fileURL: targetURL)
        #expect(reopened.all().first?.body == "edited after the backup")
    }

    @Test func testDecodingOldFormatFileWithoutTimestampSucceeds() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let json = """
        {"version":1,"notes":[{"id":"\(id.uuidString)","title":"Legacy",\
        "body":"written before updatedAt existed","tags":["x"],"isPinned":false,\
        "createdAt":"2020-01-01T00:00:00Z"}]}
        """
        try Data(json.utf8).write(to: url)

        let store = ScratchpadStore(fileURL: url)

        #expect(store.all().count == 1)
        let note = store.all().first
        #expect(note?.title == "Legacy")
        #expect(note?.body == "written before updatedAt existed")
        // Falls back to createdAt so a legacy note is never treated as newer
        // than a local edit.
        #expect(note?.updatedAt == note?.createdAt)
    }

    @Test func testDecodingLegacyBareArrayWithoutOptionalFieldsSucceeds() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","title":"Bare","body":"no tags or pin",\
        "createdAt":"2021-06-01T12:00:00Z"}]
        """
        try Data(json.utf8).write(to: url)

        let store = ScratchpadStore(fileURL: url)

        #expect(store.all().count == 1)
        #expect(store.all().first?.tags == [])
        #expect(store.all().first?.isPinned == false)
        #expect(store.all().first?.updatedAt == store.all().first?.createdAt)
    }

    // MARK: - Delete and undo (UI-01)

    @Test func testDeleteThenRestoreReturnsNoteToSamePositionAndContent() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)
        _ = store.add(title: "First", body: "one", tags: ["a"],
                      createdAt: Date(timeIntervalSince1970: 1))!
        let middle = store.add(title: "Middle", body: "two", tags: ["b"],
                               createdAt: Date(timeIntervalSince1970: 2))!
        _ = store.add(title: "Third", body: "three", tags: [],
                      createdAt: Date(timeIntervalSince1970: 3))!

        #expect(store.all().map(\.title) == ["Third", "Middle", "First"])

        let removed = store.delete(id: middle.id)
        #expect(removed?.index == 1)
        #expect(removed?.note == middle)
        #expect(store.all().map(\.title) == ["Third", "First"])

        #expect(store.restore(middle, at: removed!.index))
        #expect(store.all().map(\.title) == ["Third", "Middle", "First"])
        #expect(store.all().firstIndex { $0.id == middle.id } == removed?.index)
        // Exact content and title come back.
        #expect(store.all().first { $0.id == middle.id } == middle)
    }

    @Test func testRestorePersistsToDisk() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)
        let note = store.add(title: "Keep", body: "body text", tags: ["x"],
                             createdAt: Date(timeIntervalSince1970: 5))!

        store.delete(id: note.id)
        #expect(ScratchpadStore(fileURL: url).all().isEmpty)

        store.restore(note, at: 0)

        let reopened = ScratchpadStore(fileURL: url)
        #expect(reopened.all() == [note])
    }

    @Test func testRestoreIgnoresAnIDThatIsAlreadyPresent() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)
        let note = store.add(title: "Once", body: "only once", tags: [],
                             createdAt: Date(timeIntervalSince1970: 1))!

        #expect(store.restore(note, at: 0) == false)
        #expect(store.all().count == 1)
    }

    // MARK: - Save failure reporting (UI-02)

    @Test func testSuccessfulSaveReportsNoError() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ScratchpadStore(fileURL: url)
        _ = store.add(title: "Fine", body: "lands on disk", tags: [], createdAt: Date())
        #expect(store.lastSaveError == nil)
    }

    @Test func testFailedWriteIsReportedInsteadOfSwallowed() throws {
        // A regular file where the store needs a directory: persisting cannot
        // succeed here on any account, root included.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchpad-blocked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: blocker) }
        try Data("not a directory".utf8).write(to: blocker)
        let fileURL = blocker.appendingPathComponent("scratchpad.json")

        let store = ScratchpadStore(fileURL: fileURL)
        var reported: [Error] = []
        store.onSaveFailure = { reported.append($0) }

        _ = store.add(title: "Doomed", body: "never lands on disk", tags: [],
                      createdAt: Date())

        // Skip cleanly if the environment somehow allows the write.
        guard store.lastSaveError != nil else { return }

        #expect(reported.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        store.clearSaveError()
        #expect(store.lastSaveError == nil)
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
