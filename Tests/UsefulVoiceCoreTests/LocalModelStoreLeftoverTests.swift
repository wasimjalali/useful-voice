import Testing
import Foundation
@testable import UsefulVoiceCore

/// The hidden S1-mini cleanup model is gone, but a Mac that turned its flag on still
/// has the weights in the models folder.
@Suite final class LocalModelStoreLeftoverTests {
    private let dir: URL
    private let store: LocalModelStore

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = LocalModelStore(directory: dir)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, bytes: Int) throws {
        try Data(count: bytes).write(to: dir.appendingPathComponent(name))
    }

    @Test func totalBytesIgnoresTheLeftoverCleanupModel() throws {
        try write("ggml-large-v3-turbo.bin", bytes: 1_000)
        try write("s1-mini-q4_k_m.gguf", bytes: 5_000)
        try write("s1-mini-q4_k_m.gguf.partial", bytes: 700)
        try write("s1-mini-q4_k_m.gguf.resume", bytes: 30)
        #expect(store.totalBytesOnDisk() == 1_000)
    }

    @Test func removingTheLeftoverDeletesTheWeightsAndTheirPartialFiles() throws {
        try write("ggml-large-v3-turbo.bin", bytes: 1_000)
        try write("s1-mini-q4_k_m.gguf", bytes: 5_000)
        try write("s1-mini-q4_k_m.gguf.partial", bytes: 700)
        try write("s1-mini-q4_k_m.gguf.resume", bytes: 30)

        let removed = store.removeLegacyCleanupModel()

        #expect(Set(removed) == ["s1-mini-q4_k_m.gguf", "s1-mini-q4_k_m.gguf.partial",
                                 "s1-mini-q4_k_m.gguf.resume"])
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["ggml-large-v3-turbo.bin"])
    }

    @Test func removingWithNothingLeftoverDoesNothing() throws {
        try write("ggml-large-v3-turbo.bin", bytes: 1_000)
        #expect(store.removeLegacyCleanupModel().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }
}
