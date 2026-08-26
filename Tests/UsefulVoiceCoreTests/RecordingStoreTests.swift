import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite final class RecordingStoreTests {
    private let dir: URL
    private let store: RecordingStore

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recstore-\(UUID().uuidString)")
        store = try RecordingStore(directory: dir)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func testNewRecordingURLsAreSortableAndUnique() throws {
        let a = store.newRecordingURL(date: Date(timeIntervalSince1970: 1_000))
        let b = store.newRecordingURL(date: Date(timeIntervalSince1970: 2_000))
        #expect(a != b)
        #expect(a.lastPathComponent < b.lastPathComponent)
        #expect(a.pathExtension == "wav")
    }

    @Test func testSaveTranscriptSidecar() throws {
        let audio = store.newRecordingURL(date: Date())
        try Data([0x00]).write(to: audio)
        try store.saveTranscript("hello world", for: audio)
        let sidecar = audio.deletingPathExtension().appendingPathExtension("txt")
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "hello world")
    }

    @Test func testPruneKeepsNewestN() throws {
        for i in 0..<5 {
            let url = store.newRecordingURL(date: Date(timeIntervalSince1970: Double(i * 100)))
            try Data([0x00]).write(to: url)
        }
        try store.prune(keep: 2)
        let remaining = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
        #expect(remaining.count == 2)
        let names = remaining.map(\.lastPathComponent).sorted()
        #expect(names.allSatisfy { $0 >= "1970-01-01T00-05-00" })
    }
}
