import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite(.serialized) struct AppSettingsTests {
    private let defaults: UserDefaults
    private let settings: AppSettings

    init() {
        defaults = UserDefaults(suiteName: "ai.karko.sadaa.tests")!
        // Clear persisted state before constructing settings so tests start clean.
        defaults.removePersistentDomain(forName: "ai.karko.sadaa.tests")
        settings = AppSettings(defaults: defaults)
    }

    @Test func testDefaults() {
        #expect(settings.languagePin == .auto)
        #expect(settings.silenceTimeout == 60)
        #expect(settings.recordingsToKeep == 10)
        #expect(settings.formattingEnabled == true)
        #expect(settings.hotkeyKeycode == 54)          // Right Command
        #expect(settings.languageSwitchKeycode == 60)  // Right Shift (under Return)
        #expect(settings.soundEffectsEnabled == true)
    }

    @Test func testRoundTrip() {
        settings.languagePin = .de
        settings.silenceTimeout = 45.5
        settings.recordingsToKeep = 5
        settings.formattingEnabled = false
        settings.hotkeyKeycode = 61
        settings.languageSwitchKeycode = 63
        settings.soundEffectsEnabled = false
        #expect(settings.languagePin == .de)
        #expect(settings.silenceTimeout == 45.5)
        #expect(settings.recordingsToKeep == 5)
        #expect(settings.formattingEnabled == false)
        #expect(settings.hotkeyKeycode == 61)
        #expect(settings.languageSwitchKeycode == 63)
        #expect(settings.soundEffectsEnabled == false)
    }

    @Test func testTwoHotkeysSwapWhenTheyCollide() {
        var assignment = HotkeyAssignment(dictation: 54, languageSwitch: 60)

        assignment.setDictation(60)
        #expect(assignment.dictation == 60)
        #expect(assignment.languageSwitch == 54)

        assignment.setLanguageSwitch(60)
        #expect(assignment.dictation == 54)
        #expect(assignment.languageSwitch == 60)
    }

    @Test func testQuickToggleFlipsEnglishAndGerman() {
        #expect(LanguagePin.en.quickToggled == .de)
        #expect(LanguagePin.de.quickToggled == .en)
        // From auto the first tap lands on English, then it alternates.
        #expect(LanguagePin.auto.quickToggled == .en)
        #expect(LanguagePin.auto.quickToggled.quickToggled == .de)
    }
}
