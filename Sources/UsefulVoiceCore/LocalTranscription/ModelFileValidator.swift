import CryptoKit
import Foundation

/// Outcome of checking a would-be model file on disk.
public enum ModelFileValidation: Equatable, Sendable {
    /// File exists, size matches the catalog, magic bytes look like a model.
    case valid
    /// No file at the path.
    case missing
    /// File is present but a different size than the catalog expects — almost
    /// always a truncated or replaced download.
    case wrongSize(expected: Int64, actual: Int64)
    /// Size matches but the first bytes are not a ggml/GGUF header, so it is not
    /// a model file whisper.cpp could load (an HTML error page, a renamed file).
    case badMagic
    /// The file's SHA-256 does not match the catalog's pinned digest.
    case checksumMismatch
}

/// Sanity checks for model weight files.
///
/// Validation is layered and deliberately cheap-first:
///   1. presence + exact byte size (free),
///   2. the 4-byte ggml/GGUF magic (one read),
///   3. full SHA-256 (expensive; run once after a download, not on every
///      dictation).
///
/// The whisper.cpp `.bin` format writes the magic `ggml` as a little-endian
/// u32, so the first four bytes on disk are `lmgg` — verified against the real
/// Hugging Face files. The newer GGUF container begins with the ASCII `GGUF`.
/// Anything else — an HTML error page from a proxy, a partial download, a
/// renamed text file — is rejected before the engine ever sees it, because
/// whisper.cpp aborts outright on a bad header rather than returning an error.
public enum ModelFileValidator {
    /// The magics whisper.cpp accepts: `lmgg` (the `ggml` u32 little-endian, as
    /// shipped in `ggml-*.bin`), the ASCII `ggml` spelling for safety, and the
    /// `GGUF` container magic.
    static let acceptedMagics: [Data] = [
        Data([0x6C, 0x6D, 0x67, 0x67]), // "lmgg" — ggml u32, little-endian
        Data([0x67, 0x67, 0x6D, 0x6C]), // "ggml" — ASCII spelling
        Data([0x47, 0x47, 0x55, 0x46]), // "GGUF"
    ]

    /// Fast validation: existence, exact size, magic bytes. `expectedBytes` is
    /// the catalog's size; passing nil skips the size check (not used by the
    /// app, but keeps the validator usable for ad-hoc files in tests).
    public static func validate(fileURL: URL, expectedBytes: Int64?) -> ModelFileValidation {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int64 else {
            return .missing
        }
        if let expectedBytes, size != expectedBytes {
            return .wrongSize(expected: expectedBytes, actual: size)
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return .missing
        }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 4)) ?? Data()
        guard acceptedMagics.contains(header) else {
            return .badMagic
        }
        return .valid
    }

    /// The streaming SHA-256 of a file, lowercase hex. Streams in chunks so a
    /// 3 GB model does not have to fit in memory to be hashed.
    public static func sha256(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 22), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Full validation used once, right after a download completes. Cheap checks
    /// first so a truncated file fails fast without hashing gigabytes.
    public static func validateAfterDownload(fileURL: URL, model: WhisperModel) -> ModelFileValidation {
        let quick = validate(fileURL: fileURL, expectedBytes: model.expectedBytes)
        guard quick == .valid else { return quick }
        do {
            let digest = try sha256(fileURL: fileURL)
            return digest == model.sha256 ? .valid : .checksumMismatch
        } catch {
            return .missing
        }
    }
}
