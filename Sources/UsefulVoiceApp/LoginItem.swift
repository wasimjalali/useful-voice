import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService for launch-at-login. Spec section 4 / 8.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app as a login item. Throws so the caller
    /// can surface failure instead of silently swallowing it.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
