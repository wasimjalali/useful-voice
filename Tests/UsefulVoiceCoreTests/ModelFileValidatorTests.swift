import Foundation
import Testing
@testable import UsefulVoiceCore

@Suite("Model file validation")
struct ModelFileValidatorTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-validator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ bytes: [UInt8], at url: URL) throws {
        try Data(bytes).write(to: url)
    }

    private func modelFile(lmggMagic: Bool = true, size: Int) throws -> URL {
        let dir = try tempDir()
        // "lmgg" is the real on-disk magic of ggml-*.bin (u32 "ggml", little
        // endian); the alternate branch writes the GGUF container magic.
        var bytes = lmggMagic ? [UInt8]([0x6C, 0x6D, 0x67, 0x67]) : [UInt8]([0x47, 0x47, 0x55, 0x46])
        if size > bytes.count {
            bytes += [UInt8](repeating: 0, count: size - bytes.count)
        }
        let url = dir.appendingPathComponent("ggml-test.bin")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func missingFileReportsMissing() throws {
        let url = try tempDir().appendingPathComponent("absent.bin")
        #expect(ModelFileValidator.validate(fileURL: url, expectedBytes: 100) == .missing)
    }

    @Test func validFilePasses() throws {
        let url = try modelFile(size: 1_000)
        #expect(ModelFileValidator.validate(fileURL: url, expectedBytes: 1_000) == .valid)
    }

    @Test func truncatedFileReportsWrongSize() throws {
        let url = try modelFile(size: 500)
        #expect(ModelFileValidator.validate(fileURL: url, expectedBytes: 1_000)
                == .wrongSize(expected: 1_000, actual: 500))
    }

    @Test func htmlErrorPageReportsBadMagic() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("ggml-test.bin")
        var bytes = [UInt8]("<html>404</html>".utf8)
        bytes += [UInt8](repeating: 0, count: 1_000 - bytes.count)
        try Data(bytes).write(to: url)
        #expect(ModelFileValidator.validate(fileURL: url, expectedBytes: 1_000) == .badMagic)
    }

    @Test func ggufMagicIsAccepted() throws {
        let url = try modelFile(lmggMagic: false, size: 1_000)
        #expect(ModelFileValidator.validate(fileURL: url, expectedBytes: 1_000) == .valid)
    }

    @Test func asciiGgmlMagicIsAccepted() throws {
        let dir = try tempDir()
        var bytes = [UInt8]([0x67, 0x67, 0x6D, 0x6C]) // "ggml"
        bytes += [UInt8](repeating: 0, count: 1_000 - bytes.count)
        let url = dir.appendingPathComponent("ggml-test.bin")
        try Data(bytes).write(to: url)
        #expect(ModelFileValidator.validate(fileURL: url, expectedBytes: 1_000) == .valid)
    }

    @Test func catalogModelsHaveConsistentMetadata() {
        for model in WhisperModelCatalog.all {
            #expect(model.expectedBytes > 0)
            #expect(model.sha256.count == 64)
            #expect(model.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            #expect(model.downloadURL.host == "huggingface.co")
            #expect(model.downloadURL.lastPathComponent == model.fileName)
            #expect(model.languageCount == 99)
        }
        // The recommendation is the turbo model: the larger model must never be
        // the default, because it needs roughly twice the memory.
        #expect(WhisperModelCatalog.default.id == WhisperModelCatalog.largeV3Turbo.id)
        #expect(WhisperModelCatalog.largeV3Turbo.isRecommended)
        #expect(!WhisperModelCatalog.largeV3.isRecommended)
        // IDs are unique and resolvable.
        #expect(Set(WhisperModelCatalog.all.map(\.id)).count == WhisperModelCatalog.all.count)
        #expect(WhisperModelCatalog.model(forID: "whisper-large-v3")?.fileName == "ggml-large-v3.bin")
        #expect(WhisperModelCatalog.model(forID: "nope") == nil)
    }

    @Test func sha256MatchesKnownContent() throws {
        let url = try tempDir().appendingPathComponent("data.bin")
        try Data("hello".utf8).write(to: url)
        #expect(try ModelFileValidator.sha256(fileURL: url)
                == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    /// A catalog-shaped model small enough to build on disk in a test; its
    /// pinned digest is deliberately not the digest of anything we write.
    private func smallModel(size: Int) -> WhisperModel {
        WhisperModel(
            id: "test-model", displayName: "Test Model", fileName: "ggml-test.bin",
            downloadURL: URL(string: "https://huggingface.co/test/ggml-test.bin")!,
            expectedBytes: Int64(size), sha256: String(repeating: "0", count: 64),
            parameterCount: "1M", licenseName: "MIT",
            licenseURL: URL(string: "https://opensource.org/license/mit")!,
            provenanceURL: URL(string: "https://huggingface.co/test")!,
            languageCount: 99, isRecommended: false, note: nil)
    }

    @Test func rightSizeAndMagicWithWrongContentFailsChecksum() throws {
        let url = try modelFile(size: 1_000)
        #expect(ModelFileValidator.validate(fileURL: url, expectedBytes: 1_000) == .valid)
        #expect(ModelFileValidator.validateAfterDownload(fileURL: url, model: smallModel(size: 1_000))
                == .checksumMismatch)
    }

    @Test func activatingABadFileLeavesNothingAtTheDestination() throws {
        let dir = try tempDir()
        let store = LocalModelStore(directory: dir)
        let model = smallModel(size: 1_000)
        var bytes = [UInt8]([0x6C, 0x6D, 0x67, 0x67])
        bytes += [UInt8](repeating: 7, count: 1_000 - bytes.count)
        try Data(bytes).write(to: store.partialURL(for: model))

        #expect(throws: ModelStoreError.validationFailed("checksum mismatch")) {
            try store.activateDownloadedFile(for: model)
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: model).path))
        #expect(!FileManager.default.fileExists(atPath: store.partialURL(for: model).path))
        #expect(store.availability(of: model) == .missing)
    }

    @Test func deletingAModelThatIsNotOnDiskDoesNotThrow() throws {
        let store = LocalModelStore(directory: try tempDir())
        try store.delete(smallModel(size: 1_000))
    }
}
