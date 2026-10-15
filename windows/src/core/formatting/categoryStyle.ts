import type { FormattingStyle } from '../apps/appCategory.js';
import { lowercaseFirstWord } from './categoryContinuation.js';
import { chars, containsNewline, isWS } from './categoryText.js';

/**
 * Formal / Casual / Very casual. Mirrors
 * `Sources/UsefulVoiceCore/Formatting/CategoryStyle.swift` rule for rule.
 *
 * Formal leaves the text as is. Casual drops the closing full stop of a one-sentence
 * message (never a ? or !). Very casual does that and lowercases the first letter.
 */

/**
 * Drops the final "." of a single-sentence message. Left alone when: there is a line
 * break, another sentence ends inside the text, the text ends in "..", or the last word
 * has a dot inside it ("p.m.", "e.g.", "3.5.", "index.ts.").
 */
export function dropTrailingFullStop(text: string): string {
  if (containsNewline(text)) return text;
  const cs = chars(text);
  let end = cs.length;
  while (end > 0 && isWS(cs[end - 1] as string)) end--;
  if (end === 0 || cs[end - 1] !== '.') return text;
  if (end >= 2 && cs[end - 2] === '.') return text;
  const stem = cs.slice(0, end - 1);
  if (stem.length === 0) return text;
  for (let i = 0; i < stem.length; i++) {
    const c = stem[i] as string;
    if (c !== '.' && c !== '!' && c !== '?') continue;
    const next = stem[i + 1];
    if (next === undefined || isWS(next)) return text;
  }
  let wordStart = stem.length;
  while (wordStart > 0 && !isWS(stem[wordStart - 1] as string)) wordStart--;
  if (stem.slice(wordStart).includes('.')) return text;
  return stem.join('') + cs.slice(end).join('');
}

/** Applies an already-resolved style (see `effectiveStyle`). */
export function applyStyle(
  text: string,
  style: FormattingStyle,
  dictionaryWords: readonly string[],
): string {
  if (style === 'formal') return text;
  const dropped = dropTrailingFullStop(text);
  if (style === 'casual') return dropped;
  return lowercaseFirstWord(dropped, dictionaryWords);
}
