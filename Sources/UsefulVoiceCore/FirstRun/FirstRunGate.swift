import Foundation

/// Decides whether the first-run flow opens at launch. Pure: the caller reads
/// the system state and passes it in, so every rule is unit-testable.
public enum FirstRunGate {
    /// `UserDefaults` key set once setup is finished (or was never needed).
    public static let completedKey = "uv.firstRunCompleted"
    /// `UserDefaults` key the identity migration sets when the previous identity
    /// had finished setup. macOS keys the Accessibility and Microphone grants to
    /// the bundle id, so the renamed app starts with none: while this is set, a
    /// finished setup is checked against the grants again instead of trusted.
    public static let recheckGrantsKey = "uv.firstRunRecheckGrants"
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

    /// `grantsNeedRecheck`: setup was finished under the previous identity (see
    /// `recheckGrantsKey`). It is treated as not finished yet, so the flow shows
    /// while a grant or the engine is missing and is marked done silently once
    /// everything is in place. A completed install without it is never walked
    /// through setup again, even if a permission is revoked later.
    public static func decide(completed: Bool,
                              engineConfigured: Bool,
                              microphoneAuthorized: Bool,
                              accessibilityTrusted: Bool,
                              forced: Bool,
                              grantsNeedRecheck: Bool = false) -> Decision {
        if forced { return .show }
        if completed && !grantsNeedRecheck { return .skip }
        if engineConfigured && microphoneAuthorized && accessibilityTrusted {
            return .skipAndMarkCompleted
        }
        return .show
    }

    /// Setup is done: Done, Finish, "Set up later", or a launch that found
    /// everything in place. Clears the recheck too, so the flow never comes back
    /// for the rename and the window banners take over for a missing grant.
    public static func recordCompleted(in defaults: UserDefaults) {
        defaults.set(true, forKey: completedKey)
        defaults.removeObject(forKey: recheckGrantsKey)
    }

    /// The flow is up only because the grants are checked again after the rename:
    /// setup itself was finished under the previous identity.
    public static func isRecheckOnly(completed: Bool, grantsNeedRecheck: Bool, forced: Bool) -> Bool {
        !forced && completed && grantsNeedRecheck
    }

    /// Whether the main window opens at launch. A launch the user asked for always
    /// opens it. A login-item or restored launch opens it only for a setup that was
    /// never finished; a recheck after the rename waits for the next time the user
    /// opens the window (the Windows gate's rule), so a missing grant never puts a
    /// window in front of their work at login.
    public static func opensWindowAtLaunch(flowActive: Bool, recheckOnly: Bool,
                                           userInitiated: Bool) -> Bool {
        if userInitiated { return true }
        return flowActive && !recheckOnly
    }

    /// Whether the flow is on screen at launch. Only then does it stand in for the
    /// launch permission requests and the "Accessibility access is off" pill. A
    /// recheck left behind a closed window at login is not, so the app asks and
    /// shows the pill (and the menu's fix item) as it does without setup.
    public static func flowOnScreenAtLaunch(flowActive: Bool, recheckOnly: Bool,
                                            userInitiated: Bool) -> Bool {
        flowActive && opensWindowAtLaunch(flowActive: flowActive, recheckOnly: recheckOnly,
                                          userInitiated: userInitiated)
    }

    /// Whether the app has a way to dictate without any further setup: a Deepgram
    /// key is stored (presence only, so a key that cannot be read right now still
    /// counts) or a local model file is usable. Never reads a cache, so a slow or
    /// failed Keychain read cannot make a configured user look unconfigured.
    public static func engineConfigured(keyStored: Bool, localModelUsable: Bool) -> Bool {
        keyStored || localModelUsable
    }

    /// The same rule for the engine the app is set to: a Deepgram engine needs a
    /// stored key, a local engine needs its ACTIVE model usable. Another model
    /// being downloaded does not count, because dictation would still fail.
    public static func engineConfigured(engine: TranscriptionEngineChoice,
                                        keyStored: Bool,
                                        activeModelUsable: Bool) -> Bool {
        engineConfigured(keyStored: engine == .deepgram && keyStored,
                         localModelUsable: engine == .whisperLocal && activeModelUsable)
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
