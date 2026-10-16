import { chars, isAlnum, isLetter, isNewline, isUpper, isWS, splitWords } from './categoryText.js';

/**
 * Continuation awareness: look at the text just before the cursor and fit the dictation
 * to it. Mirrors `Sources/UsefulVoiceCore/Formatting/CategoryContinuation.swift`.
 *
 * Mid-sentence, the first word is not capitalised, but only when it is a common sentence
 * opener ("The", "And", "We"). Any other word may be a name ("Sarah", "Dr.", "A.I."), so
 * it keeps its case. A leading space is added only when the join needs one. Unknown
 * context (null) leaves the dictation unchanged.
 */

/**
 * The only words whose first letter is lowercased. A closed list on purpose: lowercasing
 * an unknown capitalised word risks damaging a name. Left out because they are names too:
 * will, may, mark, bill, hope, grace. "I" and its contractions are never lowercased.
 */
export const SENTENCE_OPENERS: ReadonlySet<string> = new Set([
  'the', 'a', 'an', 'and', 'but', 'or', 'so', 'if', 'because', 'while', 'although', 'though',
  'since', 'unless', 'until', 'when', 'where', 'what', 'who', 'whom', 'whose', 'which', 'why', 'how',
  'that', 'this', 'these', 'those', 'it', 'its', 'he', 'she', 'we', 'you', 'they', 'them', 'him',
  'her', 'us', 'me', 'my', 'your', 'our', 'their', 'his', 'there', 'here', 'then', 'now', 'also',
  'just', 'maybe', 'perhaps', 'still', 'even', 'only', 'really', 'very', 'actually', 'basically',
  'honestly', 'sure', 'yes', 'yeah', 'yep', 'nope', 'no', 'not', 'okay', 'ok', 'thanks', 'thank',
  'sorry', 'please', 'can', 'could', 'would', 'should', 'do', 'does', 'did', 'is', 'are', 'was',
  'were', 'am', 'be', 'have', 'has', 'had', 'let', 'got', 'get', 'need', 'want', 'like', 'love',
  'think', 'feel', 'see', 'look', 'looks', 'sounds', 'sound', 'wait', 'check', 'send', 'call', 'come',
  'go', 'going', 'take', 'make', 'try', 'tell', 'ask', 'give', 'to', 'for', 'of', 'in', 'on', 'at',
  'by', 'with', 'from', 'about', 'as', 'into', 'after', 'before', 'some', 'any', 'all', 'each',
  'every', 'both', 'many', 'much', 'more', 'most', 'other', 'another', 'such', 'oh', 'ah', 'hmm',
  'wow', 'lol', 'haha',
  "it's", "that's", "there's", "here's", "what's", "who's", "he's", "she's", "let's", "we're",
  "you're", "they're", "we'll", "you'll", "they'll", "we've", "you've", "they've", "don't",
  "doesn't", "didn't", "can't", "won't", "isn't", "aren't", "wasn't", "weren't", "couldn't",
  "wouldn't", "shouldn't", "haven't", "hasn't", "hadn't",
]);

const SENTENCE_ENDS = new Set(['.', '!', '?', ':']);
/** Closing marks that can follow the full stop that ends a sentence. */
const CLOSERS = new Set(['"', "'", '”', '’', ')', ']']);
const OPENERS = new Set(['(', '[', '{', '“', '‘', '«']);
/** A cursor right after one of these has nothing to space away from: paths, mentions, prices, tags. */
const NO_SPACE_AFTER = new Set(['/', '\\', '@', '#', '$', '~']);
/** In code the join is usually part of a name or a path: `foo.`, `snake_`, `--`, `key:`. */
const CODE_NO_SPACE_AFTER = new Set(['.', '_', '-', ':']);
/** Punctuation that attaches to the text before it, so the dictation starting with it needs no space. */
const ATTACH_FIRST = new Set([
  '.', ',', ';', ':', '!', '?', ')', ']', '}', '%', '…', '”', '’', "'",
]);
/** What can follow a sentence opener word: the word is then a whole word, not part of "A.I." or "A/B". */
const AFTER_WORD = new Set([',', ';', ':', '!', '?', ')', ']', '}', '"', '”', '…']);
/** A line that holds only one of these is an empty list item: the cursor is at the start of its text. */
const BULLETS = new Set(['-', '*', '•', '–', '>']);

/** A straight quote opens when it follows whitespace, an opening mark, "=" or "|", or starts the text. */
function isOpeningQuoteAt(cs: string[], index: number): boolean {
  if (index === 0) return true;
  const prev = cs[index - 1] as string;
  return isWS(prev) || OPENERS.has(prev) || prev === '=' || prev === '|';
}

/** Whether the cursor sits in the middle of a sentence. False for empty or unknown context. */
export function isMidSentence(textBeforeCursor: string | null | undefined): boolean {
  if (textBeforeCursor === null || textBeforeCursor === undefined) return false;
  const cs = chars(textBeforeCursor);
  let j = cs.length - 1;
  // Whitespace before the cursor; a line break means the cursor starts a line.
  while (j >= 0 && isWS(cs[j] as string)) {
    if (isNewline(cs[j] as string)) return false;
    j--;
  }
  if (j < 0) return false;
  // Look through brackets and opening single quotes: judge the text before them.
  for (;;) {
    const c = cs[j] as string;
    // A quotation starts its own sentence: 'He said "' then "The end." keeps its capital.
    if (c === '\u201C' || (c === '"' && isOpeningQuoteAt(cs, j))) return false;
    const opening = OPENERS.has(c) || ((c === '"' || c === "'") && isOpeningQuoteAt(cs, j));
    if (!opening) break;
    j--;
    while (j >= 0 && isWS(cs[j] as string)) {
      if (isNewline(cs[j] as string)) return false;
      j--;
    }
    if (j < 0) return false;
  }
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
 * Lowercases the first letter of the first word, but only when that word is a common
 * sentence opener (see SENTENCE_OPENERS). "I" and I'm are kept, as are acronyms, words
 * with inner capitals ("iPhone"), words followed by a dot that is part of the word
 * ("A.I.", "Dr. Smith" is not an opener anyway) and dictionary words. Everything else,
 * including every name, is returned as is.
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
  if (!endsWholeWord(cs, i, end)) return text;
  if (!SENTENCE_OPENERS.has(word.toLowerCase().replaceAll('’', "'"))) return text;
  if (isDictionaryWord(word, dictionaryWords)) return text;
  return cs.slice(0, i).join('') + (cs[i] as string).toLowerCase() + cs.slice(i + 1).join('');
}

function endsWholeWord(cs: string[], start: number, end: number): boolean {
  if (end >= cs.length) return true;
  const c = cs[end] as string;
  if (isWS(c)) return true;
  if (c === '.') {
    // "Yes." ends a word; "A." is an initial and "A.I." an abbreviation.
    const after = cs[end + 1];
    return end - start >= 2 && (after === undefined || isWS(after));
  }
  return AFTER_WORD.has(c);
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
  return (last === '"' || last === "'") && isOpeningQuoteAt(cs, cs.length - 1);
}

/** Whether one space must go between the text before the cursor and the dictation. */
export function needsLeadingSpace(
  textBeforeCursor: string,
  dictation: string,
  options: { code?: boolean } = {},
): boolean {
  const before = chars(textBeforeCursor);
  const first = chars(dictation)[0];
  if (before.length === 0 || first === undefined) return false;
  if (isWS(first) || ATTACH_FIRST.has(first)) return false;
  const last = before[before.length - 1] as string;
  if (isWS(last) || OPENERS.has(last) || NO_SPACE_AFTER.has(last)) return false;
  if (options.code === true && CODE_NO_SPACE_AFTER.has(last)) return false;
  if (endsInOpeningQuote(before)) return false;
  return true;
}

export interface ContinuationOptions {
  /** Lowercase the first word when mid-sentence. Coding turns this off to keep text as dictated. */
  lowercase?: boolean;
  /** Text in a code context: no space after ".", "_", "-" or ":". */
  code?: boolean;
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
  if (needsLeadingSpace(textBeforeCursor, out, { code: options.code ?? false })) out = ` ${out}`;
  return out;
}
