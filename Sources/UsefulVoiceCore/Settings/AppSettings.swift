import Foundation

/// The language the app is transcribing in: a specific language, or `.auto`.
///
/// A struct around a string rather than an enum with three cases. The offered set
/// is the *provider's* catalogue (`DeepgramLanguageCatalog`), not a fixed app
/// concern, and an enum meant adding a language was a source change in five files.
/// The special value is still `auto`, which is a detection mode rather than a
/// language, so the picker presents it separately and first.
///
/// `rawValue` stays a plain string, so the value already in `UserDefaults` keeps
/// working and no settings migration is needed.
public struct LanguagePin: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    /// Offered in this order by every picker: the modes first, then languages.
    public static let auto = LanguagePin(rawValue: "auto")
    public static let en = LanguagePin(rawValue: "en")
    public static let de = LanguagePin(rawValue: "de")
    /// Multilingual code-switching. A mode rather than a language: it is for audio
    /// where the speaker changes language mid-sentence. Distinct from auto, which
    /// detects a single dominant language.
    public static let multilingual = LanguagePin(rawValue: "multi")

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The non-language modes, in picker order: detection first, then
    /// code-switching.
    public static var modes: [LanguagePin] { [.auto, .multilingual] }

    /// Every value the pickers offer: the modes, then the languages.
    public static var allCases: [LanguagePin] {
        modes + DeepgramLanguageCatalog.all.map { LanguagePin(rawValue: $0.code) }
    }

    /// A pin for a language code, falling back to auto for anything unknown.
    ///
    /// Falling back rather than storing an unusable value matters: a pin naming a
    /// language the model cannot transcribe would fail silently at the provider.
    ///
    /// Matching is **case-sensitive against the catalogue**. Lowercasing the input
    /// looks harmless and is not: `zh-HK`, `zh-TW`, `de-CH` and `nl-BE` carry
    /// meaningful uppercase region subtags, and folding them to `zh-hk` matched
    /// nothing — so picking Cantonese stored `auto` and silently transcribed with
    /// detection instead. A case-insensitive retry is kept as a convenience, but it
    /// resolves to the catalogue's own spelling.
    public init(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "auto" {
            self = .auto
            return
        }
        if DeepgramLanguageCatalog.isSupported(trimmed) {
            self = LanguagePin(rawValue: trimmed)
            return
        }
        // Accept a differently-cased spelling of a real code, but resolve it to the
        // catalogue's own casing so the stored value is always canonical.
        if let match = DeepgramLanguageCatalog.all.first(where: {
            $0.code.lowercased() == trimmed.lowercased()
        }) {
            self = LanguagePin(rawValue: match.code)
            return
        }
        // A stored code the catalogue no longer offers falls back to detection
        // rather than being sent and failing at the provider.
        self = .auto
    }

    /// Whether the stored value names something this build still recognises.
    ///
    /// Distinguishes "detection" from "a language this build dropped", which are
    /// otherwise both just a string in `UserDefaults`.
    public var isRecognised: Bool {
        isAuto || DeepgramLanguageCatalog.isSupported(rawValue)
    }

    public var isAuto: Bool { rawValue == "auto" }

    /// Multilingual code-switching, which is a mode rather than a language.
    public var isMultilingual: Bool { rawValue == "multi" }

    /// The catalogue entry, or nil for auto and for codes outside the catalogue.
    public var language: DeepgramLanguage? {
        DeepgramLanguageCatalog.language(for: rawValue)
    }

    /// What to show the user. Never returns a bare code: an unlisted language
    /// still has to be describable in a menu, and a raw BCP-47 tag is not copy.
    public var displayName: String {
        if isAuto { return "Detect automatically" }
        if isMultilingual { return "Multiple languages" }
        if let language { return language.name }
        return rawValue.uppercased()
    }

    /// The name in the language's own script, for the picker's subtitle.
    public var nativeName: String? {
        language.map(\.nativeName)
    }

    /// Whether spoken punctuation applies to this pin.
    ///
    /// False for the modes: auto has not identified a language yet, and
    /// code-switching can include non-English. Asking for English-only dictation
    /// in either case would contradict the request.
    public var supportsSpokenPunctuation: Bool {
        (isAuto || isMultilingual) ? false
            : DeepgramLanguageCatalog.supportsSpokenPunctuation(rawValue)
    }

    /// Whether this pin sends `detect_language` rather than `language`.
    public var usesDetection: Bool { isAuto }

    /// Whether this pin is sent as `language=<code>`.
    public var sendsLanguageParameter: Bool { !isAuto }

    /// The next language for the quick-switch key.
    ///
    /// Kept for the keyboard path, but the hotkey no longer cycles: it opens the
    /// picker, because cycling cannot reach ten languages. This is retained so the
    /// cycle order is still defined for anything that needs a "next" value.
    public var quickToggled: LanguagePin {
        if self == .en { return .de }
        if self == .de { return .en }
        return .en
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
        static let spokenPunctuationEnabled = "spokenPunctuationEnabled"
        static let soundEffectsEnabled = "soundEffectsEnabled"
        static let lastExportFolder = "lastExportFolder"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var languagePin: LanguagePin {
        // `init(code:)` rather than `init(rawValue:)`: it normalises an unset or
        // unrecognised stored value to auto. The raw initialiser is non-failable
        // now that the type is a struct over a string, so an empty default would
        // have produced a pin naming no language at all.
        get { LanguagePin(code: defaults.string(forKey: Keys.languagePin) ?? "") }
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

    /// Convert spoken punctuation commands ("period", "new line") into the
    /// characters themselves, using Deepgram's Dictation feature.
    ///
    /// Defaults to off: it changes what the words mean, so it is opt-in rather
    /// than bundled with formatting. English only — Deepgram documents Dictation
    /// as "English (all available regions)" — so it is ignored for German.
    public var spokenPunctuationEnabled: Bool {
        get { defaults.object(forKey: Keys.spokenPunctuationEnabled) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.spokenPunctuationEnabled) }
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
