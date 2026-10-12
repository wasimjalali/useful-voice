import Foundation

/// Finds the retained recording for a history record.
///
/// `history.json` stores the ABSOLUTE path of each recording. After the data
/// folder was renamed (`Sadaa/Recordings/x.wav` -> `UsefulVoice/Recordings/x.wav`)
/// every stored path of an existing user points at a folder that no longer exists,
/// so Retry and Correct would silently lose their audio. This resolves the path at
/// read time instead of rewriting the user's history.
public enum RecordingLocator {
    /// The file to read for `storedPath`, or `nil` when it is gone.
    ///
    /// The stored path wins when it still exists. Otherwise only the file NAME is
    /// used, looked up directly inside `recordingsDirectory`: nothing from the
    /// stored path's folders is followed, so a stored path cannot reach outside it.
    public static func resolve(
        storedPath: String,
        recordingsDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        func isFile(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        if isFile(storedPath) {
            return URL(fileURLWithPath: storedPath)
        }
        let name = (storedPath as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        let candidate = recordingsDirectory.appendingPathComponent(name, isDirectory: false)
        // Belt and braces: the candidate must sit directly in the recordings folder.
        guard candidate.deletingLastPathComponent().standardizedFileURL.path
                == recordingsDirectory.standardizedFileURL.path,
              isFile(candidate.path) else { return nil }
        return candidate
    }
}
