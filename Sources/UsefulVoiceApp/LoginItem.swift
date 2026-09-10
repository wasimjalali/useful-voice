import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService for launch-at-login. Spec section 4 / 8.
enum LoginItem {
    /// What the system currently thinks of our login item.
    ///
    /// `SMAppService.Status` has more than two cases and the app used to collapse
    /// them into "enabled or not". That produced a confusing state: when the user
    /// disables the item in System Settings, the status becomes
    /// `.requiresApproval` (the registration still exists and the system wants the
    /// user to approve it), so the toggle showed OFF while the item was in fact
    /// registered. Turning it ON then called `register()` on an
    /// already-registered item — the documented error path — and the user saw a
    /// generic failure with no hint that the real fix is to approve the item in
    /// System Settings.
    enum Status: Equatable {
        /// Registered and will run at login.
        case enabled
        /// Registered with the system, but the user must approve it in
        /// System Settings > General > Login Items.
        case requiresApproval
        /// Not registered.
        case disabled
        /// The system would not tell us (older OS, or a lookup failure).
        case unknown

        var isOn: Bool {
            switch self {
            case .enabled, .requiresApproval: return true
            case .disabled, .unknown: return false
            }
        }

        var needsUserApproval: Bool { self == .requiresApproval }
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .unknown
        }
    }

    static var isEnabled: Bool { status.isOn }

    /// Registers or unregisters the app as a login item. Throws so the caller
    /// can surface failure instead of silently swallowing it.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // Registering an already-registered item is an error; only a
            // not-registered item can be registered.
            guard SMAppService.mainApp.status == .notRegistered
                || SMAppService.mainApp.status == .notFound else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled
                || SMAppService.mainApp.status == .requiresApproval else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens the System Settings pane where the user can approve a pending
    /// registration. macOS provides no API to approve it programmatically, so
    /// this is the documented recovery path.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
