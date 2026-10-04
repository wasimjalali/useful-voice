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

    public static func isForced(environment: [String: String]) -> Bool {
        environment[forceVariable] == "force"
    }
}
