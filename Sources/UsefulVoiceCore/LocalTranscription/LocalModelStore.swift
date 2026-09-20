import Foundation

/// What the model directory says about one model.
public enum LocalModelAvailability: Equatable, Sendable {
    /// Downloaded, size and magic verified — safe to hand to the engine.
    case usable
    /// Not on disk (a partial download file does not count).
    case missing
    /// On disk but failed validation, with a human-readable reason.
    case invalid(String)
}

/// Owns the on-disk model weights directory.
///
/// Weights live at `~/Library/Application Support/UsefulVoice/models/` — a
/// directory of their own rather than inside the `Sadaa` data directory,
/// because they are large, public, re-downloadable artifacts: they are not
/// user data, should not be swept up in a data export, and should not inflate
/// a backup. Owner-only permissions are applied anyway, matching the rest of
/// the app's hardening.
///
/// Layout:
///   models/ggml-large-v3-turbo.bin          — the activated weights
///   models/ggml-large-v3-turbo.bin.partial  — an in-flight or paused download
///   models/ggml-large-v3-turbo.bin.resume   — URLSession resume data
public final class LocalModelStore: @unchecked Sendable {
    public let directory: URL
    private let fileManager: FileManager

    /// `~/Library/Application Support/UsefulVoice/models`
    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsefulVoice", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    public init(directory: URL = LocalModelStore.defaultDirectory,
                fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// Creates the directory (owner-only) if needed. Idempotent and safe on
    /// every launch.
    public func prepare() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        FileProtection.restrictRecursively(directory)
    }

    public func fileURL(for model: WhisperModel) -> URL {
        directory.appendingPathComponent(model.fileName)
    }

    /// Where an in-flight download is staged before validation.
    public func partialURL(for model: WhisperModel) -> URL {
        fileURL(for: model).appendingPathExtension("partial")
    }

    /// Where URLSession resume data is persisted between attempts.
    public func resumeDataURL(for model: WhisperModel) -> URL {
        fileURL(for: model).appendingPathExtension("resume")
    }

    /// Whether the model is ready for the engine. A file that fails validation
    /// is reported but never treated as usable.
    public func availability(of model: WhisperModel) -> LocalModelAvailability {
        switch ModelFileValidator.validate(fileURL: fileURL(for: model),
                                           expectedBytes: model.expectedBytes) {
        case .valid:
            return .usable
        case .missing:
            return .missing
        case .wrongSize(let expected, let actual):
            return .invalid("incomplete download (\(actual) of \(expected) bytes)")
        case .badMagic:
            return .invalid("file is not a model (bad header)")
        case .checksumMismatch:
            return .invalid("checksum mismatch")
        }
    }

    /// Bytes the model currently occupies on disk, nil when absent.
    public func installedBytes(for model: WhisperModel) -> Int64? {
        let attrs = try? fileManager.attributesOfItem(atPath: fileURL(for: model).path)
        return attrs?[.size] as? Int64
    }

    /// Bytes a partial download has fetched so far, for resume UI.
    public func partialBytes(for model: WhisperModel) -> Int64 {
        let attrs = try? fileManager.attributesOfItem(atPath: partialURL(for: model).path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    /// Total bytes used by everything in the model directory.
    public func totalBytesOnDisk() -> Int64 {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for url in contents {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Promotes a fully downloaded `.partial` file to the live model file,
    /// after validating it. Throws rather than activate a file that fails
    /// validation, and removes the rejected file so it cannot confuse a later
    /// attempt or be loaded by accident.
    public func activateDownloadedFile(for model: WhisperModel) throws {
        let staged = partialURL(for: model)
        let result = ModelFileValidator.validateAfterDownload(fileURL: staged, model: model)
        guard result == .valid else {
            try? fileManager.removeItem(at: staged)
            throw ModelStoreError.validationFailed(Self.describe(result))
        }
        let destination = fileURL(for: model)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            throw ModelStoreError.activationFailed(error.localizedDescription)
        }
        FileProtection.restrict(destination, isDirectory: false)
        // A completed download has no resume data left to keep.
        try? fileManager.removeItem(at: resumeDataURL(for: model))
    }

    /// Deletes the model file and any leftover download artifacts.
    public func delete(_ model: WhisperModel) throws {
        try? fileManager.removeItem(at: fileURL(for: model))
        try? fileManager.removeItem(at: partialURL(for: model))
        try? fileManager.removeItem(at: resumeDataURL(for: model))
    }

    /// Drops resume state (the `.resume` blob and the `.partial` file) without
    /// touching an installed model. Used when a download is abandoned.
    public func clearDownloadState(for model: WhisperModel) {
        try? fileManager.removeItem(at: partialURL(for: model))
        try? fileManager.removeItem(at: resumeDataURL(for: model))
    }

    public func saveResumeData(_ data: Data, for model: WhisperModel) {
        try? data.write(to: resumeDataURL(for: model), options: .atomic)
        FileProtection.restrict(resumeDataURL(for: model), isDirectory: false)
    }

    public func resumeData(for model: WhisperModel) -> Data? {
        try? Data(contentsOf: resumeDataURL(for: model))
    }

    private static func describe(_ validation: ModelFileValidation) -> String {
        switch validation {
        case .valid: return "valid"
        case .missing: return "file missing"
        case .wrongSize(let expected, let actual):
            return "incomplete download (\(actual) of \(expected) bytes)"
        case .badMagic: return "file is not a model (bad header)"
        case .checksumMismatch: return "checksum mismatch"
        }
    }
}

public enum ModelStoreError: Error, Equatable {
    /// The downloaded bytes failed validation and were discarded.
    case validationFailed(String)
    /// The file validated but could not be moved into place.
    case activationFailed(String)
}
