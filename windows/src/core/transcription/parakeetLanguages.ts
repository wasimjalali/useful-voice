import type { ParakeetVersion } from '../models/parakeet.js';
import { DEEPGRAM_LANGUAGES } from './languages.js';

/** The 25 European languages Parakeet v3 speaks (the model card's list). */
export const PARAKEET_V3_LANGUAGES: readonly string[] = [
  'bg', 'hr', 'cs', 'da', 'nl', 'en', 'et', 'fi', 'fr', 'de', 'el', 'hu', 'it', 'lv', 'lt', 'mt', 'pl', 'pt', 'ro',
  'ru', 'sk', 'sl', 'es', 'sv', 'uk',
];

/**
 * Why a language pin can't be used with a Parakeet model, or null when it can. Checked before
 * a byte reaches the model, so a wrong pin gets a clear message instead of garbage text.
 * Auto and Multi pass: the model decides.
 */
export function parakeetLanguageProblem(version: ParakeetVersion, pin: string): string | null {
  if (pin === 'auto' || pin === 'multi') return null;
  const base = pin.split('-')[0]?.toLowerCase() ?? '';
  if (version === 'v2') {
    return base === 'en'
      ? null
      : 'Parakeet only speaks English. Pick Parakeet Multilingual or another voice model, or switch the language to English.';
  }
  if (PARAKEET_V3_LANGUAGES.includes(base)) return null;
  const name = DEEPGRAM_LANGUAGES.find((language) => language.code === pin)?.name ?? pin;
  return `Parakeet Multilingual doesn't cover ${name}. Pick another voice model or another language.`;
}
