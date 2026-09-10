import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import {
  DEEPGRAM_LANGUAGES,
  DETECTION_CODES,
  MULTILINGUAL_CODE_SWITCHING,
  detectionStayedOnNova3,
  findLanguage,
  isSupportedLanguage,
  normaliseLanguageCode,
  supportsSpokenPunctuation,
} from '../src/core/transcription/languages.js';
import { MEMORY_LANGUAGES, normaliseMemoryLanguage } from '../src/core/models.js';
import { filterLanguageOptions, languagePickerOptions } from '../src/renderer/languagePicker.js';

/**
 * The catalogue is a large hand-transcribed data set, and every way it can be wrong
 * is silent: a mistyped code still sends, Deepgram still answers, and the user gets
 * worse transcription in a language they believed they had picked.
 */
describe('Deepgram language catalogue', () => {
  it('carries the full Nova-3 set', () => {
    // Deepgram documents 63 named languages for Nova-3. Regional variants are
    // collapsed, so this is the count of rows, not of code strings.
    expect(DEEPGRAM_LANGUAGES.length).toBe(63);
  });

  it('has well-formed, unique, sorted entries', () => {
    for (const language of DEEPGRAM_LANGUAGES) {
      expect(language.code.length).toBeGreaterThan(0);
      expect(language.name.length).toBeGreaterThan(0);
      expect(language.nativeName.length).toBeGreaterThan(0);
      expect(language.code).not.toContain(' ');
      expect(language.code.trim()).toBe(language.code);
    }
    expect(new Set(DEEPGRAM_LANGUAGES.map((l) => l.code)).size).toBe(DEEPGRAM_LANGUAGES.length);
    const names = DEEPGRAM_LANGUAGES.map((l) => l.name);
    expect(names).toEqual([...names].sort());
  });

  it('keeps every language the app offered before', () => {
    // Existing users have terms and replacements scoped to these.
    for (const code of ['nl', 'en', 'fr', 'de', 'hi', 'it', 'ja', 'pt', 'ru', 'es', 'zh']) {
      expect(isSupportedLanguage(code), `${code} was dropped`).toBe(true);
    }
  });

  it('collapses regional variants only where the docs say that is lossless', () => {
    // English spelling is standardised regardless of which English code is sent.
    expect(isSupportedLanguage('en-US')).toBe(false);
    expect(isSupportedLanguage('en-GB')).toBe(false);
    expect(isSupportedLanguage('en')).toBe(true);
    // Cantonese is a different spoken language from Mandarin.
    expect(isSupportedLanguage('zh-HK')).toBe(true);
    expect(isSupportedLanguage('zh')).toBe(true);
    expect(isSupportedLanguage('zh-TW')).toBe(true);
    expect(isSupportedLanguage('de-CH')).toBe(true);
    expect(isSupportedLanguage('nl-BE')).toBe(true);
  });

  it('never offers auto as a language', () => {
    // `auto` is a detection mode; sending `language=auto` would be an error.
    expect(isSupportedLanguage('auto')).toBe(false);
    expect(DEEPGRAM_LANGUAGES.some((l) => l.code === 'auto')).toBe(false);
  });

  it('exposes multilingual code-switching as a selectable mode', () => {
    expect(isSupportedLanguage('multi')).toBe(true);
    expect(findLanguage('multi')?.code).toBe('multi');
    // It is a mode, so it is not one of the language rows.
    expect(DEEPGRAM_LANGUAGES.some((l) => l.code === 'multi')).toBe(false);
    expect(MULTILINGUAL_CODE_SWITCHING.name).toContain('code-switching');
  });
});

/**
 * `detect_language` supports fewer codes than Nova-3 speaks, and confusing the two
 * is the documented route to a silent model downgrade — which also drops `keyterm`,
 * the entire dictionary feature.
 */
describe('language detection', () => {
  it('uses exactly the documented detection set', () => {
    expect(DETECTION_CODES.length).toBe(35);
    expect([...DETECTION_CODES].sort()).toEqual(
      ['bg', 'ca', 'cs', 'da', 'de', 'de-CH', 'el', 'en', 'es', 'et', 'fi', 'fr', 'hi',
       'hu', 'id', 'it', 'ja', 'ko', 'lt', 'lv', 'ms', 'nl', 'nl-BE', 'no', 'pl', 'pt',
       'ro', 'ru', 'sk', 'sv', 'th', 'tr', 'uk', 'vi', 'zh'].sort(),
    );
  });

  it('restricts detection to codes the catalogue can also pin', () => {
    // Otherwise detection could return a language the picker cannot offer.
    for (const code of DETECTION_CODES) {
      expect(isSupportedLanguage(code), `${code} is not pinnable`).toBe(true);
    }
  });

  it('is a strict subset of the languages, not the whole list', () => {
    // If these ever became equal, the "smaller detection set" reasoning has stopped
    // being true and requests would ask detection for codes it cannot return.
    expect(DETECTION_CODES.length).toBeLessThan(DEEPGRAM_LANGUAGES.length);
  });

  it('recognises when a detected language left Nova-3', () => {
    expect(detectionStayedOnNova3('en')).toBe(true);
    expect(detectionStayedOnNova3('zh-HK')).toBe(true);
    expect(detectionStayedOnNova3('en-US')).toBe(true);
    expect(detectionStayedOnNova3('klingon')).toBe(false);
  });
});

describe('spoken punctuation', () => {
  it('is English-only', () => {
    expect(supportsSpokenPunctuation('en')).toBe(true);
    expect(supportsSpokenPunctuation('en-US')).toBe(true);
    expect(supportsSpokenPunctuation('de')).toBe(false);
    expect(supportsSpokenPunctuation('ja')).toBe(false);
  });

  it('is off for both modes', () => {
    // Auto has not identified a language yet, and code-switching may include
    // non-English, so neither can promise English-only dictation.
    expect(supportsSpokenPunctuation('auto')).toBe(false);
    expect(supportsSpokenPunctuation('multi')).toBe(false);
  });
});

/**
 * The stored pin decides what every request asks for, so an unusable value is not a
 * cosmetic problem.
 */
describe('language code normalisation', () => {
  it('accepts every catalogue code and mode unchanged', () => {
    for (const code of [...MEMORY_LANGUAGES]) {
      expect(normaliseLanguageCode(code)).toBe(code);
      expect(normaliseMemoryLanguage(code)).toBe(code);
    }
  });

  it('preserves region casing', () => {
    // Folding `zh-HK` to `zh-hk` matches nothing and would silently demote
    // Cantonese to detection — a user picks a language and gets detection.
    expect(normaliseLanguageCode('zh-HK')).toBe('zh-HK');
    expect(normaliseLanguageCode('zh-TW')).toBe('zh-TW');
    expect(normaliseLanguageCode('de-CH')).toBe('de-CH');
    expect(normaliseLanguageCode('nl-BE')).toBe('nl-BE');
    expect(normaliseMemoryLanguage('zh-HK')).toBe('zh-HK');
  });

  it('accepts a differently-cased spelling but resolves to canonical casing', () => {
    expect(normaliseLanguageCode('DE')).toBe('de');
    expect(normaliseLanguageCode('zh-hk')).toBe('zh-HK');
    expect(normaliseLanguageCode(' de ')).toBe('de');
  });

  it('falls back to detection for anything unusable', () => {
    expect(normaliseLanguageCode('')).toBe('auto');
    expect(normaliseLanguageCode('   ')).toBe('auto');
    expect(normaliseLanguageCode('klingon')).toBe('auto');
    expect(normaliseMemoryLanguage(undefined)).toBe('auto');
    expect(normaliseMemoryLanguage(42)).toBe('auto');
    expect(normaliseMemoryLanguage(null)).toBe('auto');
  });

  it('keeps multi as multi rather than treating it as detection', () => {
    // The bug this guards: an earlier build offered `multi` labelled "Detect
    // automatically". They are different modes — `multi` is code-switching — and a
    // user who chose what they were told was detection was sent the wrong one.
    expect(normaliseLanguageCode('multi')).toBe('multi');
    expect(normaliseLanguageCode('multi')).not.toBe('auto');
    expect(normaliseMemoryLanguage('multi')).toBe('multi');
  });
});

describe('language picker options', () => {
  it('leads with the two modes, then every language', () => {
    const options = languagePickerOptions();
    expect(options[0]?.value).toBe('auto');
    expect(options[1]?.value).toBe('multi');
    expect(options.length).toBe(DEEPGRAM_LANGUAGES.length + 2);
  });

  it('labels the modes as what they are', () => {
    const options = languagePickerOptions();
    // The regression that mattered: `multi` must not be called auto-detection.
    const auto = options.find((o) => o.value === 'auto');
    const multi = options.find((o) => o.value === 'multi');
    expect(auto?.label).toBe('Detect automatically');
    expect(multi?.label).not.toContain('Detect');
    expect(multi?.label).toContain('Multiple languages');
  });

  it('matches a search on English name, native name or code', () => {
    const options = languagePickerOptions();
    const byEnglish = filterLanguageOptions(options, 'german');
    expect(byEnglish.some((o) => o.value === 'de')).toBe(true);
    // Someone who knows the language as "Deutsch" has to find it too.
    expect(filterLanguageOptions(options, 'deutsch').some((o) => o.value === 'de')).toBe(true);
    expect(filterLanguageOptions(options, 'ja').some((o) => o.value === 'ja')).toBe(true);
  });

  it('finds detection and code-switching by description', () => {
    const options = languagePickerOptions();
    expect(filterLanguageOptions(options, 'auto').some((o) => o.value === 'auto')).toBe(true);
    expect(filterLanguageOptions(options, 'sentence').some((o) => o.value === 'multi')).toBe(true);
  });

  it('returns nothing rather than everything for a miss', () => {
    expect(filterLanguageOptions(languagePickerOptions(), 'klingon')).toEqual([]);
  });

  it('returns the full list for an empty or whitespace query', () => {
    const options = languagePickerOptions();
    expect(filterLanguageOptions(options, '')).toHaveLength(options.length);
    expect(filterLanguageOptions(options, '   ')).toHaveLength(options.length);
  });
});

/**
 * The two platforms share a data model, a request shape and a backup format, so a
 * language list that differed between them would mean a term scoped to Japanese on
 * one machine became unscoped on the other.
 */
describe('cross-platform catalogue parity', () => {
  const swiftPath = path.resolve(
    __dirname,
    '../../Sources/UsefulVoiceCore/Transcription/DeepgramLanguage.swift',
  );

  it('matches the macOS catalogue exactly', () => {
    // On a Windows checkout — or any CI job that only checks out `windows/` — the
    // Swift source is absent, so there is nothing to compare against.
    let swift: string;
    try {
      // Normalised, because the macOS catalogue is parsed with regular expressions
      // and a CRLF checkout would change what they match.
      swift = readFileSync(swiftPath, 'utf8').replace(/\r\n/g, '\n');
    } catch {
      return;
    }

    const swiftLangs = [...swift.matchAll(
      /DeepgramLanguage\(code: "([^"]+)", name: "([^"]+)", nativeName: "([^"]+)"\)/g,
    )].map((match) => ({ code: match[1], name: match[2], nativeName: match[3] }));

    expect(swiftLangs.length).toBeGreaterThan(0);
    expect(DEEPGRAM_LANGUAGES.map((l) => ({ code: l.code, name: l.name, nativeName: l.nativeName })))
      .toEqual(swiftLangs);

    const detectionBlock = swift.match(/detectionCodes: \[String\] = \[([\s\S]*?)\]/)?.[1] ?? '';
    const swiftDetection = [...detectionBlock.matchAll(/"([^"]+)"/g)].map((match) => match[1]);
    expect(swiftDetection.length).toBeGreaterThan(0);
    expect([...DETECTION_CODES]).toEqual(swiftDetection);
  });
});
