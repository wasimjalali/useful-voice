/**
 * Accept or reject the local cleanup model's output. Mirrors
 * `Sources/UsefulVoiceCore/Formatting/CleanupGuard.swift` rule for rule.
 *
 * The model only ever reads the rules-cleaned text, and its answer is advisory: when
 * this says reject, the caller keeps the rules-only text. A timeout, an error or no
 * output at all is rejected by the caller before it gets here. Both texts are NFC
 * normalised first, so canonically equivalent strings compare equal in both cores, and
 * both cores use the same whitespace list (`isSpace`). Checks run in this order:
 *   1. reasoning: the output holds a `<think>` tag (thinking was meant to be off);
 *   2. wrapper: the output adds a tag, a code fence, a chat token, a quote wrap or a
 *      preamble ("Here is the cleaned text:") that the input does not have;
 *   3. empty: the output has no letters or digits for an input that has some;
 *   4. length: the output is far longer than the input;
 *   5. no word change: the output has exactly the input's words, differing only in case,
 *      punctuation, spacing or layout. Deepgram already formats, so a model earns its place by
 *      changing words. Format-only edits are kept as the rules-only text;
 *   6. changed number: spoken numbers become digits on both sides ("forty two" -> 42, "a dozen"
 *      -> 12, "two point five" -> 2.5, "third" -> 3), then the digit runs must match. The same digit
 *      sequence split differently is fine ("five five five, zero one" -> "555-01"); a changed,
 *      dropped or invented number is not;
 *   7. negation: every not/n't, no, never, nor (and none, nothing, nobody, neither, nowhere) the
 *      speaker said must survive, and none may be invented. "do not" -> "don't" is fine;
 *   8. dropped content: more than `maxDropShare` of the input's content words are gone;
 *   9. added content: new content words beyond `maxAddedShare` of the output's;
 *  10. duplicated: input words repeated beyond what the speaker said (same allowance);
 *  11. reordered: the content words (and numbers, when they had to be matched one by one) are
 *      not in the speaker's order.
 *
 * Words are compared as a multiset, lowercase, apostrophes dropped ("don't" -> "dont").
 * "Content words" leave out function words, filler-like words ("like", "you know"),
 * self-correction cue words ("wait", "sorry", "mean") and spoken-symbol words ("at", "dot",
 * "point", "dollars", the "p m" of a spoken time).
 *
 * Self-corrections. A real correction pattern ("Monday, no wait, Tuesday", "four thousand,
 * sorry, forty thousand", "X, I mean Y", "X, actually, Y", "X, or rather Y", "Thursday, no,
 * Friday", "make that", "scratch that") with content on both sides marks a corrected span:
 * the cue plus as many content words or numbers before it as the repair after it has, and
 * never more than 4. A cue that starts a sentence ("Wait, Tuesday.") reaches back into the
 * previous sentence only when that sentence has at most 4 content words or numbers. Only
 * that span may vanish without counting as a drop, a dropped number or a dropped negation. A
 * cue word anywhere else ("Sorry, I'm late", "I mean what I said") widens nothing.
 *
 * The limits were set before the first eval run and not tuned on the held-out set. See
 * `evals/results/2026-10-16-cleanup.md`.
 */

export type GuardReason =
  | 'reasoning'
  | 'wrapper'
  | 'empty'
  | 'tooLong'
  | 'noWordChange'
  | 'changedNumber'
  | 'negation'
  | 'droppedContent'
  | 'addedContent'
  | 'duplicated'
  | 'reordered';

/** Every reason, in check order. The fixture test requires a row for each. */
export const GUARD_REASONS: readonly GuardReason[] = [
  'reasoning',
  'wrapper',
  'empty',
  'tooLong',
  'noWordChange',
  'changedNumber',
  'negation',
  'droppedContent',
  'addedContent',
  'duplicated',
  'reordered',
];

export type GuardVerdict = { accepted: true; text: string } | { accepted: false; reason: GuardReason };

export interface GuardLimits {
  /** Largest share of the input's content words (outside a corrected span) the output may lose. */
  maxDropShare: number;
  /** Share of the output's content words that may be new or repeated (rounded down). */
  maxAddedShare: number;
  /** Output length limit as a multiple of the input length, plus `lengthSlack` code points. */
  maxLengthRatio: number;
  lengthSlack: number;
  /** Reject an output whose words are the input's words, in order. */
  requireWordChange: boolean;
}

export const STANDARD_GUARD_LIMITS: GuardLimits = {
  maxDropShare: 0.15,
  maxAddedShare: 0.1,
  maxLengthRatio: 1.5,
  lengthSlack: 16,
  requireWordChange: true,
};

export function evaluateCleanupOutput(
  rulesText: string,
  modelOutput: string,
  limits: GuardLimits = STANDARD_GUARD_LIMITS,
): GuardVerdict {
  const inputText = rulesText.normalize('NFC');
  const output = trimSpace(modelOutput.normalize('NFC'));
  const lowered = lowerAscii(output);
  if (lowered.includes('<think>') || lowered.includes('</think>')) return reject('reasoning');
  if (hasWrapper(inputText, output)) return reject('wrapper');

  const rawIn = scan(inputText);
  const rawOut = scan(output);
  if (rawIn.length === 0) return output === '' ? { accepted: true, text: '' } : reject('addedContent');
  if (rawOut.length === 0) return reject('empty');

  if (Array.from(output).length > Math.floor(Array.from(inputText).length * limits.maxLengthRatio) + limits.lengthSlack) {
    return reject('tooLong');
  }

  if (limits.requireWordChange && sameText(rawIn, rawOut)) return reject('noWordChange');

  const input = withNumbers(rawIn);
  const out = withNumbers(rawOut);
  const exempt = correctedSpans(input);

  const numbers = compareNumbers(input, exempt, out);
  if (numbers === 'mismatch') return reject('changedNumber');

  if (!negationsKept(input, exempt, out)) return reject('negation');

  const inTotal = new Map<string, number>();
  const inRequired = new Map<string, number>();
  input.forEach((t, i) => {
    if (!isContent(t)) return;
    bump(inTotal, t.text);
    if (!exempt[i]) bump(inRequired, t.text);
  });
  const outCount = new Map<string, number>();
  for (const t of out) if (isContent(t)) bump(outCount, t.text);

  let required = 0;
  let dropped = 0;
  for (const [word, n] of inRequired) {
    required += n;
    dropped += Math.max(0, n - (outCount.get(word) ?? 0));
  }
  if (dropped > 0 && dropped / required > limits.maxDropShare) return reject('droppedContent');

  let outContent = 0;
  let added = 0;
  let repeated = 0;
  for (const [word, n] of outCount) {
    outContent += n;
    const said = inTotal.get(word) ?? 0;
    if (said === 0) added += n;
    else repeated += Math.max(0, n - said);
  }
  const allowance = Math.floor(limits.maxAddedShare * outContent);
  if (added > allowance) return reject('addedContent');
  if (added + repeated > allowance) return reject('duplicated');

  const withNums = numbers === 'oneByOne';
  const inSeq = input.filter((t) => isContent(t) || (withNums && t.kind === 'num')).map((t) => t.text);
  const outSeq = out
    .filter((t) => (isContent(t) && inTotal.has(t.text)) || (withNums && t.kind === 'num'))
    .map((t) => t.text);
  if (!isSubsequence(outSeq, inSeq)) return reject('reordered');

  return { accepted: true, text: output };
}

const w = (list: string): Set<string> => new Set(list.split(' '));

function reject(reason: GuardReason): GuardVerdict {
  return { accepted: false, reason };
}

function bump(map: Map<string, number>, key: string): void {
  map.set(key, (map.get(key) ?? 0) + 1);
}

function isSubsequence(small: string[], big: string[]): boolean {
  let i = 0;
  for (const w of big) if (i < small.length && w === small[i]) i += 1;
  return i === small.length;
}

// MARK: Characters (code points; Swift mirrors this on unicode scalars)

/** Unicode White_Space, plus the zero-width space and the byte order mark. */
function isSpace(ch: string): boolean {
  const c = ch.codePointAt(0) ?? 0;
  return (
    (c >= 0x09 && c <= 0x0d) ||
    c === 0x20 ||
    c === 0x85 ||
    c === 0xa0 ||
    c === 0x1680 ||
    (c >= 0x2000 && c <= 0x200b) ||
    c === 0x2028 ||
    c === 0x2029 ||
    c === 0x202f ||
    c === 0x205f ||
    c === 0x3000 ||
    c === 0xfeff
  );
}

function isLetter(ch: string): boolean {
  return /^\p{L}$/u.test(ch);
}

function isDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

function isAsciiLetter(ch: string): boolean {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
}

function isApostrophe(ch: string): boolean {
  return ch === "'" || ch === '\u2019';
}

function lowerAscii(s: string): string {
  let out = '';
  for (const ch of s) out += ch >= 'A' && ch <= 'Z' ? String.fromCharCode(ch.charCodeAt(0) + 32) : ch;
  return out;
}

function trimSpace(s: string): string {
  const chars = Array.from(s);
  let start = 0;
  let end = chars.length;
  while (start < end && isSpace(chars[start] ?? '')) start += 1;
  while (end > start && isSpace(chars[end - 1] ?? '')) end -= 1;
  return chars.slice(start, end).join('');
}

// MARK: Wrappers

const WRAPPER_WORDS = w(
  'here heres cleaned corrected cleanup output result revised rewritten edited formatted transcript ' +
    'transcription normalized normalised text version sure certainly',
);

function hasWrapper(input: string, output: string): boolean {
  for (const tag of tags(output)) if (!input.includes(tag)) return true;
  for (const marker of ['```', '<|', '|>', '[INST]', '[/INST]']) {
    if (output.includes(marker) && !input.includes(marker)) return true;
  }
  const outChars = Array.from(output);
  const first = outChars[0] ?? '';
  const last = outChars[outChars.length - 1] ?? '';
  const inFirst = Array.from(trimSpace(input))[0] ?? '';
  if (outChars.length > 1 && (first === '"' || first === '\u201C') && (last === '"' || last === '\u201D')) {
    if (inFirst !== '"' && inFirst !== '\u201C') return true;
  }
  const inWords = scan(input).map((t) => t.text);
  const outWords = scan(output).map((t) => t.text);
  // A leading "Sure," / "Certainly," / "Here is" the speaker did not start with.
  const lead = outWords[0] ?? '';
  if ((lead === 'sure' || lead === 'certainly' || lead === 'heres' || (lead === 'here' && outWords[1] === 'is')) && inWords[0] !== lead) {
    return true;
  }
  // A preamble ending in a colon on the first line ("Cleaned text:", "Here is the result:").
  const colon = outChars.indexOf(':');
  if (colon > 0) {
    const prefix = outChars.slice(0, colon).join('');
    if (!/[\n\r.!?]/.test(prefix)) {
      const words = scan(prefix).map((t) => t.text);
      if (words.some((word) => WRAPPER_WORDS.has(word)) && !containsRun(inWords, words)) return true;
    }
  }
  return false;
}

function containsRun(big: string[], run: string[]): boolean {
  if (run.length === 0) return true;
  for (let i = 0; i + run.length <= big.length; i += 1) {
    if (run.every((word, k) => big[i + k] === word)) return true;
  }
  return false;
}

/** Every "<name ...>", "</name>" or "<name/>" in the text, by a hand scanner both cores share. */
function tags(text: string): string[] {
  const chars = Array.from(text);
  const out: string[] = [];
  for (let i = 0; i < chars.length; i += 1) {
    if (chars[i] !== '<') continue;
    let j = i + 1;
    if (chars[j] === '/') j += 1;
    if (!isAsciiLetter(chars[j] ?? '')) continue;
    while (j < chars.length && (isAsciiLetter(chars[j] ?? '') || isDigit(chars[j] ?? '') || '_:-'.includes(chars[j] ?? ''))) j += 1;
    if (chars[j] !== '>' && chars[j] !== '/' && !isSpace(chars[j] ?? '')) continue;
    while (j < chars.length && chars[j] !== '>' && chars[j] !== '<') j += 1;
    if (chars[j] !== '>') continue;
    out.push(chars.slice(i, j + 1).join(''));
    i = j;
  }
  return out;
}

// MARK: Tokens

interface Tok {
  kind: 'word' | 'num';
  /** Lowercase word without apostrophes, or a digit string ("40000", "2.5", "0123"). */
  text: string;
  commaBefore: boolean;
  commaAfter: boolean;
  /** First token of a sentence: text start, or after . ! ? or a line break. */
  sentenceStart: boolean;
}

/**
 * Words and digit runs. "40,000" is one run (the comma is a thousands separator), "2.5" keeps
 * its point, "555-0123" is two runs. "1st" drops its suffix, and ":00" after an hour is dropped
 * ("5:00" is "5"), so formatting a number never invents one.
 */
function scan(text: string): Tok[] {
  const chars = Array.from(text);
  const out: Tok[] = [];
  let i = 0;
  while (i < chars.length) {
    const ch = chars[i] ?? '';
    if (!isLetter(ch) && !isDigit(ch)) {
      i += 1;
      continue;
    }
    const start = i;
    let value = '';
    let kind: Tok['kind'];
    if (isDigit(ch)) {
      kind = 'num';
      while (i < chars.length) {
        const c = chars[i] ?? '';
        if (isDigit(c)) {
          value += c;
          i += 1;
        } else if (
          c === ',' &&
          isDigit(chars[i + 1] ?? '') &&
          isDigit(chars[i + 2] ?? '') &&
          isDigit(chars[i + 3] ?? '') &&
          !isDigit(chars[i + 4] ?? '')
        ) {
          i += 1;
        } else if (c === '.' && isDigit(chars[i + 1] ?? '')) {
          value += c;
          i += 1;
        } else {
          break;
        }
      }
    } else {
      kind = 'word';
      while (i < chars.length) {
        const c = chars[i] ?? '';
        if (isLetter(c)) {
          value += c;
          i += 1;
        } else if (isApostrophe(c) && isLetter(chars[i + 1] ?? '') && value !== '') {
          i += 1;
        } else {
          break;
        }
      }
      value = lowerAscii(value);
      const prevTok = out[out.length - 1];
      // "1st", "22nd", "3rd", "4th" written straight after the digits.
      if (prevTok?.kind === 'num' && isDigit(chars[start - 1] ?? '') && ORDINAL_SUFFIX.has(value)) continue;
    }
    if (kind === 'num' && /^0+$/.test(value) && chars[start - 1] === ':') continue;
    let k = start - 1;
    let sawBreak = false;
    while (k >= 0 && isSpace(chars[k] ?? '')) {
      if (chars[k] === '\n' || chars[k] === '\r') sawBreak = true;
      k -= 1;
    }
    const before = k >= 0 ? (chars[k] ?? '') : '';
    out.push({
      kind,
      text: value,
      commaBefore: before === ',',
      commaAfter: chars[i] === ',',
      sentenceStart: k < 0 || sawBreak || before === '.' || before === '!' || before === '?',
    });
  }
  return out;
}

function sameText(a: Tok[], b: Tok[]): boolean {
  return a.length === b.length && a.every((t, i) => t.text === b[i]?.text);
}

const ORDINAL_SUFFIX = w('st nd rd th');

// MARK: Spoken numbers

const UNITS = new Map<string, number>([
  ['zero', 0], ['one', 1], ['two', 2], ['three', 3], ['four', 4], ['five', 5], ['six', 6], ['seven', 7],
  ['eight', 8], ['nine', 9],
]);
const TEENS = new Map<string, number>([
  ['ten', 10], ['eleven', 11], ['twelve', 12], ['thirteen', 13], ['fourteen', 14], ['fifteen', 15],
  ['sixteen', 16], ['seventeen', 17], ['eighteen', 18], ['nineteen', 19],
]);
const TENS = new Map<string, number>([
  ['twenty', 20], ['thirty', 30], ['forty', 40], ['fifty', 50], ['sixty', 60], ['seventy', 70],
  ['eighty', 80], ['ninety', 90],
]);
const SCALES = new Map<string, number>([['thousand', 1000], ['million', 1000000], ['billion', 1000000000]]);
const UNIT_ORDINALS = new Map<string, number>([
  ['first', 1], ['second', 2], ['third', 3], ['fourth', 4], ['fifth', 5], ['sixth', 6], ['seventh', 7],
  ['eighth', 8], ['ninth', 9],
]);
const TEEN_ORDINALS = new Map<string, number>([
  ['tenth', 10], ['eleventh', 11], ['twelfth', 12], ['thirteenth', 13], ['fourteenth', 14],
  ['fifteenth', 15], ['sixteenth', 16], ['seventeenth', 17], ['eighteenth', 18], ['nineteenth', 19],
]);
const TENS_ORDINALS = new Map<string, number>([
  ['twentieth', 20], ['thirtieth', 30], ['fortieth', 40], ['fiftieth', 50], ['sixtieth', 60],
  ['seventieth', 70], ['eightieth', 80], ['ninetieth', 90],
]);
const SCALE_ORDINALS = new Map<string, number>([
  ['thousandth', 1000], ['millionth', 1000000], ['billionth', 1000000000],
]);

type NumKind = 'unit' | 'teen' | 'tens' | 'hundred' | 'scale' | 'dozen';

function numberKind(word: string): { kind: NumKind; value: number; ordinal: boolean } | null {
  let v = UNITS.get(word);
  if (v !== undefined) return { kind: 'unit', value: v, ordinal: false };
  v = TEENS.get(word);
  if (v !== undefined) return { kind: 'teen', value: v, ordinal: false };
  v = TENS.get(word);
  if (v !== undefined) return { kind: 'tens', value: v, ordinal: false };
  if (word === 'hundred') return { kind: 'hundred', value: 100, ordinal: false };
  v = SCALES.get(word);
  if (v !== undefined) return { kind: 'scale', value: v, ordinal: false };
  if (word === 'dozen') return { kind: 'dozen', value: 12, ordinal: false };
  v = UNIT_ORDINALS.get(word);
  if (v !== undefined) return { kind: 'unit', value: v, ordinal: true };
  v = TEEN_ORDINALS.get(word);
  if (v !== undefined) return { kind: 'teen', value: v, ordinal: true };
  v = TENS_ORDINALS.get(word);
  if (v !== undefined) return { kind: 'tens', value: v, ordinal: true };
  if (word === 'hundredth') return { kind: 'hundred', value: 100, ordinal: true };
  v = SCALE_ORDINALS.get(word);
  if (v !== undefined) return { kind: 'scale', value: v, ordinal: true };
  return null;
}

const A_MULTIPLIED = w('hundred thousand million billion dozen');

/** Replaces each run of number words with one digit token: "forty two" -> "42", "a dozen" -> "12". */
function withNumbers(tokens: Tok[]): Tok[] {
  const out: Tok[] = [];
  let i = 0;
  while (i < tokens.length) {
    const tok = tokens[i];
    if (!tok) break;
    const startsWithA = tok.kind === 'word' && tok.text === 'a' && A_MULTIPLIED.has(tokens[i + 1]?.text ?? '');
    if (tok.kind !== 'word' || (!startsWithA && numberKind(tok.text) === null)) {
      out.push(tok);
      i += 1;
      continue;
    }
    let total = 0;
    let current = 0;
    let last: NumKind | null = null;
    let fraction = '';
    let j = i;
    while (j < tokens.length) {
      const t = tokens[j];
      if (!t || t.kind !== 'word') break;
      if (j === i && startsWithA) {
        current = 1;
        last = 'unit';
        j += 1;
        continue;
      }
      if (t.text === 'and' && (last === 'hundred' || last === 'scale')) {
        const after = numberKind(tokens[j + 1]?.kind === 'word' ? (tokens[j + 1]?.text ?? '') : '');
        if (after && (after.kind === 'unit' || after.kind === 'teen' || after.kind === 'tens')) {
          j += 1;
          continue;
        }
        break;
      }
      if (t.text === 'point' && last !== null && last !== 'dozen') {
        let k = j + 1;
        let digits = '';
        while (k < tokens.length) {
          const d = tokens[k];
          const u = d && d.kind === 'word' ? UNITS.get(d.text) : undefined;
          if (u === undefined) break;
          digits += String(u);
          k += 1;
        }
        if (digits === '') break;
        fraction = digits;
        j = k;
        break;
      }
      const n = numberKind(t.text);
      if (!n) break;
      let ok = false;
      switch (n.kind) {
        case 'unit':
          ok = last === null || last === 'hundred' || last === 'scale' || (last === 'tens' && current % 10 === 0);
          if (ok) current += n.value;
          break;
        case 'teen':
        case 'tens':
          ok = last === null || last === 'hundred' || last === 'scale';
          if (ok) current += n.value;
          break;
        case 'hundred':
          if (last === null) {
            ok = true;
            current = 100;
          } else if ((last === 'unit' || last === 'teen' || last === 'tens') && current > 0 && current < 100) {
            ok = true;
            current *= 100;
          }
          break;
        case 'scale':
          if (last === null) {
            ok = true;
            total += n.value;
          } else if (last === 'unit' || last === 'teen' || last === 'tens' || last === 'hundred') {
            ok = true;
            total += current * n.value;
            current = 0;
          }
          break;
        case 'dozen':
          if (last === null) {
            ok = true;
            current = 12;
          } else if (last === 'unit' || last === 'teen' || last === 'tens') {
            ok = true;
            current *= 12;
          }
          break;
      }
      if (!ok) break;
      last = n.kind;
      j += 1;
      if (n.ordinal || n.kind === 'dozen') break;
    }
    if (j === i || (startsWithA && j === i + 1)) {
      out.push(tok);
      i += 1;
      continue;
    }
    const first = tokens[i] as Tok;
    const end = tokens[j - 1] as Tok;
    const value = String(total + current) + (fraction === '' ? '' : `.${fraction}`);
    out.push({
      kind: 'num',
      text: value,
      commaBefore: first.commaBefore,
      commaAfter: end.commaAfter,
      sentenceStart: first.sentenceStart,
    });
    i = j;
  }
  return out;
}

/**
 * 'aligned': the numbers match in order, possibly merged or split ("5 5 5" vs "555").
 * 'oneByOne': they match as a multiset but not in order, so the order check includes them.
 * 'mismatch': a number was changed, dropped or invented.
 */
function compareNumbers(input: Tok[], exempt: boolean[], out: Tok[]): 'aligned' | 'oneByOne' | 'mismatch' {
  const all = input.filter((t) => t.kind === 'num').map((t) => t.text);
  const kept = input.filter((t, i) => t.kind === 'num' && !exempt[i]).map((t) => t.text);
  const produced = out.filter((t) => t.kind === 'num').map((t) => t.text);
  if (aligned(all, produced) || aligned(kept, produced)) return 'aligned';
  const pool = new Map<string, number>();
  for (const v of all) bump(pool, v);
  for (const v of produced) {
    const n = pool.get(v) ?? 0;
    if (n === 0) return 'mismatch';
    pool.set(v, n - 1);
  }
  const need = new Map<string, number>();
  for (const v of kept) bump(need, v);
  const have = new Map<string, number>();
  for (const v of produced) bump(have, v);
  for (const [v, n] of need) if ((have.get(v) ?? 0) < n) return 'mismatch';
  return 'oneByOne';
}

/** Same digits in the same order, where a group of neighbouring runs may merge into one. */
function aligned(a: string[], b: string[]): boolean {
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    const x = a[i] ?? '';
    const y = b[j] ?? '';
    if (x === y) {
      i += 1;
      j += 1;
      continue;
    }
    let acc = x;
    let k = i + 1;
    while (acc.length < y.length && k < a.length) acc += a[k++] ?? '';
    if (acc === y && k - i > 1) {
      i = k;
      j += 1;
      continue;
    }
    acc = y;
    k = j + 1;
    while (acc.length < x.length && k < b.length) acc += b[k++] ?? '';
    if (acc === x && k - j > 1) {
      j = k;
      i += 1;
      continue;
    }
    return false;
  }
  return i === a.length && j === b.length;
}

// MARK: Negation

const NEGATIONS = new Map<string, string>([
  ['not', 'not'], ['cannot', 'not'], ['dont', 'not'], ['doesnt', 'not'], ['didnt', 'not'], ['cant', 'not'],
  ['wont', 'not'], ['isnt', 'not'], ['arent', 'not'], ['wasnt', 'not'], ['werent', 'not'], ['hasnt', 'not'],
  ['havent', 'not'], ['hadnt', 'not'], ['couldnt', 'not'], ['wouldnt', 'not'], ['shouldnt', 'not'],
  ['mustnt', 'not'], ['neednt', 'not'], ['aint', 'not'], ['shant', 'not'], ['mightnt', 'not'],
  ['darent', 'not'], ['no', 'no'], ['never', 'never'], ['nor', 'nor'], ['none', 'none'],
  ['nothing', 'nothing'], ['nobody', 'nobody'], ['neither', 'neither'], ['nowhere', 'nowhere'],
]);

function negationsKept(input: Tok[], exempt: boolean[], out: Tok[]): boolean {
  const total = new Map<string, number>();
  const required = new Map<string, number>();
  input.forEach((t, i) => {
    const key = t.kind === 'word' ? NEGATIONS.get(t.text) : undefined;
    if (key === undefined) return;
    bump(total, key);
    if (!exempt[i]) bump(required, key);
  });
  const have = new Map<string, number>();
  for (const t of out) {
    const key = t.kind === 'word' ? NEGATIONS.get(t.text) : undefined;
    if (key !== undefined) bump(have, key);
  }
  for (const [key, n] of required) if ((have.get(key) ?? 0) < n) return false;
  for (const [key, n] of have) if (n > (total.get(key) ?? 0)) return false;
  return true;
}

// MARK: Content words

const STOP = w(
  'a an the and or but so yet of to in on at by for with from into onto over under about as than then ' +
    'that this these those there here is are was were be been being am do does did done have has had having ' +
    'will would shall should can could may might must i me my mine we us our you your he him his she her it its ' +
    'they them their who whom whose which what when where why how if just also very really too quite some any ' +
    'all each both few more most other such only own same up down out off again once now well oh okay ok yeah yes ' +
    'im ive ill id youre youve hes shes theyre thats whats lets theres heres um uh erm hmm like know basically ' +
    'literally honestly anyway kind sort',
);

const CUES = w('wait sorry scratch oops whoops rather mean actually correction');

const SYMBOLS = w(
  'at dot dash slash backslash underscore hash colon semicolon hyphen comma period percent dollar dollars ' +
    'cent cents euro euros pound pounds oclock am pm point p m',
);

function isContent(t: Tok): boolean {
  return (
    t.kind === 'word' &&
    !STOP.has(t.text) &&
    !CUES.has(t.text) &&
    !SYMBOLS.has(t.text) &&
    !NEGATIONS.has(t.text)
  );
}

function isContentOrNumber(t: Tok | undefined): boolean {
  return t !== undefined && (t.kind === 'num' || isContent(t));
}

// MARK: Self-corrections

/** The cue that starts at `p`, as [start, end), or null. See the header comment for the patterns. */
function cueAt(tokens: Tok[], p: number): [number, number] | null {
  const t = tokens[p];
  if (!t || t.kind !== 'word') return null;
  const prev = tokens[p - 1];
  const next = tokens[p + 1];
  const comma = (k: number): boolean => tokens[k]?.commaBefore === true;
  const commaOrStart = (k: number): boolean => comma(k) || tokens[k]?.sentenceStart === true;
  switch (t.text) {
    case 'wait':
      if (prev && (prev.text === 'no' || prev.text === 'oh') && commaOrStart(p - 1)) return [p - 1, p + 1];
      // A lone "wait" needs a comma after it too: "should, wait until Monday" is not a correction.
      if (commaOrStart(p) && t.commaAfter) return [p, p + 1];
      return null;
    case 'sorry':
      return t.commaBefore || t.commaAfter ? [p, p + 1] : null;
    case 'mean':
      return prev?.text === 'i' && comma(p - 1) ? [p - 1, p + 1] : null;
    case 'actually':
      return t.commaAfter && comma(p) ? [p, p + 1] : null;
    case 'rather':
      return prev?.text === 'or' && comma(p - 1) ? [p - 1, p + 1] : null;
    case 'make':
    case 'scratch':
      return next?.text === 'that' && next.kind === 'word' ? [p, p + 2] : null;
    case 'no':
      return t.commaBefore && t.commaAfter ? [p, p + 1] : null;
    default:
      return null;
  }
}

/** Marks the tokens a real self-correction replaced, so they may vanish from the output. */
function correctedSpans(tokens: Tok[]): boolean[] {
  const exempt = tokens.map(() => false);
  let p = 0;
  while (p < tokens.length) {
    const cue = cueAt(tokens, p);
    if (!cue) {
      p += 1;
      continue;
    }
    let [start, end] = cue;
    // "no wait, make that": back-to-back cues are one.
    for (;;) {
      let q = end;
      while (q < tokens.length && FILLERS.has(tokens[q]?.text ?? '')) q += 1;
      const more = cueAt(tokens, q) ?? (tokens[q]?.text === 'no' || tokens[q]?.text === 'oh' ? cueAt(tokens, q + 1) : null);
      if (!more || more[0] > q + 1) break;
      end = more[1];
    }
    // The repair: content words and numbers after the cue, up to the next comma or sentence end.
    let repair = 0;
    for (let k = end; k < tokens.length; k += 1) {
      const t = tokens[k] as Tok;
      if (k > end && (t.commaBefore || t.sentenceStart)) break;
      if (isContentOrNumber(t)) repair += 1;
    }
    // Content before it: back to this sentence's start, or the previous sentence when the cue starts one.
    const floor = sentenceFloor(tokens, start);
    let found = 0;
    let from = start;
    for (let k = start - 1; k >= floor && found < Math.min(MAX_CORRECTED, Math.max(1, repair)); k -= 1) {
      if (isContentOrNumber(tokens[k])) {
        found += 1;
        from = k;
      }
    }
    if (repair > 0 && found > 0) for (let k = from; k < end; k += 1) exempt[k] = true;
    p = end;
  }
  return exempt;
}

const FILLERS = w('um uh erm er hmm');

/** Most content words or numbers one correction may replace. */
const MAX_CORRECTED = 4;

/**
 * Where the corrected span may start: this sentence's start, or, for a cue that starts a
 * sentence, the previous sentence's start when that sentence is short (at most 4 content
 * words or numbers). A longer previous sentence is out of reach.
 */
function sentenceFloor(tokens: Tok[], start: number): number {
  let k = start;
  const cueStartsSentence = tokens[k]?.sentenceStart === true;
  if (cueStartsSentence) k -= 1;
  while (k > 0 && !tokens[k]?.sentenceStart) k -= 1;
  const floor = Math.max(0, k);
  if (cueStartsSentence && tokens.slice(floor, start).filter((t) => isContentOrNumber(t)).length > MAX_CORRECTED) {
    return start;
  }
  return floor;
}
