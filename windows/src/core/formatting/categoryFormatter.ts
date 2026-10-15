import { effectiveStyle, type AppCategory, type FormattingStyle } from '../apps/appCategory.js';
import { formatCoding } from './categoryCoding.js';
import { applyContinuation, isAtLineStart, isMidSentence } from './categoryContinuation.js';
import { structureEmail } from './categoryEmail.js';
import { applyStyle } from './categoryStyle.js';
import { trimWS } from './categoryText.js';

/**
 * Per-category formatting of one dictation, as deterministic rules. Mirrors
 * `Sources/UsefulVoiceCore/Formatting/CategoryFormatter.swift` rule for rule.
 *
 * It never invents content: no greeting, sign-off or name that was not dictated (or, for
 * the name, passed in), and it leaves text alone whenever a rule is unsure.
 */

export interface CategoryFormatOptions {
  category: AppCategory;
  /** The user's chosen style for this category; null or undefined means the category default. */
  style?: FormattingStyle | null;
  /** The name for an email sign-off. Only used under a dictated sign-off, and only when not empty. */
  userName?: string | null;
  /** The text just before the cursor. Null or undefined means unknown. */
  textBeforeCursor?: string | null;
  dictionaryWords?: readonly string[];
}

export function formatForCategory(dictation: string, options: CategoryFormatOptions): string {
  if (trimWS(dictation) === '') return dictation;
  const words = options.dictionaryWords ?? [];
  const before = options.textBeforeCursor ?? null;

  if (options.category === 'coding') {
    return applyContinuation(before, formatCoding(dictation), words, { lowercase: false, code: true });
  }

  let text = dictation;
  if (options.category === 'email') {
    // A greeting and sign-off belong at the start of a line, never inside a sentence.
    const startsLine = before === null || isAtLineStart(before);
    if (startsLine && !isMidSentence(before)) {
      text = structureEmail(text, options.userName, words);
    }
  }
  text = applyStyle(text, effectiveStyle(options.style, options.category), words);
  return applyContinuation(before, text, words);
}
