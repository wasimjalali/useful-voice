import Foundation

/// Finds the retained recording for a history record.
///
/// `history.json` stores the ABSOLUTE path of each recording. After the data
/// folder was renamed (the old folder's `Recordings/x.wav` -> `UsefulVoice/Recordings/x.wav`)
/// every stored path of an existing user points at a folder that no longer exists,
/// so Retry and Correct would silently lose their audio. This resolves the path at
/// read time instead of rewriting the user's history.
public enum RecordingLocator {
    /// The file to read for `storedPath`, or `nil` when it is gone.
    ///
    /// A stored path is trusted only when it is a file directly inside the current
    /// recordings folder or the previous identity's one: history.json is user data
    /// and its paths must not make the app read arbitrary files. Anything else
    /// falls back to the file NAME looked up directly inside `recordingsDirectory`,
    /// so nothing from the stored path's folders is followed.
    public static func resolve(
        storedPath: String,
        recordingsDirectory: URL,
        legacyRecordingsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        func isFile(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        func normal(_ url: URL) -> String { url.standardizedFileURL.path }

        let stored = URL(fileURLWithPath: storedPath)
        let parent = normal(stored.deletingLastPathComponent())
        let trusted = [recordingsDirectory, legacyRecordingsDirectory].compactMap { $0 }.map(normal)
        if trusted.contains(parent), isFile(stored.standardizedFileURL.path) {
            return stored.standardizedFileURL
        }

        let name = stored.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        let candidate = recordingsDirectory.appendingPathComponent(name, isDirectory: false)
        // Belt and braces: the candidate must sit directly in the recordings folder.
        guard normal(candidate.deletingLastPathComponent()) == normal(recordingsDirectory),
              isFile(candidate.path) else { return nil }
        return candidate
    }
}
