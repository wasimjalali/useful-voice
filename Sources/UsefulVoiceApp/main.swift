import AppKit
import ServiceManagement
import UsefulVoiceCore

// Works around a ggml-metal teardown bug in the whisper XCFramework: Metal
// residency sets keep freed buffers registered for a keep-alive window (180 s),
// and `ggml_metal_device_free` asserts the set is empty during static
// destruction at process exit, so quitting within 3 minutes of a local
// transcription would abort with SIGABRT. Disabling residency sets avoids the
// assert. Set here, once, before any thread exists (setenv is not thread safe),
// and without overwrite so a user's explicit environment still wins.
setenv("GGML_METAL_NO_RESIDENCY", "1", 0)

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

    // The one-time move from the previous app identity (data folder, preferences,
    // Keychain key). It runs here, before the delegate exists and before anything
    // reads the data folder, the preferences or the key store. A render or a forced
    // first run never migrates.
    let environment = ProcessInfo.processInfo.environment
    if LaunchMode.migrateOnlyConflictsWithPreview(environment: environment) {
        FileHandle.standardError.write(Data(
            "UV_MIGRATE_ONLY cannot be combined with UV_SNAPSHOT or UV_FIRST_RUN=force\n".utf8))
        exit(2)
    }
    if LaunchMode.current(environment: environment) == .migrateOnly {
        // Test hook: migrate, print one JSON line and exit, with no UI, status
        // item, hotkey tap or single-instance guard.
        FileHandle.standardOutput.write(Data((LaunchMigration.migrateOnlySummary() + "\n").utf8))
        exit(0)
    }
    let migrationReport = LaunchMigration.runAtLaunch()

    UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    let app = NSApplication.shared
    let delegate = AppDelegate(migrationReport: migrationReport)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
