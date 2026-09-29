/**
 * Number style for Deepgram Smart Format output. Mirrors
 * `Sources/UsefulVoiceCore/Formatting/TranscriptStyle.swift`.
 *
 * `numerals=true` used to be sent to get digits, but it turned every spoken number
 * into digits, so "the first numbers" became "the 1st numbers". Without it English
 * already writes small numbers and ordinals as words, so English only needs version
 * and model numbers kept as digits. German Smart Format digitises regardless, so
 * German small numbers and ordinals are put back into words here.
 *
 * Every rule leaves the text alone when it is unsure: a wrong digit is better than
 * a wrong word. Nothing here adds, drops or reorders what was said.
 */

export function applyTranscriptStyle(text: string, language: string | null | undefined): string {
  const code = language?.toLowerCase();
  if (!code) return text;
  if (code === 'en' || code.startsWith('en-')) return english(text);
  if (code === 'de' || code.startsWith('de-')) return german(text);
  return text;
}

const ENGLISH_NUMBERS: Record<string, string> = {
  one: '1', two: '2', three: '3', four: '4', five: '5',
  six: '6', seven: '7', eight: '8', nine: '9', ten: '10',
};
const ENGLISH_WORDS = Object.keys(ENGLISH_NUMBERS).join('|');

/** "version two" -> "version 2", "GPT-five" -> "GPT-5". */
function english(text: string): string {
  return text
    .replace(
      new RegExp(`\\b([Vv]ersion)(\\s+)(${ENGLISH_WORDS})\\b`, 'g'),
      (_m, word: string, space: string, n: string) => `${word}${space}${ENGLISH_NUMBERS[n]}`,
    )
    .replace(
      new RegExp(`\\b([A-Z]{2,5})([- ])(${ENGLISH_WORDS})\\b`, 'g'),
      (_m, code: string, sep: string, n: string) => `${code}${sep}${ENGLISH_NUMBERS[n]}`,
    );
}

const GERMAN_CARDINALS: Record<number, string> = {
  2: 'zwei', 3: 'drei', 4: 'vier', 5: 'fünf', 6: 'sechs', 7: 'sieben', 8: 'acht', 9: 'neun',
};
const GERMAN_ORDINAL_STEMS: Record<number, string> = {
  1: 'erst', 2: 'zweit', 3: 'dritt', 4: 'viert', 5: 'fünft',
  6: 'sechst', 7: 'siebt', 8: 'acht', 9: 'neunt',
};
/**
 * Words after which an ordinal has a certain ending. Only the unambiguous articles
 * are listed: "der" and "die" can be masculine, feminine or plural, and a wrong
 * ending would change a word the speaker said.
 */
const ORDINAL_ENDINGS: Record<string, string> = {
  das: 'e',
  den: 'en', dem: 'en', des: 'en',
  am: 'en', im: 'en', zum: 'en', beim: 'en', vom: 'en', zur: 'en',
};
const MONTHS = new Set([
  'januar', 'jänner', 'februar', 'märz', 'april', 'mai', 'juni', 'juli', 'august',
  'september', 'oktober', 'november', 'dezember',
]);
/** A digit before one of these is a measurement or a clock time, so it stays. */
const UNITS = new Set([
  'uhr', 'euro', 'cent', 'dollar', 'franken', 'pfund', 'prozent', 'grad',
  'gigabyte', 'megabyte', 'kilobyte', 'terabyte', 'gb', 'mb', 'kb', 'tb',
  'kilometer', 'km', 'meter', 'm', 'zentimeter', 'cm', 'millimeter', 'mm',
  'kilogramm', 'kg', 'gramm', 'g', 'liter', 'l', 'ml', 'watt', 'volt',
]);
/** A digit or decimal after one of these is a date ("am 3.5.") or a range. */
const DATE_LEAD_INS = new Set(['am', 'bis', 'ab', 'vom', 'seit', 'zum', 'dem']);

// JS `\w` is ASCII-only, which would treat "ä" as a word boundary.
const W = '[\\p{L}\\p{N}_]';

function german(text: string): string {
  return germanSmallNumbers(germanDecimals(text));
}

function isNumber(char: string | undefined): boolean {
  return char !== undefined && /\p{N}/u.test(char);
}

function previousWord(before: string): string | null {
  const trimmed = before.replace(/[ \t]+$/u, '');
  const match = /[\p{L}\p{N}-]+$/u.exec(trimmed);
  return match ? match[0] : null;
}

function nextWord(after: string): string | null {
  const match = /^ *(\p{L}+)/u.exec(after);
  return match ? match[1]! : null;
}

/** "3.5" -> "3,5". Left alone after a capitalised word and after a date lead-in. */
function germanDecimals(text: string): string {
  const pattern = new RegExp(`(?<!${W}|[.,])(\\d+)\\.(\\d{1,2})(?!${W}|[.,])`, 'gu');
  return text.replace(pattern, (match, whole: string, fraction: string, offset: number) => {
    const prev = previousWord(text.slice(0, offset));
    if (prev && (/^\p{Lu}/u.test(prev) || /\p{N}/u.test(prev))) return match;
    if (prev && DATE_LEAD_INS.has(prev.toLowerCase())) return match;
    return `${whole},${fraction}`;
  });
}

/** "2 Fragen" -> "zwei Fragen", "das 1. Kapitel" -> "das erste Kapitel". */
function germanSmallNumbers(text: string): string {
  const pattern = new RegExp(
    `(?<!${W}|[.,:/+\\-–%€$£#@])(\\d)(\\.)?(?!${W}|[:/%°€$£+\\-–]|[.,]\\d)`,
    'gu',
  );
  return text.replace(pattern, (match, digitText: string, dot: string | undefined, offset: number) => {
    const digit = Number(digitText);
    const ordinal = dot !== undefined;
    const before = text.slice(0, offset).replace(/[ \t]+$/u, '');
    const after = text.slice(offset + match.length);

    // Lists and ranges of digits ("1, 2, 3", "2 3", "5 - 7") stay digits.
    if (isNumber(before.at(-1))) return match;
    if (before.endsWith(',') && isNumber(before.at(-2))) return match;
    const afterTrimmed = after.replace(/^ +/u, '');
    const first = afterTrimmed[0];
    if (first !== undefined && (isNumber(first) || '-–/'.includes(first))) return match;
    if (afterTrimmed.startsWith(',') && isNumber(afterTrimmed.slice(1).replace(/^ +/u, '')[0])) return match;

    const atSentenceStart = before === '' || '.!?'.includes(before.at(-1)!);
    const prev = previousWord(before);

    if (ordinal) {
      // Needs a following word; "3." at the end of a sentence is ambiguous.
      if (!after.startsWith(' ')) return match;
      const next = nextWord(after);
      const ending = prev ? ORDINAL_ENDINGS[prev.toLowerCase()] : undefined;
      const stem = GERMAN_ORDINAL_STEMS[digit];
      if (!next || ending === undefined || stem === undefined) return match;
      const lower = next.toLowerCase();
      if (MONTHS.has(lower) || ['bis', 'und', 'oder'].includes(lower)) return match;
      return stem + ending;
    }

    const word = GERMAN_CARDINALS[digit];
    if (word === undefined) return match;
    if (!atSentenceStart && prev && /^\p{Lu}/u.test(prev)) return match;
    const next = nextWord(after);
    if (next && UNITS.has(next.toLowerCase())) return match;
    return atSentenceStart ? word.charAt(0).toUpperCase() + word.slice(1) : word;
  });
}
