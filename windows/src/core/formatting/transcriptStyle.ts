/**
 * Number style for Deepgram Smart Format output. Mirrors
 * `Sources/UsefulVoiceCore/Formatting/TranscriptStyle.swift` rule for rule.
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
const ENGLISH_VERBS = 'is|was';

/**
 * "version two" -> "version 2", "GPT-five" -> "GPT-5". The number after the word
 * "version" or a hyphenated all-caps product code is a name, not a quantity.
 * "version" only counts when the number ends the phrase or is followed by "is" or
 * "was" ("version two is out"), so "version one users", "the version one would
 * expect" and "version two and three" are left as spoken. A bare acronym followed by a number
 * ("the API one more time") is never touched.
 */
function english(text: string): string {
  return text
    .replace(
      new RegExp(
        `(?<![\\p{L}\\p{N}_])([Vv]ersion)(\\s+)(${ENGLISH_WORDS})(?!\\s*,?\\s*(?:and|or)\\s+(?:${ENGLISH_WORDS})(?![\\p{L}\\p{N}_]))(?=\\s*(?:[.,;:!?)]|$)|\\s+(?:${ENGLISH_VERBS})(?![\\p{L}\\p{N}_]))`,
        'gu',
      ),
      (_m, word: string, space: string, n: string) => `${word}${space}${ENGLISH_NUMBERS[n]}`,
    )
    .replace(
      new RegExp(
        `(?<![\\p{L}\\p{N}_])(?!(?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN)-)([A-Z]{3,5})(-)(${ENGLISH_WORDS})(?![\\p{L}\\p{N}_])(?!-)`,
        'gu',
      ),
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
 * ending would change a word the speaker said. "am" and "vom" are left out on
 * purpose: "am 3." is usually a date that ends a sentence ("am 3. Danach essen wir."),
 * and a date is not an ordinal to spell out.
 */
const ORDINAL_ENDINGS: Record<string, string> = {
  das: 'e',
  den: 'en', dem: 'en', des: 'en',
  im: 'en', zum: 'en', beim: 'en', zur: 'en',
};
const MONTHS = new Set([
  'januar', 'jänner', 'februar', 'märz', 'april', 'mai', 'juni', 'juli', 'august',
  'september', 'oktober', 'november', 'dezember',
  'jan', 'feb', 'mär', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'okt', 'nov', 'dez',
]);
/** A digit before one of these is a measurement, a price or a clock time, so it stays. */
const UNITS = new Set([
  'uhr', 'euro', 'cent', 'dollar', 'franken', 'pfund', 'prozent', 'grad',
  'gigabyte', 'megabyte', 'kilobyte', 'terabyte', 'gb', 'mb', 'kb', 'tb',
  'kilometer', 'km', 'meter', 'm', 'zentimeter', 'cm', 'millimeter', 'mm',
  'kilogramm', 'kg', 'gramm', 'g', 'liter', 'l', 'ml', 'watt', 'volt',
  'kwh', 'ps', 'h', 'std', 'min', 'mio', 'mrd', 'x', 'chf', 'eur', 'usd', 'gbp', 'tsd', 'pkt',
]);
/**
 * The only words after which "3.5" becomes "3,5". Deliberately not "Uhr": "10.30 Uhr"
 * is a time. A decimal anywhere else could be a section number or a version.
 */
const DECIMAL_UNITS = new Set([
  ...[...UNITS].filter((unit) => unit !== 'uhr' && unit !== 'x'),
  'stunden', 'minuten', 'sekunden', 'tage', 'tagen', 'wochen', 'monate', 'monaten',
  'jahre', 'jahren', 'millionen', 'milliarden', 'tonnen', 'kilo', 'prozentpunkte',
]);
/**
 * A decimal after one of these is a date, a clock time, a range or a comparison
 * ("am 3.5.", "von 2.5 auf 3.5 Prozent"), so it stays.
 */
const DATE_OR_RANGE_LEAD_INS = new Set([
  'am', 'bis', 'ab', 'vom', 'seit', 'zum', 'dem', 'um', 'gegen', 'von', 'zwischen', 'x',
  'auf', 'zu', 'und', 'oder',
]);
/**
 * A small cardinal becomes a word only after one of these, which clearly take a
 * quantity ("habe 2 Katzen", "in 2 Wochen"). After anything else it could be a product
 * ("iOS 9", "iPad 2"), a label ("die 7"), a street number, a version or one half of a
 * range, and the digit stays. Determiners are left out on purpose.
 */
const QUANTITY_LEAD_INS = new Set([
  'habe', 'hast', 'hat', 'haben', 'habt', 'hatte', 'hatten', 'sind', 'waren', 'gibt', 'gab',
  'brauche', 'brauchst', 'braucht', 'brauchen', 'nur', 'noch', 'schon', 'bereits', 'mit', 'für',
  'in', 'nach', 'vor', 'seit', 'über', 'etwa', 'ungefähr', 'fast', 'knapp', 'genau', 'sogar',
]);
/** A bare number before one of these is half of a range, score, sum or comparison. */
const RANGE_FOLLOWERS = new Set([
  'bis', 'von', 'gegen', 'zu', 'auf', 'und', 'oder', 'statt', 'anstatt', 'vor', 'nach',
  'mal', 'plus', 'minus', 'durch', 'kommt',
]);
/**
 * A word that starts the next sentence. An ordinal followed by one is a date or a number
 * that ended a sentence ("im 5. Das merkt man."), not "im fünften Das".
 */
const SENTENCE_STARTERS = new Set([
  'das', 'der', 'die', 'er', 'sie', 'es', 'wir', 'ihr', 'ich', 'du', 'man', 'dann', 'danach',
  'dort', 'hier', 'also', 'aber', 'doch', 'jetzt', 'heute', 'morgen', 'später', 'zuerst',
  'wenn', 'weil', 'dass', 'ob', 'wie', 'was', 'wer', 'wo', 'wann', 'warum', 'nun', 'nur',
  'noch', 'schon', 'ja', 'nein', 'vielleicht', 'leider', 'bitte', 'danke', 'ok', 'okay',
  'gut', 'dabei', 'davor', 'zuletzt', 'zum', 'im', 'am', 'in',
]);
const SYMBOLS_AFTER = new Set('%€$£°§+×*=÷-–/:');
const SYMBOLS_BEFORE = new Set('€$£§#№-–—/+×*=÷:');

// JS `\w` is ASCII-only, which would treat "ä" as a word boundary.
const W = '[\\p{L}\\p{N}_]';
// Swift's `.whitespaces` includes no-break spaces; `[ \t]` would not.
const TRAILING_BLANKS = /[\p{Zs}\t]+$/u;

function german(text: string): string {
  return germanSmallNumbers(germanDecimals(text));
}

function isNumber(char: string | undefined): boolean {
  return char !== undefined && /\p{N}/u.test(char);
}

function isLetterOrNumber(char: string | undefined): boolean {
  return char !== undefined && /[\p{L}\p{N}]/u.test(char);
}

function previousWord(before: string): string | null {
  const trimmed = before.replace(TRAILING_BLANKS, '');
  if (!isLetterOrNumber(trimmed.at(-1))) return null;
  const match = /[\p{L}\p{N}-]+$/u.exec(trimmed);
  return match ? match[0] : null;
}

function nextWord(after: string): string | null {
  const match = /^ *(\p{L}+)/u.exec(after);
  return match ? match[1]! : null;
}

/**
 * "3.5 Gigabyte" -> "3,5 Gigabyte". Only before a unit or quantity word, and not after
 * a capitalised word, digit or hyphen ("Version 3.5", "GPT-4.5").
 */
function germanDecimals(text: string): string {
  const pattern = new RegExp(`(?<!${W}|[.,\\-])(\\d+)\\.(\\d{1,2})(?!${W}|[.,])`, 'gu');
  return text.replace(pattern, (match, whole: string, fraction: string, offset: number) => {
    const next = nextWord(text.slice(offset + match.length));
    if (!next || !DECIMAL_UNITS.has(next.toLowerCase())) return match;
    const prev = previousWord(text.slice(0, offset));
    if (prev && (/^\p{Lu}/u.test(prev) || /\p{N}/u.test(prev))) return match;
    if (prev && DATE_OR_RANGE_LEAD_INS.has(prev.toLowerCase())) return match;
    return `${whole},${fraction}`;
  });
}

const SMALL_NUMBER_PATTERN = new RegExp(
  `(?<!${W}|[.,:/+\\-–%€$£#@])(\\d)(\\.)?(?!${W}|[:/%°€$£+\\-–]|[.,]\\d|\\.\\p{L})`,
  'gu',
);
// A full stop right after a digit is an ordinal dot, not a sentence end.
const SENTENCE_BOUNDARY = /(?<!\d)[.!?]+(?=\s|$)/gu;

/**
 * "2 Fragen" -> "zwei Fragen", "das 1. Kapitel" -> "das erste Kapitel".
 *
 * All or nothing per sentence: if any single digit in a sentence cannot be turned into a
 * word safely, none of that sentence's single digits are. That is what keeps lists,
 * ranges, scores and "die 3 ... die 4" from coming out half converted.
 */
function germanSmallNumbers(text: string): string {
  const matches = [...text.matchAll(SMALL_NUMBER_PATTERN)];
  if (matches.length === 0) return text;
  const boundaries = [...text.matchAll(SENTENCE_BOUNDARY)].map((m) => m.index! + m[0].length);

  const converted = new Set<number>();
  const decisions = matches.map((match) => {
    const start = match.index!;
    const chunk = boundaries.filter((boundary) => boundary <= start).length;
    const replacement = smallNumberWord(
      Number(match[1]),
      match[2] !== undefined,
      text.slice(0, start),
      text.slice(start + match[0].length),
      converted.has(chunk),
    );
    if (replacement !== null) converted.add(chunk);
    return { start, length: match[0].length, replacement, chunk };
  });
  const blocked = new Set(decisions.filter((d) => d.replacement === null).map((d) => d.chunk));

  let result = text;
  for (const d of [...decisions].reverse()) {
    if (d.replacement === null || blocked.has(d.chunk)) continue;
    result = result.slice(0, d.start) + d.replacement + result.slice(d.start + d.length);
  }
  return result;
}

/** The word for one digit, or null when it must stay a digit. */
function smallNumberWord(
  digit: number,
  ordinal: boolean,
  rawBefore: string,
  after: string,
  afterConvertedNumber: boolean,
): string | null {
  const before = rawBefore.replace(TRAILING_BLANKS, '');
  const afterTrimmed = after.replace(/^ +/u, '');
  const prev = previousWord(before);

  // Lists, ranges, sums and scores of digits stay digits.
  if (isNumber(before.at(-1))) return null;
  if (before.endsWith(',') && isNumber(before.at(-2))) return null;
  const last = before.at(-1);
  if (last !== undefined && SYMBOLS_BEFORE.has(last)) return null;
  const first = afterTrimmed[0];
  if (first !== undefined && (isNumber(first) || SYMBOLS_AFTER.has(first))) return null;
  if (afterTrimmed.startsWith(',') && isNumber(afterTrimmed.slice(1).replace(/^ +/u, '')[0])) return null;

  // Sentence start counts only at the very start of the text or after "!" or "?".
  // After a full stop the previous word may be an abbreviation ("inkl. 3",
  // "Hauptstr. 3", "ca. 3"), so a digit there stays.
  const atSentenceStart = before === '' || last === '!' || last === '?';

  if (ordinal) {
    // Needs a following word; "3." at the end of a sentence is ambiguous.
    if (!after.startsWith(' ')) return null;
    const next = nextWord(after);
    const ending = prev ? ORDINAL_ENDINGS[prev.toLowerCase()] : undefined;
    const stem = GERMAN_ORDINAL_STEMS[digit];
    if (!next || ending === undefined || stem === undefined) return null;
    const lower = next.toLowerCase();
    if (MONTHS.has(lower) || SENTENCE_STARTERS.has(lower) || ['bis', 'und', 'oder'].includes(lower)) return null;
    // "gegen den 1. FC Köln": an all-capitals word is a name, not a noun.
    if ([...next].length > 1 && next === next.toUpperCase()) return null;
    return stem + ending;
  }

  const word = GERMAN_CARDINALS[digit];
  if (word === undefined) return null;
  if (!atSentenceStart) {
    if (!prev) return null;
    const lower = prev.toLowerCase();
    // "und" and "oder" continue a quantity only after one that already converted.
    const continuesQuantity = (lower === 'und' || lower === 'oder') && afterConvertedNumber;
    if (!QUANTITY_LEAD_INS.has(lower) && !continuesQuantity) return null;
  }
  const next = nextWord(after);
  if (next && (UNITS.has(next.toLowerCase()) || RANGE_FOLLOWERS.has(next.toLowerCase()))) return null;
  return atSentenceStart ? word.charAt(0).toUpperCase() + word.slice(1) : word;
}
