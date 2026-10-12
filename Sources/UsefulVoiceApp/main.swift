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

/// Copies of the previous app identity that are running: a stale bundle, another
/// path, or a login item that still starts it. Quitting is a polite terminate.
@MainActor
private func runningLegacyCopies() -> LegacyInstances {
    func copies() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: IdentityMigration.Legacy.bundleID)
            .filter { !$0.isTerminated }
    }
    return LegacyInstances(
        runningPIDs: { copies().map { $0.processIdentifier } },
        requestQuit: { copies().forEach { _ = $0.terminate() } })
}

MainActor.assumeIsolated {
    _ = runMaintenanceFlagIfPresent()

    // The one-time move from the previous app identity (data folder, preferences,
    // Keychain key). It runs here, before the delegate exists and before anything
    // reads the data folder, the preferences or the key store. A render or a forced
    // first run never migrates.
    let environment = ProcessInfo.processInfo.environment
    if let refusal = LaunchMode.migrateOnlyRefusal(environment: environment) {
        FileHandle.standardError.write(Data((refusal + "\n").utf8))
        exit(2)
    }
    if LaunchMode.current(environment: environment) == .migrateOnly {
        // Test hook: migrate, print one JSON line and exit, with no UI, status
        // item, hotkey tap or single-instance guard.
        FileHandle.standardOutput.write(Data((LaunchMigration.migrateOnlySummary() + "\n").utf8))
        exit(0)
    }
    let launch = LaunchMigration.runAtLaunch(legacyInstances: runningLegacyCopies())
    if launch.mustQuitForLegacyCopy {
        // An older copy would not quit and still owns its data folder. Running beside
        // it would give two hotkey taps and two writers on the same files, so say so
        // and leave before any store, tap or write. The next launch migrates.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "An older copy of Useful Voice is still running."
        alert.informativeText = "Quit it, then open Useful Voice again. If it won't quit, force quit it in Activity Monitor."
        alert.addButton(withTitle: "OK")
        alert.runModal()
        exit(0)
    }

    // A render writes no preferences, so the scrollbar style is applied in memory
    // for it, merged into the argument domain rather than replacing it.
    if LaunchMode.migrationAllowed(environment: ProcessInfo.processInfo.environment) {
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
    } else {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleShowScrollBars"] = "WhenScrolling"
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate(launch: launch)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
