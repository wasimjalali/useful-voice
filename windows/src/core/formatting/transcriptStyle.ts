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
 * "version two" -> "version 2", "GPT-five" -> "GPT-5". The number after the word "version"
 * or a hyphenated all-caps product code is a name, not a quantity. "version" only counts
 * when it is the only "version <number>" in the text and the number ends the phrase
 * ("version two is out"), so pairs and lists ("version one to version two", "version one,
 * two and three"), "version one users" and "the version one would expect" are left as
 * spoken. "one" is also the pronoun, so it needs punctuation after it. A bare acronym
 * followed by a number ("the API one more time") is never touched.
 */
function english(text: string): string {
  const others = 'two|three|four|five|six|seven|eight|nine|ten';
  const edge = '(?![\\p{L}\\p{N}_])';
  const notAList =
    `(?!\\s*,?\\s*(?:and|or)\\s+(?:${ENGLISH_WORDS})${edge})(?!\\s*,\\s*(?:${ENGLISH_WORDS})${edge})`;
  const start = '(?<![\\p{L}\\p{N}_])([Vv]ersion)(\\s+)';
  const toDigit = (_m: string, word: string, space: string, n: string): string =>
    `${word}${space}${ENGLISH_NUMBERS[n]}`;

  let result = text;
  const versions = text.match(new RegExp(`(?<![\\p{L}\\p{N}_])[Vv]ersion\\s+(?:${ENGLISH_WORDS})${edge}`, 'gu'));
  if (versions?.length === 1) {
    result = result
      .replace(
        new RegExp(`${start}(${others})${edge}${notAList}(?=\\s*(?:[.,;:!?)]|$)|\\s+(?:${ENGLISH_VERBS})${edge})`, 'gu'),
        toDigit,
      )
      .replace(new RegExp(`${start}(one)${edge}${notAList}(?=\\s*(?:[.,;:!?)]|$))`, 'gu'), toDigit);
  }
  result = result.replace(
    new RegExp(
      `(?<![\\p{L}\\p{N}_])(?!(?:ONE|TWO|THREE|FOUR|FIVE|SIX|SEVEN|EIGHT|NINE|TEN)-)([A-Z]{3,5})(-)(${ENGLISH_WORDS})(?![\\p{L}\\p{N}_])(?!-)`,
      'gu',
    ),
    (_m, code: string, sep: string, n: string) => `${code}${sep}${ENGLISH_NUMBERS[n]}`,
  );
  // "07:45AM" -> "7:45 AM", "3PM" -> "3 PM": no leading zero and a space before AM or PM.
  // Never inside a longer number or code ("UA 007 PM", "A007AM").
  result = result.replace(
    /(?<![\p{L}\p{N}_:.])(0?)([1-9]|1[0-2])(:[0-5]\d)?\s?([AaPp][Mm])(?![A-Za-z])/gu,
    (_m, _zero: string, hour: string, minutes: string | undefined, meridiem: string) =>
      `${hour}${minutes ?? ''} ${meridiem}`,
  );
  // "the 21st Floor" -> "the 21st floor": Deepgram capitalises the noun after a digit
  // ordinal. Only common nouns that are not part of a name, and only when no other
  // capitalised word follows, so "5th Avenue", "21st Place NW", "21st Century Fox",
  // "The 13th Floor Elevators" and "2nd Year Student" keep their capitals.
  result = result.replace(
    /\b(\d+(?:st|nd|rd|th))(\s+)(Floor|Time|Quarter|Draft|Item|Attempt|Round|Session|Row|Chapter|Week|Month|Year|Half|Semester|Grade|Birthday)\b(?=\s*(?:[.,;:!?)]|$)|\s+[a-z])/gu,
    (_m, ordinal: string, space: string, noun: string) => `${ordinal}${space}${noun.toLowerCase()}`,
  );
  // "q three" -> "Q3", only as a quarter: at the end of a phrase, before a word that follows
  // a quarter ("Q three revenue") or a linking word. "Press Q two times" and "hit the Q
  // three times" keep their words.
  result = result.replace(
    new RegExp(
      `(?<![\\p{L}\\p{N}_])[Qq][ -](${ENGLISH_WORDS.split('|').slice(0, 4).join('|')})(?![\\p{L}\\p{N}_])(?=\\s*(?:[.,;:!?)]|$)|\\s+(?:${QUARTER_FOLLOWERS})(?![\\p{L}\\p{N}_]))`,
      'gu',
    ),
    (_m, n: string) => `Q${ENGLISH_NUMBERS[n]}`,
  );
  return closingFullStop(result);
}

const QUARTER_FOLLOWERS =
  'revenue|results|earnings|sales|numbers|report|targets|goals|planning|review|forecast|budget|roadmap|growth|profit|performance|update|okrs|close|guidance|bookings|is|was|will|of|and|or|to';

const QUESTION_OPENERS = new Set([
  'did', 'do', 'does', 'is', 'are', 'was', 'were', 'will', 'would', 'can', 'could', 'should',
  'how', 'what', 'when', 'where', 'who', 'why', 'which', 'have', 'has', 'had', 'shall', 'may',
]);

/**
 * Deepgram drops the closing full stop after a currency amount ("costs $25"). Added only
 * when the whole text is a one-line sentence of at least four words that starts with a
 * capital letter, is not a question opener or a URL, and ends on the amount with no
 * punctuation at all. Lists, chat fragments and questions are left alone.
 */
function closingFullStop(text: string): string {
  const words = text.split(/\s+/u).filter((word) => word !== '');
  const first = words[0];
  if (
    words.length < 4 ||
    text.includes('\n') ||
    text.includes('://') ||
    first === undefined ||
    !/^\p{Lu}/u.test(first) ||
    QUESTION_OPENERS.has(first.toLowerCase()) ||
    !/[$€£]\s?\d(?:[\d,]*\d)?(?:\.\d+)?(?:\s(?:million|billion|thousand))?$/u.test(text)
  ) {
    return text;
  }
  return `${text}.`;
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
 * ending would change a word the speaker said. "am", "vom" and "den" are left out on
 * purpose: "am 3." and "Dienstag, den 3." are dates that often end a sentence ("den 5.
 * Kommst du?"), and a date is not an ordinal to spell out.
 */
const ORDINAL_ENDINGS: Record<string, string> = {
  das: 'e',
  dem: 'en', des: 'en',
  im: 'en', zum: 'en', beim: 'en', zur: 'en',
};
/** A digit before one of these is a measurement, a price or a clock time, so it stays. */
const UNITS = new Set([
  'uhr', 'euro', 'cent', 'dollar', 'franken', 'pfund', 'prozent', 'grad',
  'gigabyte', 'megabyte', 'kilobyte', 'terabyte', 'gb', 'mb', 'kb', 'tb',
  'kilometer', 'km', 'meter', 'm', 'zentimeter', 'cm', 'millimeter', 'mm',
  'kilogramm', 'kg', 'gramm', 'g', 'liter', 'l', 'ml', 'watt', 'volt',
  'kwh', 'ps', 'h', 'std', 'min', 'mio', 'mrd', 'x', 'chf', 'eur', 'usd', 'gbp', 'tsd', 'pkt',
  'mg', 'ghz', 'mhz', 'khz', 'hz', 'kw', 'mw', 'kv', 'ppm', 'dpi', 'fps', 'mbit', 'gbit', 'mbps', 'gbps',
]);
/**
 * The only words after which "3.5" becomes "3,5". Deliberately not "Uhr": "10.30 Uhr"
 * is a time. A decimal anywhere else could be a section number or a version.
 */
const DECIMAL_UNITS = new Set([
  ...[...UNITS].filter((unit) => unit !== 'uhr' && unit !== 'x' && unit !== 'h'),
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
 * An ordinal becomes a word only before one of these nouns. "im 4. Kannst du ihr helfen?"
 * and "Freitag, dem 3. Kommst du?" are a number that ended a sentence and a date, and a
 * capitalised word after "N." cannot tell them apart from a noun, so anything not on this
 * list keeps its digit. "Mal" and "Klasse" are not listed because "bis zum 5. Mal sehen,
 * ..." and "am 3. Klasse, danke!" are sentences.
 */
const ORDINAL_NOUNS = new Set([
  'kapitel', 'stock', 'stockwerk', 'etage', 'platz', 'versuch', 'anlauf', 'quartal',
  'jahr', 'jahrhundert', 'semester', 'runde', 'auflage', 'satz', 'schritt', 'woche', 'monat',
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

const DECIMAL_PATTERN = new RegExp(`(?<!${W}|[.,\\-])(\\d+)\\.(\\d{1,2})(?!${W}|[.,])`, 'gu');
const SMALL_NUMBER_PATTERN = new RegExp(
  `(?<!${W}|[.,:/+\\-–%€$£#@])(\\d)(\\.)?(?!${W}|[:/%°€$£+\\-–]|[.,]\\d|\\.\\p{L})`,
  'gu',
);
/**
 * A full stop ends a sentence only after a word of five or more letters and before a
 * capital letter or a line end, so an abbreviation ("bzw. Welpen", "inkl. Küche", "z. B.
 * Boskop", "u. a. Siemens") does not split a sentence in two. "!" and "?" always end one.
 * A full stop right after a digit is an ordinal dot.
 */
const SENTENCE_BOUNDARY = /(?<!\d)(?:[!?]+|(?<=\p{L}{5})\.+)(?=\s+\p{Lu}|\s*\n|\s*$)/gu;

/**
 * "3.5 Gigabyte" -> "3,5 Gigabyte". Only before a unit or quantity word, and not after a
 * capitalised word, digit or hyphen ("Version 3.5", "GPT-4.5"). All or nothing per
 * sentence, like the small numbers, so one sentence never mixes "2,5 Kilo" with "3.5 Kilo".
 */
function germanDecimals(text: string): string {
  return allOrNothing(text, DECIMAL_PATTERN, (match, before, after, afterConverted) => {
    const next = nextWord(after);
    if (!next || !DECIMAL_UNITS.has(next.toLowerCase())) return null;
    const prev = previousWord(before);
    if (prev) {
      if (/^\p{Lu}/u.test(prev) || /\p{N}/u.test(prev)) return null;
      const lower = prev.toLowerCase();
      const continuesQuantity = (lower === 'und' || lower === 'oder') && afterConverted;
      if (DATE_OR_RANGE_LEAD_INS.has(lower) && !continuesQuantity) return null;
    }
    return `${match[1]},${match[2]}`;
  });
}

/**
 * "2 Fragen" -> "zwei Fragen", "das 1. Kapitel" -> "das erste Kapitel".
 *
 * All or nothing per sentence: if any single digit in a sentence cannot be turned into a
 * word safely, none of that sentence's single digits are. That is what keeps lists,
 * ranges, scores and "die 3 ... die 4" from coming out half converted.
 */
function germanSmallNumbers(text: string): string {
  return allOrNothing(text, SMALL_NUMBER_PATTERN, (match, before, after) =>
    smallNumberWord(Number(match[1]), match[2] !== undefined, before, after),
  );
}

/**
 * Decides every match of `pattern` in order, then applies the replacements of a sentence
 * only if none of its matches was refused (`decide` returned null). `decide` also learns
 * whether an earlier match in the same sentence converted.
 */
function allOrNothing(
  text: string,
  pattern: RegExp,
  decide: (match: RegExpMatchArray, before: string, after: string, afterConverted: boolean) => string | null,
): string {
  const matches = [...text.matchAll(pattern)];
  if (matches.length === 0) return text;
  const boundaries = [...text.matchAll(SENTENCE_BOUNDARY)].map((m) => m.index! + m[0].length);

  const converted = new Set<number>();
  const decisions = matches.map((match) => {
    const start = match.index!;
    const chunk = boundaries.filter((boundary) => boundary <= start).length;
    const replacement = decide(
      match,
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

  // "14 und 5", "11 oder 3": one half of a pair of numbers, whatever their length.
  if (/\d[\d.,:]*\s*(und|oder)$/iu.test(before)) return null;

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
    if (!ORDINAL_NOUNS.has(next.toLowerCase())) return null;
    return stem + ending;
  }

  const word = GERMAN_CARDINALS[digit];
  if (word === undefined) return null;
  if (!atSentenceStart) {
    if (!prev) return null;
    // "und" and "oder" never continue a quantity: the number before them may be a label
    // ("§ 5a und 6", "Windows XP und 7") that never converted.
    if (!QUANTITY_LEAD_INS.has(prev.toLowerCase())) return null;
  }
  const next = nextWord(after);
  if (next && (UNITS.has(next.toLowerCase()) || RANGE_FOLLOWERS.has(next.toLowerCase()))) return null;
  return atSentenceStart ? word.charAt(0).toUpperCase() + word.slice(1) : word;
}
