import Foundation

/// JSON-backed store of delivered dictations, kept newest-first in memory.
/// Used on the main thread; no locking. Never throws, never crashes.
public final class DictationHistory {
    private let fileURL: URL
    private var records: [DictationRecord]

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            records = try DictationHistory.makeDecoder().decode([DictationRecord].self, from: data)
        } catch {
            // Corrupt or unreadable file: move it aside (best-effort) and start empty.
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            records = []
        }
    }

    // Maximum number of records kept in memory and on disk.
    private let retentionCap = 1_000

    /// Insert newest-first, enforce the retention cap, then persist. Write failure is swallowed.
    public func append(_ record: DictationRecord) {
        records.insert(record, at: 0)
        if records.count > retentionCap {
            records = Array(records.prefix(retentionCap))
        }
        persist()
    }

    /// Remove the record with the given id and persist. No-op if id is not found.
    public func delete(id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    /// Remove all records and persist.
    public func clear() {
        records = []
        persist()
    }

    public func all() -> [DictationRecord] {
        records
    }

    public func recent(_ limit: Int) -> [DictationRecord] {
        Array(records.prefix(max(0, limit)))
    }

    public func search(_ query: String) -> [DictationRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        return records.filter {
            $0.text.range(of: trimmed, options: .caseInsensitive) != nil
        }
    }

    // MARK: - Private helpers

    private func persist() {
        if let data = try? DictationHistory.makeEncoder().encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
