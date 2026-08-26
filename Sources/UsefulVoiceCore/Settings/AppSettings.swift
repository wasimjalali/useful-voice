import Foundation

public enum LanguagePin: String, CaseIterable, Sendable {
    case auto, en, de

    /// The next language for the quick-switch key: a straight English<->German
    /// flip. From `.auto`, the first tap lands on English, then it alternates.
    public var quickToggled: LanguagePin {
        switch self {
        case .en: return .de
        case .de: return .en
        case .auto: return .en
        }
    }
}

public struct HotkeyAssignment: Equatable, Sendable {
    public private(set) var dictation: Int
    public private(set) var languageSwitch: Int

    public init(dictation: Int, languageSwitch: Int) {
        self.dictation = dictation
        self.languageSwitch = languageSwitch
    }

    public mutating func setDictation(_ keycode: Int) {
        let previous = dictation
        if keycode == languageSwitch {
            languageSwitch = previous
        }
        dictation = keycode
    }

    public mutating func setLanguageSwitch(_ keycode: Int) {
        let previous = languageSwitch
        if keycode == dictation {
            dictation = previous
        }
        languageSwitch = keycode
    }
}

/// Non-secret app configuration. The Deepgram API key lives in Keychain, never here.
public final class AppSettings {
    private enum Keys {
        static let languagePin = "languagePin"
        static let silenceTimeout = "silenceTimeout"
        static let recordingsToKeep = "recordingsToKeep"
        static let hotkeyKeycode = "hotkeyKeycode"
        static let languageSwitchKeycode = "languageSwitchKeycode"
        static let formattingEnabled = "formattingEnabled"
        static let soundEffectsEnabled = "soundEffectsEnabled"
        static let lastExportFolder = "lastExportFolder"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var languagePin: LanguagePin {
        get { LanguagePin(rawValue: defaults.string(forKey: Keys.languagePin) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Keys.languagePin) }
    }

    /// Seconds of silence before recording auto-stops. Spec section 8.
    public var silenceTimeout: TimeInterval {
        get { defaults.object(forKey: Keys.silenceTimeout) as? TimeInterval ?? 60 }
        set { defaults.set(newValue, forKey: Keys.silenceTimeout) }
    }

    /// How many past recordings to retain for retry/debugging. Spec section 5.
    public var recordingsToKeep: Int {
        get { defaults.object(forKey: Keys.recordingsToKeep) as? Int ?? 10 }
        set { defaults.set(newValue, forKey: Keys.recordingsToKeep) }
    }

    /// Virtual keycode of the activation modifier key. Default 54 = Right Command.
    public var hotkeyKeycode: Int {
        get { defaults.object(forKey: Keys.hotkeyKeycode) as? Int ?? 54 }
        set { defaults.set(newValue, forKey: Keys.hotkeyKeycode) }
    }

    /// Virtual keycode of the language quick-switch key. Default 60 = Right Shift
    /// (the Shift key under the Return key) by explicit user choice. A clean tap
    /// flips the dictation language between English and German. A bare Shift tap
    /// can fire by accident during fast capitalization, so if that becomes a
    /// nuisance the key is changeable in Settings. The Settings layer keeps it
    /// distinct from the dictation key.
    public var languageSwitchKeycode: Int {
        get { defaults.object(forKey: Keys.languageSwitchKeycode) as? Int ?? 60 }
        set { defaults.set(newValue, forKey: Keys.languageSwitchKeycode) }
    }

    /// Auto-format the transcript. Maps to Deepgram's `smart_format` (punctuation,
    /// capitalization, formatted numbers and dates). Default: on.
    public var formattingEnabled: Bool {
        get { defaults.object(forKey: Keys.formattingEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.formattingEnabled) }
    }

    /// Soft chimes when dictation starts and stops. Default: on.
    public var soundEffectsEnabled: Bool {
        get { defaults.object(forKey: Keys.soundEffectsEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.soundEffectsEnabled) }
    }

    public var lastExportFolder: String {
        get { defaults.string(forKey: Keys.lastExportFolder) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lastExportFolder) }
    }
}
