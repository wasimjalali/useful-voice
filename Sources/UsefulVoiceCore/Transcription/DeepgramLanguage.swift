import Foundation

/// A language Deepgram can be asked to transcribe.
///
/// Modelled as data rather than an enum because the supported set is the
/// *provider's* catalogue, not the app's: it changes when Deepgram adds a
/// language, and the picker is populated from it. An enum with three cases meant
/// offering three languages and no way to describe the rest.
public struct DeepgramLanguage: Identifiable, Hashable, Sendable {
    /// The value sent as `language=`. A BCP-47 tag, or the special `multi`.
    public let code: String
    /// English display name, matching Deepgram's own documentation.
    public let name: String
    /// The language's own name, so a speaker recognises it without translating.
    public let nativeName: String

    public var id: String { code }

    public init(code: String, name: String, nativeName: String) {
        self.code = code
        self.name = name
        self.nativeName = nativeName
    }
}

/// The languages this app offers, and how each one may be used.
///
/// The catalogue is the full set Deepgram documents for Nova-3 on `/v1/listen`,
/// not a hand-picked subset. It started as ten, which silently withheld most of
/// what the model supports: a Korean or Turkish speaker had no way to pin their
/// language and would have been left on detection that cannot return their code.
///
/// Regional variants are collapsed to their base language where doing so is
/// lossless, and kept as separate rows where it is not:
///
/// - `en-US`/`en-GB`/`en-AU`/`en-IN`/`en-NZ` collapse to `en`. Deepgram normalises
///   English spelling regardless of variant — "Transcription outputs from the
///   English models are provided with standardized American spelling of words …
///   'color' will always be spelled as such with both `language=en-US` and
///   `language=en-GB`" — so the variants select the same output for dictation and
///   a list of six English rows would bury the languages being scanned for.
/// - `zh-HK` (Cantonese) is **not** collapsed into `zh` (Mandarin): different
///   spoken language, same writing system.
/// - `de-CH` is kept: Deepgram names it separately and Swiss German is not a
///   restyling of German German.
/// - `nl-BE` (Flemish) is kept, and `es-419` (Latin American Spanish) is dropped in
///   favour of `es` — its variant is regional vocabulary rather than a distinct
///   acoustic model.
public enum DeepgramLanguageCatalog {

    /// Every language `nova-3` supports for pre-recorded `/v1/listen`.
    ///
    /// Sorted by English name so the picker reads as a list rather than a spec.
    public static let all: [DeepgramLanguage] = [
        DeepgramLanguage(code: "af", name: "Afrikaans", nativeName: "Afrikaans"),
        DeepgramLanguage(code: "ar", name: "Arabic", nativeName: "العربية"),
        DeepgramLanguage(code: "hy", name: "Armenian", nativeName: "Հայերեն"),
        DeepgramLanguage(code: "as", name: "Assamese", nativeName: "অসমীয়া"),
        DeepgramLanguage(code: "be", name: "Belarusian", nativeName: "Беларуская"),
        DeepgramLanguage(code: "bn", name: "Bengali", nativeName: "বাংলা"),
        DeepgramLanguage(code: "bs", name: "Bosnian", nativeName: "Bosanski"),
        DeepgramLanguage(code: "bg", name: "Bulgarian", nativeName: "Български"),
        DeepgramLanguage(code: "ca", name: "Catalan", nativeName: "Català"),
        DeepgramLanguage(code: "zh-HK", name: "Chinese (Cantonese)", nativeName: "廣東話"),
        DeepgramLanguage(code: "zh", name: "Chinese (Mandarin, Simplified)", nativeName: "简体中文"),
        DeepgramLanguage(code: "zh-TW", name: "Chinese (Mandarin, Traditional)", nativeName: "繁體中文"),
        DeepgramLanguage(code: "hr", name: "Croatian", nativeName: "Hrvatski"),
        DeepgramLanguage(code: "cs", name: "Czech", nativeName: "Čeština"),
        DeepgramLanguage(code: "da", name: "Danish", nativeName: "Dansk"),
        DeepgramLanguage(code: "nl", name: "Dutch", nativeName: "Nederlands"),
        DeepgramLanguage(code: "en", name: "English", nativeName: "English"),
        DeepgramLanguage(code: "et", name: "Estonian", nativeName: "Eesti"),
        DeepgramLanguage(code: "fi", name: "Finnish", nativeName: "Suomi"),
        DeepgramLanguage(code: "nl-BE", name: "Flemish", nativeName: "Vlaams"),
        DeepgramLanguage(code: "fr", name: "French", nativeName: "Français"),
        DeepgramLanguage(code: "ka", name: "Georgian", nativeName: "ქართული"),
        DeepgramLanguage(code: "de", name: "German", nativeName: "Deutsch"),
        DeepgramLanguage(code: "de-CH", name: "German (Switzerland)", nativeName: "Schweizerdeutsch"),
        DeepgramLanguage(code: "el", name: "Greek", nativeName: "Ελληνικά"),
        DeepgramLanguage(code: "gu", name: "Gujarati", nativeName: "ગુજરાતી"),
        DeepgramLanguage(code: "he", name: "Hebrew", nativeName: "עברית"),
        DeepgramLanguage(code: "hi", name: "Hindi", nativeName: "हिन्दी"),
        DeepgramLanguage(code: "hu", name: "Hungarian", nativeName: "Magyar"),
        DeepgramLanguage(code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia"),
        DeepgramLanguage(code: "it", name: "Italian", nativeName: "Italiano"),
        DeepgramLanguage(code: "ja", name: "Japanese", nativeName: "日本語"),
        DeepgramLanguage(code: "kn", name: "Kannada", nativeName: "ಕನ್ನಡ"),
        DeepgramLanguage(code: "kk", name: "Kazakh", nativeName: "Қазақша"),
        DeepgramLanguage(code: "ko", name: "Korean", nativeName: "한국어"),
        DeepgramLanguage(code: "lv", name: "Latvian", nativeName: "Latviešu"),
        DeepgramLanguage(code: "lt", name: "Lithuanian", nativeName: "Lietuvių"),
        DeepgramLanguage(code: "mk", name: "Macedonian", nativeName: "Македонски"),
        DeepgramLanguage(code: "ms", name: "Malay", nativeName: "Bahasa Melayu"),
        DeepgramLanguage(code: "mr", name: "Marathi", nativeName: "मराठी"),
        DeepgramLanguage(code: "mn", name: "Mongolian", nativeName: "Монгол"),
        DeepgramLanguage(code: "ne", name: "Nepali", nativeName: "नेपाली"),
        DeepgramLanguage(code: "no", name: "Norwegian", nativeName: "Norsk"),
        DeepgramLanguage(code: "ps", name: "Pashto", nativeName: "پښتو"),
        DeepgramLanguage(code: "fa", name: "Persian", nativeName: "فارسی"),
        DeepgramLanguage(code: "pl", name: "Polish", nativeName: "Polski"),
        DeepgramLanguage(code: "pt", name: "Portuguese", nativeName: "Português"),
        DeepgramLanguage(code: "pa", name: "Punjabi", nativeName: "ਪੰਜਾਬੀ"),
        DeepgramLanguage(code: "ro", name: "Romanian", nativeName: "Română"),
        DeepgramLanguage(code: "ru", name: "Russian", nativeName: "Русский"),
        DeepgramLanguage(code: "sr", name: "Serbian", nativeName: "Српски"),
        DeepgramLanguage(code: "sk", name: "Slovak", nativeName: "Slovenčina"),
        DeepgramLanguage(code: "sl", name: "Slovenian", nativeName: "Slovenščina"),
        DeepgramLanguage(code: "es", name: "Spanish", nativeName: "Español"),
        DeepgramLanguage(code: "sv", name: "Swedish", nativeName: "Svenska"),
        DeepgramLanguage(code: "tl", name: "Tagalog", nativeName: "Tagalog"),
        DeepgramLanguage(code: "ta", name: "Tamil", nativeName: "தமிழ்"),
        DeepgramLanguage(code: "te", name: "Telugu", nativeName: "తెలుగు"),
        DeepgramLanguage(code: "th", name: "Thai", nativeName: "ไทย"),
        DeepgramLanguage(code: "tr", name: "Turkish", nativeName: "Türkçe"),
        DeepgramLanguage(code: "uk", name: "Ukrainian", nativeName: "Українська"),
        DeepgramLanguage(code: "ur", name: "Urdu", nativeName: "اردو"),
        DeepgramLanguage(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt"),
    ]

    /// Multilingual code-switching, as a selectable value.
    ///
    /// Not a language and not auto-detection: it transcribes "conversations where
    /// speakers switch between multiple languages" and covers ten languages
    /// (English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese,
    /// Italian, Dutch). Offered separately from `auto`, and billed at the
    /// multilingual rate, which is higher than monolingual.
    public static let multilingualCodeSwitching = DeepgramLanguage(
        code: "multi",
        name: "Multiple languages (code-switching)",
        nativeName: "Multilingual"
    )

    /// The codes Deepgram documents as supported by `detect_language`.
    ///
    /// **A different and smaller set than Nova-3's languages** — 35 codes against
    /// 63. This matters beyond tidiness: the docs say that if a detected language
    /// is unavailable on the requested model, Deepgram "will automatically select
    /// the next highest model to complete the request", and `keyterm` is "Only
    /// compatible with Nova-3". A detection restricted to codes Nova-3 already
    /// supports natively cannot trigger that fallback, so the dictionary feature
    /// cannot be silently dropped on a request the app itself made.
    public static let detectionCodes: [String] = [
        "bg", "ca", "cs", "da", "de", "de-CH", "el", "en", "es", "et", "fi", "fr",
        "hi", "hu", "id", "it", "ja", "ko", "lt", "lv", "ms", "nl", "nl-BE", "no",
        "pl", "pt", "ro", "ru", "sk", "sv", "th", "tr", "uk", "vi", "zh",
    ]

    public static func language(for code: String) -> DeepgramLanguage? {
        if code == multilingualCodeSwitching.code { return multilingualCodeSwitching }
        return all.first { $0.code == code }
    }

    /// Whether the app can ask for this value directly.
    public static func isSupported(_ code: String) -> Bool {
        language(for: code) != nil
    }

    /// Whether a returned `detected_language` is one Nova-3 handles natively.
    ///
    /// If it is not, the provider fell back to a lower model and `keyterm` was
    /// silently dropped — the app was told to bias the transcript with the user's
    /// dictionary and could not. Worth surfacing rather than discarding, because the
    /// visible symptom (odd spellings of the user's own terminology) looks like a
    /// dictionary problem rather than a model problem.
    ///
    /// The comparison goes from the *returned* code towards the catalogue, and the
    /// direction is the whole point. Deepgram may answer with a more specific tag
    /// than the one the catalogue stores — `zh-CN` for `zh`, `en-US` for `en` — so
    /// the returned code is the one that gets stripped. Testing it the other way
    /// round (`code.hasPrefix(catalogueCode)`) inverts the meaning and passes almost
    /// everything: `nope` matches `no`, `korean` matches `ko`, `ja-JP` matches `ja`.
    /// That direction looked plausible and was wrong, and a check that answers "yes"
    /// by accident is worse than no check, because its caller believes it.
    public static func detectionStayedOnNova3(_ code: String) -> Bool {
        let normalised = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalised.isEmpty else { return false }
        return all.contains { language in
            let known = language.code.lowercased()
            return normalised == known || normalised.hasPrefix(known + "-")
        }
    }

    /// Whether spoken punctuation ("period", "new line") applies.
    ///
    /// Deepgram documents Dictation as "English (all available regions)" only, so
    /// it is suppressed everywhere else rather than sent and ignored.
    public static func supportsSpokenPunctuation(_ code: String) -> Bool {
        code == "en" || code.hasPrefix("en-")
    }
}
