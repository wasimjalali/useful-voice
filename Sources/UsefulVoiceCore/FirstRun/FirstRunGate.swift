import Foundation

/// Decides whether the first-run flow opens at launch. Pure: the caller reads
/// the system state and passes it in, so every rule is unit-testable.
public enum FirstRunGate {
    /// `UserDefaults` key set once setup is finished (or was never needed).
    public static let completedKey = "uv.firstRunCompleted"
    /// Environment variable that forces the flow open without saving anything.
    public static let forceVariable = "UV_FIRST_RUN"

    public enum Decision: Equatable, Sendable {
        /// Open the flow at Welcome.
        case show
        /// Normal launch.
        case skip
        /// Normal launch, and record that setup is done: an existing user
        /// upgrading with everything already configured and granted.
        case skipAndMarkCompleted
    }

    public static func decide(completed: Bool,
                              engineConfigured: Bool,
                              microphoneAuthorized: Bool,
                              accessibilityTrusted: Bool,
                              forced: Bool) -> Decision {
        if forced { return .show }
        if completed { return .skip }
        if engineConfigured && microphoneAuthorized && accessibilityTrusted {
            return .skipAndMarkCompleted
        }
        return .show
    }

    /// Whether the app has a way to dictate without any further setup: a Deepgram
    /// key is stored (presence only, so a key that cannot be read right now still
    /// counts) or a local model file is usable. Never reads a cache, so a slow or
    /// failed Keychain read cannot make a configured user look unconfigured.
    public static func engineConfigured(keyStored: Bool, localModelUsable: Bool) -> Bool {
        keyStored || localModelUsable
    }

    /// The engine and local model the app was using when the flow opened.
    public struct EngineSelection: Equatable, Sendable {
        public let engine: TranscriptionEngineChoice
        public let modelID: String

        public init(engine: TranscriptionEngineChoice, modelID: String) {
            self.engine = engine
            self.modelID = modelID
        }
    }

    /// What the app should be set to when the flow ends without finishing
    /// (closed, cancelled, backed out): the current choice when it can already
    /// dictate, otherwise the one from before the flow opened, so nothing is
    /// left pointing at an engine or model that cannot work.
    public static func selectionAfterAbandon(snapshot: EngineSelection,
                                             current: EngineSelection,
                                             currentUsable: Bool) -> EngineSelection {
        currentUsable ? current : snapshot
    }

    public static func isForced(environment: [String: String]) -> Bool {
        environment[forceVariable] == "force"
    }
}
