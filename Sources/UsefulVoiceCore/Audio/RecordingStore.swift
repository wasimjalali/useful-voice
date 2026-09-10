import Foundation

/// Owns the recordings directory. Audio is retained until transcription
/// succeeds; the newest N recordings are kept for retry/debugging (spec 5).
public struct RecordingStore {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        // Recorded speech is the most sensitive thing this app writes. The
        // directory is created with the process umask (022 by default), which
        // would leave it world-readable; restrict it here so the protection
        // travels with the store rather than depending on the caller.
        FileProtection.restrict(directory, isDirectory: true)
    }

    /// Builds a store, falling back to a private temporary directory when the
    /// preferred location cannot be created (full disk, permissions, a managed
    /// Mac, a sandbox denial).
    ///
    /// Recording audio is ephemeral: it only has to survive until transcription
    /// completes. Losing the preferred directory should degrade audio retention,
    /// never prevent the app from launching, which is what a hard failure here
    /// used to do.
    public static func make(directory: URL) -> RecordingStore {
        if let store = try? RecordingStore(directory: directory) {
            return store
        }
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsefulVoice-Recordings", isDirectory: true)
        if let store = try? RecordingStore(directory: fallback) {
            return store
        }
        // Last resort: a non-throwing store whose directory may not exist.
        // Every write path tolerates a missing directory (writes are `try?`),
        // so the app stays usable even if audio can never be persisted.
        return RecordingStore(uncheckedDirectory: fallback)
    }

    private init(uncheckedDirectory: URL) {
        self.directory = uncheckedDirectory
    }

    public func newRecordingURL(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return directory
            .appendingPathComponent("\(formatter.string(from: date))")
            .appendingPathExtension("wav")
    }

    public func saveTranscript(_ text: String, for audio: URL) throws {
        let sidecar = audio.deletingPathExtension().appendingPathExtension("txt")
        try text.write(to: sidecar, atomically: true, encoding: .utf8)
        // A transcript is as sensitive as the audio next to it, and `write` applies
        // the umask like any other creation.
        FileProtection.restrict(sidecar, isDirectory: false)
    }

    public func prune(keep: Int) throws {
        let wavs = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // newest first
        for url in wavs.dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
            let sidecar = url.deletingPathExtension().appendingPathExtension("txt")
            try? FileManager.default.removeItem(at: sidecar)
        }
    }
}
