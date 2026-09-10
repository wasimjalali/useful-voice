import AppKit
import ServiceManagement
import UsefulVoiceCore

/// Headless maintenance flags, used by the install/uninstall scripts.
///
/// `uninstall.sh` must turn off launch-at-login *while the bundle still exists*,
/// because `SMAppService` unregisters the calling bundle. Doing it here keeps
/// that logic next to the only code that knows how to talk to the service,
/// instead of duplicating it in a shell script.
@MainActor
private func runMaintenanceFlagIfPresent() -> Bool {
    let args = CommandLine.arguments
    if args.contains("--disable-login-item") {
        do {
            if SMAppService.mainApp.status == .enabled
                || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
                FileHandle.standardOutput.write(Data("login item disabled\n".utf8))
            } else {
                FileHandle.standardOutput.write(Data("login item not registered\n".utf8))
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data("could not disable login item: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    if args.contains("--version") {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        FileHandle.standardOutput.write(
            Data("Useful Voice \(version ?? "dev") (\(build ?? "0"))\n".utf8))
        exit(0)
    }
    return false
}

MainActor.assumeIsolated {
    _ = runMaintenanceFlagIfPresent()
    UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
