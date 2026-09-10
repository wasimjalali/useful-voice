import Foundation
import Testing

@testable import UsefulVoiceCore

/// Regression tests for the store write-refusal behaviour.
///
/// Every store previously used `try?` for both reading and writing. The dangerous
/// consequence was not the missing error message but the data loss: a file that
/// failed to READ was treated as an empty store, and the next edit wrote that
/// emptiness back over the intact file. A single transient read error at launch
/// therefore permanently destroyed the user's dictionary, snippets, language
/// memory or history.
///
/// These tests treat "the file must still contain the original data" as the
/// property under test, not merely "an error was reported".
@Suite("Store write refusal")
struct StoreWriteRefusalTests {

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-refusal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A path that exists but can never be read as a file, so `Data(contentsOf:)`
    /// fails with something other than "no such file".
    ///
    /// A directory is used because it is robust for any user: an unreadable *file*
    /// depends on POSIX permissions, which the root user ignores.
    private func makeUnreadablePath(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("unreadable.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - SnippetStore

    @Test("SnippetStore refuses to overwrite a file it could not read")
    func snippetRefusesWriteAfterUnreadable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeUnreadablePath(in: directory)

        let store = SnippetStore(fileURL: url)
        #expect(store.all().isEmpty)

        // Attempt an edit, which triggers a write.
        store.add(trigger: "brb", expansion: "be right back")

        #expect(store.lastSaveError != nil, "the refusal must be reported")
        // The critical property: the unreadable file is untouched, not replaced.
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "the original path must not have been overwritten")
        #expect(store.loadOutcome.allowsWriting == false)
    }

    @Test("SnippetStore reports a successful save and clears the error")
    func snippetReportsSuccess() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snippets.json")

        let store = SnippetStore(fileURL: url)
        #expect(store.save())
        #expect(store.lastSaveError == nil)
        // Nothing was ever added, so a reload sees an empty list whether or not the
        // save wrote anything. Add a snippet first, then reload, so the assertion
        // actually depends on the write having happened.
        store.add(trigger: "t", expansion: "e")
        #expect(store.lastSaveError == nil)

        let reloaded = SnippetStore(fileURL: url)
        #expect(reloaded.all().count == 1)
        #expect(reloaded.lastSaveError == nil)
    }

    @Test("SnippetStore invokes the failure callback exactly once per failed write")
    func snippetFailureCallbackFiresOnce() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeUnreadablePath(in: directory)

        let store = SnippetStore(fileURL: url)
        var messages: [String] = []
        store.onSaveFailure { messages.append($0) }

        store.add(trigger: "one", expansion: "1")
        #expect(messages.count == 1)
        #expect(messages[0].contains("Snippets"))
    }

    @Test("SnippetStore persists real data on a clean first run")
    func snippetRoundTrips() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snippets.json")

        let store = SnippetStore(fileURL: url)
        store.add(trigger: "brb", expansion: "be right back")
        #expect(store.lastSaveError == nil)

        let reloaded = SnippetStore(fileURL: url)
        #expect(reloaded.all().count == 1)
        #expect(reloaded.all().first?.trigger == "brb")
    }

    // MARK: - DictationHistory

    @Test("DictationHistory refuses to overwrite a file it could not read")
    func historyRefusesWriteAfterUnreadable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeUnreadablePath(in: directory)

        let store = DictationHistory(fileURL: url)
        #expect(store.all().isEmpty)
        #expect(store.persist() == false)
        #expect(store.lastSaveError != nil)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "the original path must not have been overwritten")
    }

    @Test("DictationHistory round-trips records on a clean first run")
    func historyRoundTrips() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")

        let store = DictationHistory(fileURL: url)
        store.append(DictationRecord(
            text: "hello there",
            createdAt: Date(),
            language: "en",
            provider: "deepgram",
            durationSeconds: 1.2,
            mode: .raw
        ))
        #expect(store.lastSaveError == nil)

        let reloaded = DictationHistory(fileURL: url)
        #expect(reloaded.all().count == 1)
        #expect(reloaded.all().first?.text == "hello there")
    }

    /// The old code deleted an existing `.bak` before moving the new one onto it,
    /// so a second corruption event destroyed the first backup as well.
    @Test("DictationHistory does not destroy an existing backup on a second corruption")
    func historyPreservesEarlierBackup() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let firstBackup = url.appendingPathExtension("bak")

        // First corruption.
        try Data("{ not json".utf8).write(to: url)
        _ = DictationHistory(fileURL: url)
        let firstBackupContents = try Data(contentsOf: firstBackup)

        // Second corruption.
        try Data("{ also not json".utf8).write(to: url)
        let second = DictationHistory(fileURL: url)

        // The first backup must still be the FIRST file, untouched.
        #expect(try Data(contentsOf: firstBackup) == firstBackupContents)

        // And the second original must have been preserved somewhere.
        if case .corrupt(let backupURL) = second.loadOutcome {
            #expect(backupURL != nil, "the second corrupt file must be preserved")
            if let backupURL {
                #expect(try Data(contentsOf: backupURL) == Data("{ also not json".utf8))
            }
        } else {
            Issue.record("expected a corrupt outcome, got \(second.loadOutcome)")
        }
    }

    // MARK: - DictionaryStore

    @Test("DictionaryStore refuses to overwrite a file it could not read")
    func dictionaryRefusesWriteAfterUnreadable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeUnreadablePath(in: directory)

        let store = DictionaryStore(fileURL: url)
        store.add(word: "Kubernetes")

        #expect(store.lastSaveError != nil)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "the original path must not have been overwritten")
    }

    @Test("DictionaryStore round-trips entries on a clean first run")
    func dictionaryRoundTrips() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dictionary.json")

        let store = DictionaryStore(fileURL: url)
        store.add(word: "Kubernetes", soundsLike: "kubernets")
        #expect(store.lastSaveError == nil)

        let reloaded = DictionaryStore(fileURL: url)
        #expect(reloaded.all().count == 1)
        #expect(reloaded.all().first?.word == "Kubernetes")
        #expect(reloaded.all().first?.soundsLike == "kubernets")
    }

    // MARK: - LanguageMemoryStore

    @Test("LanguageMemoryStore refuses to overwrite a file it could not read")
    func memoryRefusesWriteAfterUnreadable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeUnreadablePath(in: directory)

        let store = LanguageMemoryStore(fileURL: url)
        #expect(store.terms().isEmpty)
        #expect(store.save() == false)
        #expect(store.lastSaveError != nil)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue, "the original path must not have been overwritten")
    }

    @Test("LanguageMemoryStore round-trips terms on a clean first run")
    func memoryRoundTrips() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("language-memory.json")

        let store = LanguageMemoryStore(fileURL: url)
        store.upsertTerm(MemoryTerm(phrase: "Kubernetes", language: .auto))
        #expect(store.lastSaveError == nil)

        let reloaded = LanguageMemoryStore(fileURL: url)
        #expect(reloaded.terms().count == 1)
        #expect(reloaded.terms().first?.phrase == "Kubernetes")
    }

    /// A file from a newer build decodes successfully, so it must be recognised as
    /// incompatible rather than silently downgraded by the next save.
    @Test("LanguageMemoryStore refuses to downgrade a file from a newer build")
    func memoryRefusesNewerSchema() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("language-memory.json")

        let futureVersion = LanguageMemoryPersisted.currentVersion + 4
        // A fully valid snapshot (with all required keys) and only the VERSION in
        // the future: this must be recognised as "from a newer build", not as
        // corruption. A malformed payload would legitimately be quarantined.
        let snapshot = LanguageMemorySnapshot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshotData = try encoder.encode(snapshot)
        let snapshotObject = try JSONSerialization.jsonObject(with: snapshotData)
        let payload: [String: Any] = ["version": futureVersion, "snapshot": snapshotObject]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: url)

        let store = LanguageMemoryStore(fileURL: url)
        #expect(store.loadOutcome.allowsWriting == false)
        #expect(store.save() == false)

        // The newer file is still there, untouched.
        let raw = try Data(contentsOf: url)
        let decoded = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        #expect(decoded?["version"] as? Int == futureVersion)
    }

    // MARK: - Shared reader behaviour

    @Test("A missing file is a clean start and allows writing")
    func missingFileAllowsWriting() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("absent.json")

        let result = StoreFileReader.load(from: url) { data in
            try JSONDecoder().decode([String].self, from: data)
        }
        #expect(result.outcome == .fresh)
        #expect(result.outcome.allowsWriting)
        #expect(result.outcome.userFacingMessage == nil)
    }

    @Test("A corrupt file is quarantined and blocks writing")
    func corruptFileIsQuarantined() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("corrupt.json")
        try Data("{{{".utf8).write(to: url)

        let result = StoreFileReader.load(from: url) { data in
            try JSONDecoder().decode([String].self, from: data)
        }
        guard case .corrupt(let backupURL) = result.outcome else {
            Issue.record("expected corrupt, got \(result.outcome)")
            return
        }
        #expect(result.outcome.allowsWriting == false)
        let backup = try #require(backupURL)
        #expect(try Data(contentsOf: backup) == Data("{{{".utf8))
    }

    @Test("An empty file listing zero values decodes as loaded, not corrupt")
    func emptyArrayIsLoaded() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty.json")
        try Data("[]".utf8).write(to: url)

        let result = StoreFileReader.load(from: url) { data in
            try JSONDecoder().decode([String].self, from: data)
        }
        #expect(result.outcome == .loaded)
        #expect(result.outcome.allowsWriting)
    }

    @Test("Every non-writable outcome explains itself to the user")
    func outcomesAreActionable() {
        let cases: [StoreLoadOutcome] = [
            .unreadable("permission denied"),
            .corrupt(backupURL: nil),
            .corrupt(backupURL: URL(fileURLWithPath: "/tmp/x.json.bak")),
            .incompatible(version: 9),
        ]
        for outcome in cases {
            let message = outcome.userFacingMessage
            #expect(message != nil)
            #expect((message?.count ?? 0) > 20)
            #expect(outcome.allowsWriting == false)
        }
    }
}
