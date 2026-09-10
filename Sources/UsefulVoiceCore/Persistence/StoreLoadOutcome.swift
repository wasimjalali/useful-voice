import Foundation

/// How a store's backing file was read at launch.
///
/// The stores previously expressed this as `try? Data(contentsOf:)`, which
/// collapsed four genuinely different situations into one:
///
///   * no file yet (a first run — nothing is wrong),
///   * a file that could not be read at all (permissions, a lock, an I/O error),
///   * a file whose contents do not decode (corruption), and
///   * a file that was read and decoded.
///
/// Treating all of them as "empty" was not merely a lost error message. The store
/// started empty and the very next mutation wrote that emptiness back over the
/// intact file, so one transient read error at launch became permanent, silent
/// data loss. This type keeps the distinction so a store can refuse to overwrite
/// data it never managed to read.
public enum StoreLoadOutcome: Equatable {
    /// The file does not exist yet. Safe to write: there is nothing to destroy.
    case fresh
    /// The file was read and decoded.
    case loaded
    /// The file exists but could not be read. NOT safe to write.
    case unreadable(String)
    /// The file was read but does not decode. `backupURL` is where the original
    /// was preserved, when it could be preserved.
    case corrupt(backupURL: URL?)
    /// The file declares a schema version this build does not understand. NOT
    /// safe to write: a newer build owns this file.
    case incompatible(version: Int)

    /// Whether writing is safe without risking data that was never read.
    public var allowsWriting: Bool {
        switch self {
        case .fresh, .loaded: return true
        case .unreadable, .corrupt, .incompatible: return false
        }
    }

    /// A message suitable for showing to the user, or nil when nothing is wrong.
    public var userFacingMessage: String? {
        switch self {
        case .fresh, .loaded:
            return nil
        case .unreadable(let reason):
            return "Some saved data could not be read (\(reason)). Changes are not being saved "
                 + "so nothing is lost. Check that the folder is accessible, then restart the app."
        case .corrupt(let backupURL):
            if let backupURL {
                return "Some saved data was unreadable and has been set aside at "
                     + "\(backupURL.lastPathComponent). Changes are not being saved yet so the "
                     + "original is preserved. You can restore it from that file."
            }
            return "Some saved data was unreadable and could not be moved aside. Changes are not "
                 + "being saved so nothing is lost. Check the folder's permissions."
        case .incompatible(let version):
            return "This data was written by a newer version of Useful Voice (format \(version)). "
                 + "Update the app to see it. Changes are not being saved so it is not overwritten."
        }
    }
}

/// Reads a store's backing file and classifies the result.
///
/// Shared so that every store — dictionary, snippets, language memory, history —
/// makes the same distinction and cannot drift back into "silently empty".
public enum StoreFileReader {
    /// Read and decode `fileURL`.
    ///
    /// - Parameter decode: turns raw bytes into a value, or throws.
    /// - Parameter version: optional schema version reported by the file, used to
    ///   refuse files from a newer build.
    /// - Parameter diagnostics: where failures are recorded. **Injectable on
    ///   purpose.** Every store routes through this function, so hardcoding
    ///   `Diagnostics.shared` here meant any test that exercised a failing read
    ///   wrote into the developer's real `~/Library/Application Support/Sadaa/
    ///   diagnostics.log` — 186 entries of test fixtures landed in a live install's
    ///   log, which would have made that log actively misleading to debug against.
    ///   Tests pass their own instance; production takes the shared one.
    public static func load<T>(
        from fileURL: URL,
        version: (T) -> Int? = { _ in nil },
        supportedVersion: Int? = nil,
        diagnostics: Diagnostics = .shared,
        decode: (Data) throws -> T
    ) -> (outcome: StoreLoadOutcome, value: T?) {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError {
            // Only a genuinely absent file is a clean start. Everything else means
            // there may be data we failed to read, so writing must be refused.
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError {
                return (.fresh, nil)
            }
            // A directory or a file we cannot read reports a different code; both
            // are real failures, not a fresh start.
            //
            // Recorded here rather than at each call site: every store routes
            // through this function, so this is the one place a read failure can
            // be logged without the risk of a store forgetting to.
            diagnostics.failure(
                "store",
                error,
                context: "reading \(fileURL.lastPathComponent)",
            )
            return (.unreadable(error.localizedDescription), nil)
        }

        do {
            let value = try decode(data)
            if let supportedVersion, let fileVersion = version(value), fileVersion > supportedVersion {
                diagnostics.error(
                    "store",
                    "\(fileURL.lastPathComponent) is version \(fileVersion), newer than the supported version \(supportedVersion); writing is refused to avoid discarding newer fields",
                )
                return (.incompatible(version: fileVersion), nil)
            }
            return (.loaded, value)
        } catch {
            // Preserve the unreadable original before reporting. Move, never copy:
            // moving cannot fail for lack of space, and the original is no longer
            // usable in place.
            let backup = quarantine(fileURL)
            diagnostics.error(
                "store",
                "\(fileURL.lastPathComponent) could not be decoded (\(error.localizedDescription)); "
                    + (backup.map { "moved aside to \($0.lastPathComponent)" } ?? "could not be moved aside"),
            )
            return (.corrupt(backupURL: backup), nil)
        }
    }

    /// Move an undecodable file aside so the original is never overwritten.
    ///
    /// Prefers the plain `.bak` name, which is what users of earlier versions
    /// already have and what the app tells them to look for. Only if a backup
    /// already exists (so moving onto it would destroy the earlier one) does it
    /// fall back to a timestamped name.
    public static func quarantine(_ fileURL: URL) -> URL? {
        let plainBackup = fileURL.appendingPathExtension("bak")
        if !FileManager.default.fileExists(atPath: plainBackup.path) {
            do {
                try FileManager.default.moveItem(at: fileURL, to: plainBackup)
                return plainBackup
            } catch {
                // Fall through to a timestamped name.
            }
        }

        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let stamped = fileURL.appendingPathExtension("corrupt-\(stamp)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: stamped)
            return stamped
        } catch {
            return nil
        }
    }
}

/// A store that reports its failures instead of discarding them.
///
/// Both halves matter and they are different failures:
///
///   * **Write failures** were reported nowhere. `try? data.write(…)` discarded the
///     error, so a full disk or a permissions problem produced a UI that said
///     "Saved" while nothing reached disk.
///   * **Read failures** were discarded at launch, which as described on
///     `StoreLoadOutcome` turned into permanent overwrite of intact data.
public protocol StoreFailureReporting: AnyObject {
    /// The last write failure, cleared by a successful write.
    var lastSaveError: String? { get }
    /// The load problem from launch, if any. Persists for the session.
    var loadOutcome: StoreLoadOutcome { get }
    /// Register a callback invoked on every write failure.
    func onSaveFailure(_ handler: @escaping (String) -> Void)
    /// Clear the reported write failure (the UI acknowledging it).
    func clearSaveError()
}

/// Shared implementation of the failure-reporting contract.
///
/// Composed into each store rather than inherited, because the stores are
/// `final class`es with `Sendable`-free, main-actor use and a shared base class
/// would change their type relationships for no benefit.
public final class StoreFailureReporter {
    private var saveError: String?
    private var handlers: [(String) -> Void] = []
    private let label: String
    /// Injectable for the same reason as `StoreFileReader.load`: otherwise tests
    /// write their fixtures into the real install's log.
    private let diagnostics: Diagnostics

    public init(label: String, diagnostics: Diagnostics = .shared) {
        self.label = label
        self.diagnostics = diagnostics
    }

    public var lastSaveError: String? { saveError }

    public func onSaveFailure(_ handler: @escaping (String) -> Void) {
        handlers.append(handler)
    }

    public func clearSaveError() {
        saveError = nil
    }

    /// Record a write failure and notify every listener.
    public func reportSaveFailure(_ error: Error) {
        // Logged as well as reported to the UI. The UI message is transient and
        // gone the moment the user dismisses it; the log is what answers "why did
        // my dictionary stop saving" days later.
        diagnostics.failure("store", error, context: "\(label) could not be saved")
        let message = "\(label) could not be saved: \(error.localizedDescription)"
        saveError = message
        for handler in handlers {
            handler(message)
        }
    }

    /// Record a write failure described by a string.
    public func reportSaveFailure(_ message: String) {
        diagnostics.error("store", "\(label) could not be saved: \(message)")
        let text = "\(label) could not be saved: \(message)"
        saveError = text
        for handler in handlers {
            handler(text)
        }
    }

    /// Record a successful write.
    public func reportSaveSuccess() {
        saveError = nil
    }
}
