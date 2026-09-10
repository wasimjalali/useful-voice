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

    public init(fileURL: URL, diagnostics: Diagnostics = .shared) {
        self.fileURL = fileURL

        let loaded = StoreFileReader.load(from: fileURL, diagnostics: diagnostics) { data in
            try DictationHistory.makeDecoder().decode([DictationRecord].self, from: data)
        }
        self.records = loaded.value ?? []
        self.outcome = loaded.outcome
        self.isWritable = loaded.outcome.allowsWriting
    }

    // Maximum number of records kept in memory and on disk.
    private let retentionCap = 1_000

    private let failures = StoreFailureReporter(label: "History")
    private let outcome: StoreLoadOutcome
    private var isWritable: Bool

    /// Whether the file could be read at launch, and why not if it could not.
    public var loadOutcome: StoreLoadOutcome { outcome }

    /// The last write failure, or nil. Drives the UI's save indicator.
    public var lastSaveError: String? { failures.lastSaveError }

    /// Called on every write failure.
    public func onSaveFailure(_ handler: @escaping (String) -> Void) {
        failures.onSaveFailure(handler)
    }

    public func clearSaveError() {
        failures.clearSaveError()
    }

    /// Insert newest-first, enforce the retention cap, then persist.
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

    /// Persist the current state, reporting rather than swallowing any failure.
    @discardableResult
    public func persist() -> Bool {
        guard isWritable else {
            // The file exists but was never read. Writing now would replace records
            // we do not have, so refuse and keep the problem visible.
            failures.reportSaveFailure(
                "not saving: \(loadOutcome.userFacingMessage ?? "the existing file could not be read")")
            return false
        }
        do {
            let data = try DictationHistory.makeEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
            failures.reportSaveSuccess()
            return true
        } catch {
            failures.reportSaveFailure(error)
            return false
        }
    }

    /// Allow writing again, after the user has resolved a launch-time read problem.
    public func allowWritingAgain() {
        isWritable = true
        failures.clearSaveError()
    }
}
