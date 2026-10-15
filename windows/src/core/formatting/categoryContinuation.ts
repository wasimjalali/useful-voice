import { chars, isAlnum, isLetter, isNewline, isUpper, isWS, splitWords } from './categoryText.js';

/**
 * Continuation awareness: look at the text just before the cursor and fit the dictation
 * to it. Mirrors `Sources/UsefulVoiceCore/Formatting/CategoryContinuation.swift`.
 *
 * Mid-sentence, the first word is not capitalised. A leading space is added only when
 * the join needs one. Unknown context (null) leaves the dictation unchanged.
 */

const SENTENCE_ENDS = new Set(['.', '!', '?', ':']);
/** Closing marks that can follow the full stop that ends a sentence. */
const CLOSERS = new Set(['"', "'", '”', '’', ')', ']']);
const OPENERS = new Set(['(', '[', '{', '“', '‘', '«']);
/** A cursor right after one of these has nothing to space away from: paths, mentions, prices, tags. */
const NO_SPACE_AFTER = new Set(['/', '\\', '@', '#', '$', '~']);
/** Punctuation that attaches to the text before it, so the dictation starting with it needs no space. */
const ATTACH_FIRST = new Set([
  '.', ',', ';', ':', '!', '?', ')', ']', '}', '%', '…', '”', '’', "'",
]);
/** A line that holds only one of these is an empty list item: the cursor is at the start of its text. */
const BULLETS = new Set(['-', '*', '•', '–', '>']);

/** Whether the cursor sits in the middle of a sentence. False for empty or unknown context. */
export function isMidSentence(textBeforeCursor: string | null | undefined): boolean {
  if (textBeforeCursor === null || textBeforeCursor === undefined) return false;
  const cs = chars(textBeforeCursor);
  let j = cs.length - 1;
  let sawNewline = false;
  while (j >= 0 && isWS(cs[j] as string)) {
    if (isNewline(cs[j] as string)) sawNewline = true;
    j--;
  }
  if (j < 0 || sawNewline) return false;
  let k = j;
  while (k >= 0 && CLOSERS.has(cs[k] as string)) k--;
  if (k >= 0 && SENTENCE_ENDS.has(cs[k] as string)) return false;
  if (BULLETS.has(cs[j] as string)) {
    let lineStart = j;
    while (lineStart > 0 && !isNewline(cs[lineStart - 1] as string)) lineStart--;
    if (cs.slice(lineStart, j).every(isWS)) return false;
  }
  return true;
}

/** Whether the cursor sits at the start of a line (or in empty text). Unknown context is not. */
export function isAtLineStart(textBeforeCursor: string | null | undefined): boolean {
  if (textBeforeCursor === null || textBeforeCursor === undefined) return false;
  const cs = chars(textBeforeCursor);
  let j = cs.length - 1;
  while (j >= 0 && isWS(cs[j] as string)) {
    if (isNewline(cs[j] as string)) return true;
    j--;
  }
  return j < 0;
}

function isWordChar(c: string): boolean {
  return isAlnum(c) || c === "'" || c === '’' || c === '-';
}

/**
 * Lowercases the first letter of the first word, unless that word is "I" (or I'm, I'll),
 * an acronym, has inner capitals, or is one of the dictionary words. Anything that does
 * not start with an uppercase letter is returned as is.
 */
export function lowercaseFirstWord(text: string, dictionaryWords: readonly string[]): string {
  const cs = chars(text);
  let i = 0;
  while (i < cs.length && isWS(cs[i] as string)) i++;
  if (i >= cs.length || !isUpper(cs[i] as string)) return text;
  let end = i;
  while (end < cs.length && isWordChar(cs[end] as string)) end++;
  const wordChars = cs.slice(i, end);
  const word = wordChars.join('');
  if (word === 'I' || word.startsWith("I'") || word.startsWith('I’')) return text;
  if (wordChars.filter(isUpper).length >= 2) return text;
  if (isDictionaryWord(word, dictionaryWords)) return text;
  return cs.slice(0, i).join('') + (cs[i] as string).toLowerCase() + cs.slice(i + 1).join('');
}

/** Whether the word is a dictionary word, or the first word of a multi-word entry. Case-insensitive. */
function isDictionaryWord(word: string, dictionaryWords: readonly string[]): boolean {
  let core = word;
  while (core.endsWith("'") || core.endsWith('’') || core.endsWith('-')) core = core.slice(0, -1);
  // Swift compares strings by canonical equivalence, so compare composed forms here.
  const lower = word.toLowerCase().normalize('NFC');
  const lowerCore = core.toLowerCase().normalize('NFC');
  for (const entry of dictionaryWords) {
    const first = (splitWords(entry)[0] ?? '').toLowerCase().normalize('NFC');
    if (first !== '' && (first === lower || first === lowerCore)) return true;
  }
  return false;
}

/**
 * Capitalises the first letter of the first word when that word is plain lowercase
 * ("thanks"). A word with any capital ("iPhone") or in the dictionary is left as is.
 */
export function capitalizeFirstWord(text: string, dictionaryWords: readonly string[]): string {
  const cs = chars(text);
  let i = 0;
  while (i < cs.length && isWS(cs[i] as string)) i++;
  if (i >= cs.length) return text;
  const first = cs[i] as string;
  if (!isLetter(first) || first.toUpperCase() === first) return text;
  let end = i;
  while (end < cs.length && isWordChar(cs[end] as string)) end++;
  const word = cs.slice(i, end).join('');
  if (cs.slice(i, end).some(isUpper)) return text;
  if (isDictionaryWord(word, dictionaryWords)) return text;
  return cs.slice(0, i).join('') + first.toUpperCase() + cs.slice(i + 1).join('');
}

function endsInOpeningQuote(cs: string[]): boolean {
  const last = cs[cs.length - 1] as string;
  if (last !== '"' && last !== "'") return false;
  if (cs.length < 2) return true;
  const prev = cs[cs.length - 2] as string;
  return isWS(prev) || OPENERS.has(prev) || prev === '=' || prev === '|';
}

/** Whether one space must go between the text before the cursor and the dictation. */
export function needsLeadingSpace(textBeforeCursor: string, dictation: string): boolean {
  const before = chars(textBeforeCursor);
  const first = chars(dictation)[0];
  if (before.length === 0 || first === undefined) return false;
  if (isWS(first) || ATTACH_FIRST.has(first)) return false;
  const last = before[before.length - 1] as string;
  if (isWS(last) || OPENERS.has(last) || NO_SPACE_AFTER.has(last)) return false;
  if (endsInOpeningQuote(before)) return false;
  return true;
}

export interface ContinuationOptions {
  /** Lowercase the first word when mid-sentence. Coding turns this off to keep text as dictated. */
  lowercase?: boolean;
}

/**
 * Fits the dictation to the text before the cursor.
 * `textBeforeCursor` null means unknown: the dictation is returned unchanged.
 */
export function applyContinuation(
  textBeforeCursor: string | null | undefined,
  dictation: string,
  dictionaryWords: readonly string[],
  options: ContinuationOptions = {},
): string {
  if (textBeforeCursor === null || textBeforeCursor === undefined) return dictation;
  if (dictation === '') return dictation;
  let out = dictation;
  if ((options.lowercase ?? true) && isMidSentence(textBeforeCursor)) {
    out = lowercaseFirstWord(out, dictionaryWords);
  }
  if (needsLeadingSpace(textBeforeCursor, out)) out = ` ${out}`;
  return out;
}
