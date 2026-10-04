import Foundation

/// New installs dictate in English, but an install that predates that default
/// was on Auto-detect and must stay there. Pure: the caller reads the system
/// state and passes it in.
public enum LanguageDefault {
    /// `UserDefaults` key set once the default has been settled for this install.
    public static let resolvedKey = "uv.languageDefaultResolved"

    public enum Outcome: Equatable, Sendable {
        /// Already settled on an earlier launch, or the user has a saved choice.
        case nothing
        /// A new install: record that it was settled, leave the English default.
        case markResolved
        /// An existing install with no saved pin: write Auto once, then record it.
        case writeAutoAndMarkResolved
    }

    /// - Parameters:
    ///   - alreadyResolved: the `resolvedKey` flag.
    ///   - storedPin: the saved `languagePin` string, nil when never saved.
    ///   - existingInstall: the app left any trace of earlier use (a saved
    ///     setting, history, usage stats or a Deepgram key).
    public static func outcome(alreadyResolved: Bool,
                               storedPin: String?,
                               existingInstall: Bool) -> Outcome {
        if alreadyResolved { return .nothing }
        if storedPin != nil { return .markResolved }
        return existingInstall ? .writeAutoAndMarkResolved : .markResolved
    }
}
