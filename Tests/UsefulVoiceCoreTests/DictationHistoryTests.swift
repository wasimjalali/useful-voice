import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite final class DictationHistoryTests {
    private let dir: URL
    private let fileURL: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(_ text: String, at date: Date) -> DictationRecord {
        DictationRecord(text: text, createdAt: date, language: "en",
                        provider: "azure", durationSeconds: 1.5)
    }

    @Test func testLegacyRecordWithoutModeDecodes() throws {
        // history.json written before the mode field existed.
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","text":"old one",
          "createdAt":"2026-06-01T10:00:00Z","language":"en",
          "provider":"azure","durationSeconds":2.5}]
        """
        try Data(legacy.utf8).write(to: fileURL)
        let history = DictationHistory(fileURL: fileURL)
        let all = history.all()
        #expect(all.count == 1)
        #expect(all.first?.text == "old one")
        #expect(all.first?.mode == nil)
        #expect(all.first?.snippetIDs == nil)
    }

    @Test func testLegacyPromptModeDecodesAsRaw() throws {
        // Records written by the removed Prompt Mode carry mode "prompt"; the
        // whole history must still load, mapping the dead mode to .raw rather than
        // throwing and discarding every record.
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000002","text":"old prompt",
          "createdAt":"2026-06-01T10:00:00Z","language":"en",
          "provider":"azure","durationSeconds":2.5,"mode":"prompt",
          "promptTarget":"Claude"}]
        """
        try Data(legacy.utf8).write(to: fileURL)
        let history = DictationHistory(fileURL: fileURL)
        #expect(history.all().count == 1)
        #expect(history.all().first?.text == "old prompt")
        #expect(history.all().first?.mode == .raw)
    }

    @Test func testModeRoundTrip() throws {
        let history = DictationHistory(fileURL: fileURL)
        history.append(DictationRecord(
            text: "cleaned", createdAt: Date(timeIntervalSince1970: 1_000),
            language: "en", provider: "azure", durationSeconds: 1,
            mode: .formatted))
        let reloaded = DictationHistory(fileURL: fileURL)
        #expect(reloaded.all().first?.mode == .formatted)
    }

    @Test func testRecordPreservesDiagnosticFields() {
        let ruleID = UUID()
        let snippetID = UUID()
        let record = DictationRecord(
            text: "x", createdAt: Date(), language: nil, provider: "deepgram",
            durationSeconds: 1, mode: .formatted, rawText: "raw",
            replacementRuleIDs: [ruleID], snippetIDs: [snippetID],
            audioPath: "/tmp/audio.wav")
        #expect(record.mode == .formatted)
        #expect(record.rawText == "raw")
        #expect(record.replacementRuleIDs == [ruleID])
        #expect(record.snippetIDs == [snippetID])
        #expect(record.audioPath == "/tmp/audio.wav")
    }

    @Test func testRoundTripPersists() throws {
        let history = DictationHistory(fileURL: fileURL)
        let first = record("first", at: Date(timeIntervalSince1970: 1_000))
        let second = record("second", at: Date(timeIntervalSince1970: 2_000))
        history.append(first)
        history.append(second)

        let reloaded = DictationHistory(fileURL: fileURL)
        let all = reloaded.all()
        #expect(all.count == 2)
        #expect(all[0] == second)
        #expect(all[1] == first)
    }

    @Test func testRecentCaps() throws {
        let history = DictationHistory(fileURL: fileURL)
        history.append(record("a", at: Date(timeIntervalSince1970: 1_000)))
        history.append(record("b", at: Date(timeIntervalSince1970: 2_000)))
        let newest = record("c", at: Date(timeIntervalSince1970: 3_000))
        history.append(newest)

        #expect(history.recent(1).count == 1)
        #expect(history.recent(1).first == newest)
        #expect(history.recent(10).count == 3)
    }

    @Test func testSearchCaseInsensitive() throws {
        let history = DictationHistory(fileURL: fileURL)
        let hello = record("Hello World", at: Date(timeIntervalSince1970: 1_000))
        let guten = record("Guten Tag", at: Date(timeIntervalSince1970: 2_000))
        history.append(hello)
        history.append(guten)

        let hits = history.search("hello")
        #expect(hits.count == 1)
        #expect(hits.first == hello)
        #expect(history.search("  ").count == 2)
    }

    @Test func testCorruptFileRecovers() throws {
        try Data("{ not json".utf8).write(to: fileURL)
        let history = DictationHistory(fileURL: fileURL)
        #expect(history.all().isEmpty)
        let backup = fileURL.appendingPathExtension("bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func testRecordCodableRoundTrip() throws {
        let original = DictationRecord(text: "round trip",
                                       createdAt: Date(timeIntervalSince1970: 1_234),
                                       language: "de", provider: "azure",
                                       durationSeconds: 3.25)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DictationRecord.self, from: data)
        #expect(decoded == original)
    }

    @Test func testDeleteRemovesExactRecord() throws {
        let history = DictationHistory(fileURL: fileURL)
        let r1 = record("first", at: Date(timeIntervalSince1970: 1_000))
        let r2 = record("second", at: Date(timeIntervalSince1970: 2_000))
        let r3 = record("third", at: Date(timeIntervalSince1970: 3_000))
        history.append(r1)
        history.append(r2)
        history.append(r3)

        history.delete(id: r2.id)

        // In-memory check: only r1 and r3 remain, newest-first.
        let inMemory = history.all()
        #expect(inMemory.count == 2)
        #expect(!inMemory.contains(where: { $0.id == r2.id }))
        #expect(inMemory[0] == r3)
        #expect(inMemory[1] == r1)

        // Reload from disk to confirm persistence.
        let reloaded = DictationHistory(fileURL: fileURL)
        let onDisk = reloaded.all()
        #expect(onDisk.count == 2)
        #expect(!onDisk.contains(where: { $0.id == r2.id }))
    }

    @Test func testClearEmptiesAndPersists() throws {
        let history = DictationHistory(fileURL: fileURL)
        history.append(record("a", at: Date(timeIntervalSince1970: 1_000)))
        history.append(record("b", at: Date(timeIntervalSince1970: 2_000)))

        history.clear()

        #expect(history.all().isEmpty)

        // Reload from disk to confirm persistence.
        let reloaded = DictationHistory(fileURL: fileURL)
        #expect(reloaded.all().isEmpty)
    }

    @Test func testRetentionCapKeepsNewest1000() throws {
        let history = DictationHistory(fileURL: fileURL)
        let total = 1_005
        for i in 0..<total {
            history.append(record("item-\(i)", at: Date(timeIntervalSince1970: Double(i))))
        }

        // After inserting 1005 records the cap must have trimmed to 1000.
        #expect(history.all().count == 1_000)

        // The surviving records should be the newest ones (highest timestamps).
        // The oldest surviving record was appended at index (total - 1000) = 5,
        // which means its text is "item-5" but in newest-first order it is last.
        let all = history.all()
        #expect(all.last?.text == "item-5")
        #expect(all.first?.text == "item-\(total - 1)")

        // Reload and verify the cap survived persistence.
        let reloaded = DictationHistory(fileURL: fileURL)
        #expect(reloaded.all().count == 1_000)
    }
}
