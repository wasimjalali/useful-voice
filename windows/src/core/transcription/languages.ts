/**
 * The languages Deepgram's Nova-3 model supports, and how each may be used.
 *
 * GENERATED FROM THE macOS CATALOGUE — do not hand-edit.
 * Source: `Sources/UsefulVoiceCore/Transcription/DeepgramLanguage.swift`, which is
 * itself transcribed from Deepgram's published Nova-3 language table
 * (https://developers.deepgram.com/docs/models-languages-overview).
 *
 * The two platforms share a data model, a Deepgram request shape and a backup
 * format, so a language list that differed between them would mean a term scoped to
 * Japanese on one machine became unscoped on the other. Generating this file is what
 * keeps them equal; `tests/languageCatalog.test.ts` asserts the contents match what
 * macOS ships.
 *
 * This file is pure data with no Electron, Node or DOM import, so it is unit-tested
 * on any platform.
 */

/** A language the provider can be asked to transcribe. */
export interface DeepgramLanguage {
  /** The value sent as `language=`. BCP-47, or the special `multi`. */
  code: string;
  /** English display name, matching Deepgram's own documentation. */
  name: string;
  /** The language's own name, so a speaker recognises it without translating. */
  nativeName: string;
}

/**
 * Every language `nova-3` supports for pre-recorded `/v1/listen`.
 *
 * Sorted by English name. Regional variants are collapsed only where the docs say
 * that is lossless: English variants (`en-US`, `en-GB`, …) all normalise to
 * standardised American spelling, so `en` covers them, while `zh-HK` (Cantonese)
 * is a different spoken language from `zh` (Mandarin) and stays its own row.
 */
export const DEEPGRAM_LANGUAGES: readonly DeepgramLanguage[] = [
  { code: "af", name: "Afrikaans", nativeName: "Afrikaans" },
  { code: "ar", name: "Arabic", nativeName: "\u0627\u0644\u0639\u0631\u0628\u064a\u0629" },
  { code: "hy", name: "Armenian", nativeName: "\u0540\u0561\u0575\u0565\u0580\u0565\u0576" },
  { code: "as", name: "Assamese", nativeName: "\u0985\u09b8\u09ae\u09c0\u09af\u09bc\u09be" },
  { code: "be", name: "Belarusian", nativeName: "\u0411\u0435\u043b\u0430\u0440\u0443\u0441\u043a\u0430\u044f" },
  { code: "bn", name: "Bengali", nativeName: "\u09ac\u09be\u0982\u09b2\u09be" },
  { code: "bs", name: "Bosnian", nativeName: "Bosanski" },
  { code: "bg", name: "Bulgarian", nativeName: "\u0411\u044a\u043b\u0433\u0430\u0440\u0441\u043a\u0438" },
  { code: "ca", name: "Catalan", nativeName: "Catal\u00e0" },
  { code: "zh-HK", name: "Chinese (Cantonese)", nativeName: "\u5ee3\u6771\u8a71" },
  { code: "zh", name: "Chinese (Mandarin, Simplified)", nativeName: "\u7b80\u4f53\u4e2d\u6587" },
  { code: "zh-TW", name: "Chinese (Mandarin, Traditional)", nativeName: "\u7e41\u9ad4\u4e2d\u6587" },
  { code: "hr", name: "Croatian", nativeName: "Hrvatski" },
  { code: "cs", name: "Czech", nativeName: "\u010ce\u0161tina" },
  { code: "da", name: "Danish", nativeName: "Dansk" },
  { code: "nl", name: "Dutch", nativeName: "Nederlands" },
  { code: "en", name: "English", nativeName: "English" },
  { code: "et", name: "Estonian", nativeName: "Eesti" },
  { code: "fi", name: "Finnish", nativeName: "Suomi" },
  { code: "nl-BE", name: "Flemish", nativeName: "Vlaams" },
  { code: "fr", name: "French", nativeName: "Fran\u00e7ais" },
  { code: "ka", name: "Georgian", nativeName: "\u10e5\u10d0\u10e0\u10d7\u10e3\u10da\u10d8" },
  { code: "de", name: "German", nativeName: "Deutsch" },
  { code: "de-CH", name: "German (Switzerland)", nativeName: "Schweizerdeutsch" },
  { code: "el", name: "Greek", nativeName: "\u0395\u03bb\u03bb\u03b7\u03bd\u03b9\u03ba\u03ac" },
  { code: "gu", name: "Gujarati", nativeName: "\u0a97\u0ac1\u0a9c\u0ab0\u0abe\u0aa4\u0ac0" },
  { code: "he", name: "Hebrew", nativeName: "\u05e2\u05d1\u05e8\u05d9\u05ea" },
  { code: "hi", name: "Hindi", nativeName: "\u0939\u093f\u0928\u094d\u0926\u0940" },
  { code: "hu", name: "Hungarian", nativeName: "Magyar" },
  { code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia" },
  { code: "it", name: "Italian", nativeName: "Italiano" },
  { code: "ja", name: "Japanese", nativeName: "\u65e5\u672c\u8a9e" },
  { code: "kn", name: "Kannada", nativeName: "\u0c95\u0ca8\u0ccd\u0ca8\u0ca1" },
  { code: "kk", name: "Kazakh", nativeName: "\u049a\u0430\u0437\u0430\u049b\u0448\u0430" },
  { code: "ko", name: "Korean", nativeName: "\ud55c\uad6d\uc5b4" },
  { code: "lv", name: "Latvian", nativeName: "Latvie\u0161u" },
  { code: "lt", name: "Lithuanian", nativeName: "Lietuvi\u0173" },
  { code: "mk", name: "Macedonian", nativeName: "\u041c\u0430\u043a\u0435\u0434\u043e\u043d\u0441\u043a\u0438" },
  { code: "ms", name: "Malay", nativeName: "Bahasa Melayu" },
  { code: "mr", name: "Marathi", nativeName: "\u092e\u0930\u093e\u0920\u0940" },
  { code: "mn", name: "Mongolian", nativeName: "\u041c\u043e\u043d\u0433\u043e\u043b" },
  { code: "ne", name: "Nepali", nativeName: "\u0928\u0947\u092a\u093e\u0932\u0940" },
  { code: "no", name: "Norwegian", nativeName: "Norsk" },
  { code: "ps", name: "Pashto", nativeName: "\u067e\u069a\u062a\u0648" },
  { code: "fa", name: "Persian", nativeName: "\u0641\u0627\u0631\u0633\u06cc" },
  { code: "pl", name: "Polish", nativeName: "Polski" },
  { code: "pt", name: "Portuguese", nativeName: "Portugu\u00eas" },
  { code: "pa", name: "Punjabi", nativeName: "\u0a2a\u0a70\u0a1c\u0a3e\u0a2c\u0a40" },
  { code: "ro", name: "Romanian", nativeName: "Rom\u00e2n\u0103" },
  { code: "ru", name: "Russian", nativeName: "\u0420\u0443\u0441\u0441\u043a\u0438\u0439" },
  { code: "sr", name: "Serbian", nativeName: "\u0421\u0440\u043f\u0441\u043a\u0438" },
  { code: "sk", name: "Slovak", nativeName: "Sloven\u010dina" },
  { code: "sl", name: "Slovenian", nativeName: "Sloven\u0161\u010dina" },
  { code: "es", name: "Spanish", nativeName: "Espa\u00f1ol" },
  { code: "sv", name: "Swedish", nativeName: "Svenska" },
  { code: "tl", name: "Tagalog", nativeName: "Tagalog" },
  { code: "ta", name: "Tamil", nativeName: "\u0ba4\u0bae\u0bbf\u0bb4\u0bcd" },
  { code: "te", name: "Telugu", nativeName: "\u0c24\u0c46\u0c32\u0c41\u0c17\u0c41" },
  { code: "th", name: "Thai", nativeName: "\u0e44\u0e17\u0e22" },
  { code: "tr", name: "Turkish", nativeName: "T\u00fcrk\u00e7e" },
  { code: "uk", name: "Ukrainian", nativeName: "\u0423\u043a\u0440\u0430\u0457\u043d\u0441\u044c\u043a\u0430" },
  { code: "ur", name: "Urdu", nativeName: "\u0627\u0631\u062f\u0648" },
  { code: "vi", name: "Vietnamese", nativeName: "Ti\u1ebfng Vi\u1ec7t" },
];

/**
 * Multilingual code-switching, as a selectable value.
 *
 * Not a language and not auto-detection: it transcribes conversations where the
 * speaker switches language mid-sentence, covers ten languages, and is billed at
 * the higher multilingual rate. Offered separately from `auto`.
 */
export const MULTILINGUAL_CODE_SWITCHING: DeepgramLanguage = {
  code: 'multi',
  name: 'Multiple languages (code-switching)',
  nativeName: 'Multilingual',
};

/**
 * The codes Deepgram documents as supported by `detect_language`.
 *
 * A different and **smaller** set than Nova-3's languages — 35 against 63. That
 * matters beyond tidiness: the docs say an undetected-unsupported language makes
 * Deepgram "automatically select the next highest model", and `keyterm` is "Only
 * compatible with Nova-3". Restricting detection to codes Nova-3 supports natively
 * makes that fallback unreachable, so the dictionary cannot be silently dropped on
 * a request the app itself constructed.
 */
export const DETECTION_CODES: readonly string[] = [
  "bg",
  "ca",
  "cs",
  "da",
  "de",
  "de-CH",
  "el",
  "en",
  "es",
  "et",
  "fi",
  "fr",
  "hi",
  "hu",
  "id",
  "it",
  "ja",
  "ko",
  "lt",
  "lv",
  "ms",
  "nl",
  "nl-BE",
  "no",
  "pl",
  "pt",
  "ro",
  "ru",
  "sk",
  "sv",
  "th",
  "tr",
  "uk",
  "vi",
  "zh",
];

/** Look up a language, including the `multi` mode. */
export function findLanguage(code: string): DeepgramLanguage | undefined {
  if (code === MULTILINGUAL_CODE_SWITCHING.code) return MULTILINGUAL_CODE_SWITCHING;
  return DEEPGRAM_LANGUAGES.find((language) => language.code === code);
}

/**
 * Whether the app can ask for this value directly.
 *
 * `auto` is deliberately excluded: it is a detection mode, not a language to
 * request, and sending `language=auto` would be an error.
 */
export function isSupportedLanguage(code: string): boolean {
  return findLanguage(code) !== undefined;
}

/**
 * Normalise a stored value to something sendable.
 *
 * Matching is **case-sensitive against the catalogue**. Lowercasing the input looks
 * harmless and is not: `zh-HK`, `zh-TW`, `de-CH` and `nl-BE` carry meaningful
 * uppercase region subtags, and folding them to `zh-hk` matched nothing — so
 * selecting Cantonese stored `auto` and silently transcribed with detection
 * instead. A case-insensitive retry is kept as a convenience, but it resolves to
 * the catalogue's own spelling.
 */
export function normaliseLanguageCode(code: string): string {
  const trimmed = code.trim();
  if (trimmed.length === 0) return 'auto';
  if (trimmed.toLowerCase() === 'auto') return 'auto';
  if (isSupportedLanguage(trimmed)) return trimmed;
  const folded = DEEPGRAM_LANGUAGES.find(
    (language) => language.code.toLowerCase() === trimmed.toLowerCase(),
  );
  return folded ? folded.code : 'auto';
}

/**
 * Whether spoken punctuation ("period", "new line") applies.
 *
 * Deepgram documents Dictation as "English (all available regions)" only, so it is
 * suppressed everywhere else rather than sent and ignored.
 */
export function supportsSpokenPunctuation(code: string): boolean {
  return code === 'en' || code.startsWith('en-');
}

/**
 * Whether a returned `detected_language` is one Nova-3 handles natively.
 *
 * If it is not, the provider fell back to a lower model and `keyterm` was silently
 * dropped: the app was told to bias the transcript with the user's dictionary and
 * could not. Worth surfacing, because the visible symptom — odd spellings of the
 * user's own terminology — looks like a dictionary fault rather than a model one.
 */
export function detectionStayedOnNova3(code: string): boolean {
  return DEEPGRAM_LANGUAGES.some(
    (language) => language.code === code || code.startsWith(language.code),
  );
}
