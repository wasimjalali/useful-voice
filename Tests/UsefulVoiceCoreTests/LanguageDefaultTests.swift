import Foundation
import Testing
@testable import UsefulVoiceCore

/// The English default must reach new installs only. The failure these guard
/// against is an existing user, who was on Auto-detect, waking up on English.
@Suite("Language default")
struct LanguageDefaultTests {
    private func outcome(resolved: Bool = false, pin: String? = nil,
                         existing: Bool = false) -> LanguageDefault.Outcome {
        LanguageDefault.outcome(alreadyResolved: resolved, storedPin: pin, existingInstall: existing)
    }

    @Test func newInstallKeepsTheEnglishDefault() {
        #expect(outcome() == .markResolved)
    }

    @Test func existingInstallWithoutAPinGetsAutoOnce() {
        #expect(outcome(existing: true) == .writeAutoAndMarkResolved)
    }

    @Test func savedPinIsNeverOverwritten() {
        #expect(outcome(pin: "de", existing: true) == .markResolved)
        #expect(outcome(pin: "multi", existing: false) == .markResolved)
    }

    /// A new user who launched once (which creates usage stats) must not be
    /// read as an existing install on the next launch.
    @Test func settledInstallIsNeverReconsidered() {
        #expect(outcome(resolved: true, existing: true) == .nothing)
        #expect(outcome(resolved: true) == .nothing)
    }

    private func scratch() -> (UserDefaults, String) {
        let name = "uv.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func settingsOnAnExistingInstallStayOnAuto() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(54, forKey: "hotkeyKeycode")
        let settings = AppSettings(defaults: defaults)
        settings.resolveLanguageDefault(hasPriorData: false)
        #expect(settings.languagePin == .auto)
    }

    @Test func historyAloneMarksAnExistingInstall() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.resolveLanguageDefault(hasPriorData: true)
        #expect(settings.languagePin == .auto)
    }

    @Test func freshSettingsDefaultToEnglishAndStayThereOnRelaunch() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.resolveLanguageDefault(hasPriorData: false)
        #expect(settings.languagePin == .en)
        // Next launch: usage stats now exist, but the install is already settled.
        settings.resolveLanguageDefault(hasPriorData: true)
        #expect(settings.languagePin == .en)
    }
}
