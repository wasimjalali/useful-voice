import { capitalizeFirstWord } from './categoryContinuation.js';
import { chars, containsNewline, isLetter, isUpper, splitWords, trimWS } from './categoryText.js';

/**
 * Lays a long dictation out as an email. Mirrors
 * `Sources/UsefulVoiceCore/Formatting/CategoryEmail.swift` rule for rule.
 *
 * Restrained on purpose: it only moves what was dictated (and capitalises the first word
 * of each paragraph when it was said in plain lowercase, since it now starts a line). A greeting or sign-off that
 * was not said is never added, and paragraphs are split only at a dictated sign-off or
 * a spoken "new paragraph". The one thing it can add is the user's own name under a
 * dictated sign-off, and only when a non-empty name is passed in.
 */

/**
 * A dictation of at least this many words is laid out as an email even without a greeting or
 * sign-off (so a spoken "new paragraph" works). Shorter ones are laid out only when they
 * open with a greeting or close with a sign-off.
 */
export const EMAIL_LONG_DICTATION_WORDS = 25;

const GREETING_WORDS = new Set(['hi', 'hey', 'hello', 'dear']);

/** Group words a greeting may address in lower case: "Hey team,", "Hello everyone!". */
const GREETING_GROUP_WORDS = new Set([
  'team', 'all', 'everyone', 'everybody', 'there', 'guys', 'folks', 'friends', 'both', 'gang',
]);

/** Titles that carry their own dot inside a greeting: "Dear Dr. Smith,". */
const GREETING_TITLES = new Set(['mr.', 'mrs.', 'ms.', 'dr.', 'prof.']);

/**
 * Capitalised words that are not names: closing words and common sentence openers. A word
 * from this list after a greeting or a sign-off is a sentence, not a person ("Thanks. Bye.").
 * Left out because they are names too: will, may, mark, grace, hope.
 */
const NON_NAME_WORDS = new Set([
  'bye', 'goodbye', 'cheers', 'thanks', 'thank', 'sorry', 'please', 'soon', 'later', 'today',
  'tomorrow', 'tonight', 'again', 'now', 'yes', 'no', 'ok', 'okay', 'sure', 'hello', 'hi', 'hey',
  'regards', 'best', 'sincerely', 'enjoy', 'great', 'good', 'love', 'take', 'see', 'talk', 'speak',
  'night', 'morning', 'evening', 'i', 'it', 'we', 'you', 'he', 'she', 'they', 'the', 'this', 'that',
  'these', 'those', 'there', 'here', 'what', 'when', 'where', 'why', 'how', 'who', 'which', 'can',
  'could', 'would', 'should', 'do', 'does', 'did', 'is', 'are', 'was', 'were', 'have', 'has', 'had',
  'let', 'just', 'also', 'so', 'but', 'and', 'or', 'if', 'then', 'maybe', 'well', 'oh', 'wow',
]);

/** Sign-off phrases, longest first so "best regards" wins over "best". */
const SIGN_OFFS: readonly (readonly string[])[] = [
  ['yours', 'sincerely'],
  ['best', 'regards'],
  ['kind', 'regards'],
  ['warm', 'regards'],
  ['best', 'wishes'],
  ['many', 'thanks'],
  ['thank', 'you'],
  ['thanks'],
  ['best'],
  ['regards'],
  ['cheers'],
  ['sincerely'],
];

/** Stands for a spoken "new paragraph" while the words are being sorted. */
const BREAK = '\u0001';

function endsWithAny(word: string, marks: string): boolean {
  const last = chars(word).at(-1);
  return last !== undefined && marks.includes(last);
}

function stripTrailing(word: string, marks: string): string {
  const cs = chars(word);
  while (cs.length > 0 && marks.includes(cs[cs.length - 1] as string)) cs.pop();
  return cs.join('');
}

/** A capitalised word of letters, or a group word ("team"), that is not a closing or opening word. */
function isGreetingNameWord(word: string): boolean {
  const cs = chars(word);
  if (cs.length === 0 || !cs.every((c) => isLetter(c) || c === '-' || c === "'" || c === '\u2019')) return false;
  const lower = word.toLowerCase();
  if (NON_NAME_WORDS.has(lower)) return false;
  return isUpper(cs[0] as string) || GREETING_GROUP_WORDS.has(lower);
}

/**
 * How many leading words form a greeting ("Hi Sarah," is 2), or 0. The greeting word needs
 * a comma or "!" right after it, or right after one to three name words that follow it.
 * "Hey can you check this, it is urgent." has neither, so it is not a greeting.
 */
function greetingLength(words: string[]): number {
  const first = words[0];
  if (first === undefined || !GREETING_WORDS.has(stripTrailing(first, ',!').toLowerCase())) return 0;
  if (endsWithAny(first, ',!')) return 1;
  for (let n = 1; n <= 3; n++) {
    const word = words[n];
    if (word === undefined) return 0;
    const closes = endsWithAny(word, ',!');
    const core = stripTrailing(word, ',!');
    if (!closes && GREETING_TITLES.has(core.toLowerCase())) continue;
    if (!isGreetingNameWord(core)) return 0;
    if (closes) return n + 1;
  }
  return 0;
}

/** Replaces each spoken "new paragraph" that stands on its own with a BREAK marker. */
function markBreaks(words: string[]): string[] {
  const out: string[] = [];
  let i = 0;
  while (i < words.length) {
    const word = words[i] as string;
    const next = words[i + 1];
    const previous = out.length === 0 ? null : (out[out.length - 1] as string);
    const atBoundary = previous === null || endsWithAny(previous, '.!?,') || previous === BREAK;
    if (
      next !== undefined &&
      word.toLowerCase() === 'new' &&
      stripTrailing(next, '.,!?').toLowerCase() === 'paragraph' &&
      (endsWithAny(next, '.,!?') || i + 1 === words.length - 1) &&
      atBoundary
    ) {
      out.push(BREAK);
      i += 2;
    } else {
      out.push(word);
      i += 1;
    }
  }
  return out;
}

/** A dictated name after a sign-off: letters only, capitalised, and not a closing or opening word. */
function isNameWord(word: string): boolean {
  const cs = chars(word);
  if (cs.length === 0 || !isUpper(cs[0] as string)) return false;
  if (NON_NAME_WORDS.has(word.toLowerCase())) return false;
  return cs.every((c) => isLetter(c) || c === '-');
}

interface SignOff {
  /** Index in the word list where the sign-off phrase starts. */
  start: number;
  phrase: string;
  name: string | null;
}

function findSignOff(words: string[]): SignOff | null {
  for (let start = 1; start < words.length; start++) {
    if (!words.slice(0, start).some((w) => w !== BREAK)) continue;
    const previous = words[start - 1] as string;
    if (previous !== BREAK && !endsWithAny(previous, '.!?')) continue;
    for (const phrase of SIGN_OFFS) {
      const length = phrase.length;
      if (start + length > words.length) continue;
      let matches = true;
      for (let k = 0; k < length; k++) {
        const word = words[start + k] as string;
        const want = phrase[k] as string;
        const comparable = k === length - 1 ? stripTrailing(word, ',.!') : word;
        if (comparable.toLowerCase() !== want) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      const lastWord = words[start + length - 1] as string;
      const after = words.slice(start + length);
      const phraseText = words.slice(start, start + length).join(' ');
      if (after.length === 0) return { start, phrase: phraseText, name: null };
      if (after.length > 3 || !endsWithAny(lastWord, ',.!')) continue;
      const nameWords = after.map((w, idx) => (idx === after.length - 1 ? stripTrailing(w, '.') : w));
      if (!nameWords.every(isNameWord)) continue;
      return { start, phrase: phraseText, name: nameWords.join(' ') };
    }
  }
  return null;
}

/** "Thanks." or "Thanks" becomes "Thanks," when a name line follows. */
function withComma(phrase: string): string {
  const base = stripTrailing(phrase, ',.!');
  return `${base},`;
}

/**
 * Structures a dictation as an email: greeting line, paragraphs, sign-off, and the
 * user's name under a dictated sign-off. Laid out only with an explicit greeting or
 * sign-off, or when long (EMAIL_LONG_DICTATION_WORDS). Returns the text unchanged when
 * it already contains a line break or has nothing to lay out.
 */
export function structureEmail(
  text: string,
  userName: string | null | undefined,
  dictionaryWords: readonly string[] = [],
): string {
  if (containsNewline(text)) return text;
  const spoken = splitWords(text);
  const greetingWords = greetingLength(spoken);
  const greeting = greetingWords > 0 ? spoken.slice(0, greetingWords).join(' ') : null;
  const marked = markBreaks(spoken.slice(greetingWords));
  const hadBreak = marked.includes(BREAK);
  const signOff = findSignOff(marked);
  const isLong = spoken.length >= EMAIL_LONG_DICTATION_WORDS;
  if (greeting === null && signOff === null && !isLong) return text;
  if (greeting === null && signOff === null && !hadBreak) return text;

  const bodyWords = signOff === null ? marked : marked.slice(0, signOff.start);
  const paragraphs: string[] = [];
  let current: string[] = [];
  for (const word of bodyWords) {
    if (word === BREAK) {
      if (current.length > 0) paragraphs.push(current.join(' '));
      current = [];
    } else {
      current.push(word);
    }
  }
  if (current.length > 0) paragraphs.push(current.join(' '));

  const blocks: string[] = [];
  if (greeting !== null) blocks.push(greeting);
  blocks.push(...paragraphs.map((p) => capitalizeFirstWord(p, dictionaryWords)));
  if (signOff !== null) {
    const typedName = userName === null || userName === undefined ? '' : trimWS(userName);
    const name = signOff.name ?? (typedName === '' ? null : typedName);
    if (name === null) {
      blocks.push(signOff.phrase);
    } else {
      blocks.push(`${withComma(signOff.phrase)}\n${name}`);
    }
  }
  return blocks.join('\n\n');
}
