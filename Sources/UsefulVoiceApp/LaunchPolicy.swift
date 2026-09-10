import AppKit

/// Why the process was started, used to decide whether opening the main window
/// is wanted.
///
/// Useful Voice is a menu-bar utility (`LSUIElement`), and it offers "Launch at
/// login". Before this existed, `applicationDidFinishLaunching` unconditionally
/// opened a ~1080x720 window and called `activate(ignoringOtherApps: true)`, so
/// every login produced a window that took focus while the user was already
/// typing into another app — the first keystrokes went to the dictation app
/// instead. It also looked like malware to a first-time user.
enum LaunchReason {
    /// The user launched the app deliberately (Finder, Dock, `open`) — or asked
    /// for it by reopening a running instance. Show the window.
    case userInitiated
    /// The app was started by the system — a login item, a state restoration, or
    /// a Service / file-open request. Stay in the background as a menu-bar app;
    /// the hotkey and status item are the interface.
    case automatic

    /// Interprets `NSApplicationDidFinishLaunchingNotification`.
    ///
    /// AppKit documents `NSApplicationLaunchIsDefaultLaunchKey` as `false` when
    /// "the app launch was in some other sense not a 'default' launch". That is
    /// the signal we want: a user double-clicking the app, opening it from the
    /// Dock, or `open UsefulVoice.app` is a default launch, while a login item
    /// (and state restoration, a Service, or a file-open request) is not.
    ///
    /// A missing key means an older AppKit or a launch path that does not
    /// populate it, and is treated as user-initiated: showing the window
    /// unnecessarily is a much smaller failure than an app that appears to do
    /// nothing when launched. Reopening a running instance goes through
    /// `applicationShouldHandleReopen`, which shows the window regardless.
    static func current(from notification: Notification?) -> LaunchReason {
        let isDefault = (notification?.userInfo?[NSApplication.launchIsDefaultUserInfoKey]
            as? NSNumber)?.boolValue
        guard let isDefault else { return .userInitiated }
        return isDefault ? .userInitiated : .automatic
    }
}

/// Guarantees only one copy of the app is ever running.
///
/// Two copies of the same bundle id share a TCC grant and both install a
/// session-wide `flagsChanged` event tap, so a single hotkey press toggles
/// dictation twice: recording starts and immediately stops, nothing is
/// transcribed, and two HUD pills render. This is reachable in practice because
/// `make run` leaves a live bundle at `dist/` with the same bundle identifier
/// and signature as the `/Applications` copy, and the login item records
/// whichever copy was running when the user enabled it.
enum SingleInstance {
    /// The running copy that is NOT this process, if there is one.
    @MainActor
    static func otherInstance() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// Quits this process if another instance already owns the hotkey tap.
    ///
    /// Must run before any event tap is installed. Returns true when this
    /// process should give way (the caller must stop launching: the app is
    /// terminating).
    @MainActor
    @discardableResult
    static func yieldToExistingInstance() -> Bool {
        guard let other = otherInstance() else { return false }

        // Bring the instance the user already has to the front so their launch
        // action is not silently swallowed, then quit this duplicate.
        other.activate(options: [])
        // The duplicate is almost always the copy launched by the login item or
        // by a stale path, so it should not touch the user's clipboard or files.
        NSApp.terminate(nil)
        return true
    }
}
