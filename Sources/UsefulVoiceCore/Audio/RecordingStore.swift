import Foundation

/// Owns the recordings directory. Audio is retained until transcription
/// succeeds; the newest N recordings are kept for retry/debugging (spec 5).
public struct RecordingStore {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
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
