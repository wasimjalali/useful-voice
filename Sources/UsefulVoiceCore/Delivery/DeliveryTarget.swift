import Foundation

/// Where a hotkey dictation's text is meant to land, captured the moment the
/// hotkey is pressed.
///
/// The old code read the frontmost app again at formatting and delivery time,
/// after transcription. By then the user had often clicked into another composer,
/// and the text landed there: the "wrong composer" bug. The target is now locked
/// at the press and delivery aims at it, nowhere else.
///
/// Every field is optional: what can be read depends on the app (an AX-blind
/// Electron app exposes no focused element, a native app has no URL). A field the
/// capture could not read is simply not compared.
public struct DeliveryTarget: Equatable, Sendable {
    /// Bundle id on macOS, lowercased executable name (no `.exe`) on Windows.
    public let appID: String?
    /// The name shown to the user ("Slack").
    public let appName: String?
    /// The process. A relaunched app has a new one, so the old target is gone.
    public let processID: Int32?
    /// Identity of the window that had focus (an AX window hash, a window handle).
    public let windowID: String?
    /// Its title, for display and logs. Never compared: titles change as you type.
    public let windowTitle: String?
    /// Identity of the focused element (the composer) inside that window.
    public let elementID: String?
    /// The page address when the app is a known browser and it could be read.
    /// Held in memory for this dictation only, never logged or stored.
    public let browserURL: String?

    public init(appID: String?,
                appName: String? = nil,
                processID: Int32? = nil,
                windowID: String? = nil,
                windowTitle: String? = nil,
                elementID: String? = nil,
                browserURL: String? = nil) {
        self.appID = appID
        self.appName = appName
        self.processID = processID
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.elementID = elementID
        self.browserURL = browserURL
    }

    /// A target that knows only the app, for callers that read nothing more.
    public init(app: FrontmostApp) {
        self.init(appID: app.id, appName: app.name)
    }

    /// Whether anything identifies the app at all. A target with neither a
    /// process nor an app id cannot be told apart from any other window.
    public var isIdentified: Bool { processID != nil || appID != nil }
}

/// Why a hotkey dictation was copied instead of pasted into its target.
public enum TargetLossReason: Equatable, Sendable {
    /// No target was captured at the hotkey press, so there is nothing to aim at.
    case unknownTarget
    /// The target app quit (or was relaunched as a new process).
    case targetGone
    /// Focus moved and bringing the target back did not work, or brought back a
    /// different window or element.
    case notRestored
}

/// What delivery does about the target before inserting anything.
public enum TargetCheck: Equatable, Sendable {
    /// The target is in front with the same window and element: insert.
    case insert
    /// Focus moved but the target app is still running: bring it back, then check
    /// again with `TargetLock.recheck`.
    case reactivate
    /// Do not insert anywhere. The text goes on the clipboard and the user sees the
    /// existing "copied" notice.
    case copyOnly(TargetLossReason)
}

/// The pure rules that lock delivery onto the target captured at the hotkey press.
///
/// The app layer observes (what is in front now, is the target still running) and
/// acts (reactivates the target, pastes); this only decides. The invariant every
/// rule serves: text is never inserted into a window that is not the captured
/// target. When in doubt, the dictation is copied, which loses nothing.
public enum TargetLock {
    /// Whether `current` (what has focus now) is the captured target.
    ///
    /// - The app: the same process when both are known, else the same app id.
    /// - The window and the element: compared only when the target recorded one.
    ///   A target that recorded one and a current focus that cannot report it do
    ///   not match: the focus may be anywhere.
    public static func matches(_ target: DeliveryTarget, _ current: DeliveryTarget?) -> Bool {
        guard let current, target.isIdentified else { return false }
        if let pid = target.processID, let now = current.processID {
            guard pid == now else { return false }
        } else {
            guard let id = target.appID, id == current.appID else { return false }
        }
        if let window = target.windowID, window != current.windowID { return false }
        if let element = target.elementID, element != current.elementID { return false }
        return true
    }

    /// The first check at delivery.
    ///
    /// - Parameters:
    ///   - target: captured at the hotkey press, nil when it could not be read.
    ///   - current: what has focus now, nil when it could not be read.
    ///   - targetRunning: the target's process still exists.
    public static func check(target: DeliveryTarget?,
                             current: DeliveryTarget?,
                             targetRunning: Bool) -> TargetCheck {
        guard let target, target.isIdentified else { return .copyOnly(.unknownTarget) }
        if matches(target, current) { return .insert }
        guard targetRunning else { return .copyOnly(.targetGone) }
        return .reactivate
    }

    /// The check after a reactivation attempt. Never asks to reactivate again: one
    /// attempt, then copy, so delivery cannot loop or fight the user for focus.
    ///
    /// - Parameters:
    ///   - reactivated: the app layer reports the target came to the front.
    ///   - current: what has focus after the attempt.
    public static func recheck(target: DeliveryTarget?,
                               current: DeliveryTarget?,
                               reactivated: Bool) -> TargetCheck {
        guard let target, target.isIdentified else { return .copyOnly(.unknownTarget) }
        guard reactivated, matches(target, current) else { return .copyOnly(.notRestored) }
        return .insert
    }
}
