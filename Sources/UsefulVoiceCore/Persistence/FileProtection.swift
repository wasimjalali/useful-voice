import Foundation

/// Restricts a file or directory to its owner.
///
/// Why this is needed: the app's data directory is created with the process
/// umask, which is `022` on a default macOS install. That produces `0755`
/// directories and `0644` files — **readable by every other user account on the
/// machine**. On a shared or managed Mac, another account could read the
/// dictionary, the full dictation history, and the retained audio recordings.
///
/// The parent `~/Library/Application Support` is `0700`, so a standard single-user
/// Mac is not actually exposed. But relying on a permission set by the OS, on a
/// directory the app does not own, is not a guarantee — it is a coincidence that
/// happens to hold on the machines tested so far. This makes the guarantee ours.
///
/// Design choices:
///
///   * **Applied at launch, and after creating anything.** Permissions are also
///     re-asserted on startup, so a directory that was created by an older build
///     (or restored from a backup, which does not preserve modes) is corrected
///     rather than left open forever.
///   * **Failures are reported, never fatal.** Hardening is a security
///     improvement, not a precondition for the app working. A read-only or
///     managed volume must not stop dictation.
///   * **Owner-only, not "more restrictive than before".** `0600`/`0700` exactly.
///     An earlier attempt might reasonably use `.posixPermissions` masks, but
///     setting an absolute mode is what actually removes the exposure; masking
///     can leave bits set that were never ours to leave.
public enum FileProtection {
    /// Owner read/write only, for files: `0600`.
    public static let fileMode: NSNumber = 0o600
    /// Owner read/write/execute only, for directories: `0700`.
    public static let directoryMode: NSNumber = 0o700

    /// Tighten `url` to owner-only access.
    ///
    /// - Parameter isDirectory: pass `nil` to detect, or the known kind to skip a
    ///   stat call.
    /// - Returns: `true` when the mode was applied (or already correct).
    @discardableResult
    public static func restrict(_ url: URL, isDirectory: Bool? = nil) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return false }

        let directory = isDirectory ?? isDirectoryAt(url)
        let mode = directory ? directoryMode : fileMode

        do {
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            return true
        } catch {
            // Reported rather than fatal: see the type comment.
            Diagnostics.shared.failure(
                "file-protection",
                error,
                context: "could not restrict \(url.lastPathComponent) to owner-only",
            )
            return false
        }
    }

    /// Tighten a directory and everything inside it, recursively.
    ///
    /// Used at launch over the data directory so files written by an earlier
    /// build are corrected too.
    public static func restrictRecursively(_ url: URL) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }

        restrict(url, isDirectory: isDirectory.boolValue)
        guard isDirectory.boolValue else { return }

        let contents = (try? manager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        for child in contents {
            restrictRecursively(child)
        }
    }

    private static func isDirectoryAt(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }
}
