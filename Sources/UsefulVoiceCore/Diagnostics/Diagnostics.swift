import Foundation

/// A bounded, privacy-preserving error log.
///
/// Why this exists: before it, every failure in this app lived for a few seconds
/// in a floating pill and then vanished. There was no `os_log`, no file, nothing
/// to look at. A user reporting "it just doesn't work sometimes" was
/// unanswerable, and an intermittent bug — a failed paste, a refused write, a
/// dropped keyterm — left no trace at all.
///
/// Two rules shape the design:
///
/// 1. **It must never hold a transcript or an API key.** This is a file that
///    outlives the dictation, and a dictation log is a surveillance log. Only
///    short diagnostic *descriptions* are recorded, never user content. Callers
///    pass error descriptions and codes; the API deliberately offers no
///    "record this text" entry point.
///
/// 2. **It must never block the caller.** The global CGEvent tap runs on the main
///    run loop, and macOS disables a tap that stalls; a synchronous file write on
///    that path could therefore break system-wide keyboard handling. Records are
///    enqueued and written by a background queue, and the in-memory ring buffer is
///    the source of truth for reading back.
public final class Diagnostics: @unchecked Sendable {
    public enum Level: String, Sendable, CaseIterable {
        case error
        case warning
        case info
    }

    public struct Entry: Sendable, Equatable {
        public let date: Date
        public let level: Level
        public let category: String
        public let message: String

        public init(date: Date, level: Level, category: String, message: String) {
            self.date = date
            self.level = level
            self.category = category
            self.message = message
        }
    }

    public static let shared = Diagnostics()

    /// How many entries are kept in memory for the UI to display.
    public static let memoryLimit = 200
    /// The log file is truncated to this size once it exceeds it, so it cannot
    /// grow without bound on a long-lived install.
    public static let fileByteLimit = 256 * 1024
    /// A single message is clipped to this length. Error descriptions can embed
    /// whole payloads; a truncated one is still diagnostic, a huge one is a
    /// privacy risk and a disk problem.
    public static let messageLimit = 400

    private let lock = NSLock()
    private var buffer: [Entry] = []
    private let queue = DispatchQueue(label: "ai.karko.sadaa.diagnostics", qos: .utility)
    private let directory: URL?
    private var fileURL: URL? { directory?.appendingPathComponent("diagnostics.log") }

    /// - Parameter directory: where the log file lives. `nil` disables file
    ///   output but keeps the in-memory buffer working, which is what the tests
    ///   use so they never touch the user's real log.
    public init(directory: URL? = Diagnostics.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Sadaa")
    }

    // MARK: - Recording

    public func error(_ category: String, _ message: String) {
        record(level: .error, category: category, message: message)
    }

    public func warning(_ category: String, _ message: String) {
        record(level: .warning, category: category, message: message)
    }

    public func info(_ category: String, _ message: String) {
        record(level: .info, category: category, message: message)
    }

    /// Records a failed `Error`.
    ///
    /// `NSError` is unwrapped into domain/code plus a description, because the
    /// code is what makes a report actionable and the description alone often is
    /// not (a bare "The operation couldn't be completed.").
    public func failure(_ category: String, _ error: Error, context: String? = nil) {
        let nsError = error as NSError
        var message = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        if let context, !context.isEmpty {
            message = "\(context) — \(message)"
        }
        record(level: .error, category: category, message: message)
    }

    public func record(level: Level, category: String, message: String) {
        let clipped = String(message.prefix(Self.messageLimit))
        let entry = Entry(date: Date(), level: level, category: category, message: clipped)

        lock.lock()
        buffer.append(entry)
        if buffer.count > Self.memoryLimit {
            buffer.removeFirst(buffer.count - Self.memoryLimit)
        }
        lock.unlock()

        // Off the caller's thread on purpose: see rule 2 in the type comment.
        queue.async { [weak self] in
            self?.append(entry)
        }
    }

    // MARK: - Reading

    /// The most recent entries, oldest first. Safe from any thread.
    public func entries(level: Level? = nil) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard let level else { return buffer }
        return buffer.filter { $0.level == level }
    }

    public func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        guard let fileURL else { return }
        queue.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// A plain-text report suitable for copying into a bug report.
    ///
    /// Deliberately built from the in-memory buffer rather than the file, so it
    /// works even when the file could not be written, and so it can never read
    /// back something that was pruned from memory.
    public func report() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return entries().map { entry in
            "\(formatter.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] \(entry.category): \(entry.message)"
        }
        .joined(separator: "\n")
    }

    // MARK: - File output

    /// Waits for queued writes to land. For tests and for the quit path.
    public func flush() {
        queue.sync {}
    }

    private func append(_ entry: Entry) {
        guard let fileURL, let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let line = "\(formatter.string(from: entry.date)) [\(entry.level.rawValue.uppercased())] \(entry.category): \(entry.message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            // Truncate rather than rotate: a single bounded file that always holds
            // the most recent history is more useful than a set of archives, and
            // it cannot fill the disk.
            if let size = try? handle.seekToEnd(), size > UInt64(Self.fileByteLimit) {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
