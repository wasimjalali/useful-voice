/**
 * Accept or reject the local cleanup model's output. Mirrors
 * `Sources/UsefulVoiceCore/Formatting/CleanupGuard.swift` rule for rule.
 *
 * The model only ever reads the rules-cleaned text, and its answer is advisory: when
 * this says reject, the caller keeps the rules-only text. A timeout, an error or no
 * output at all is rejected by the caller before it gets here. Checks run in this order:
 *   1. reasoning: the output holds a `<think>` tag (thinking was meant to be off);
 *   2. empty: nothing came back for text that has words in it;
 *   3. length: the output is far longer than the input;
 *   4. dropped content: too many of the input's content words are gone;
 *   5. added content: content words appear that the speaker never said.
 *
 * "Content words" are the distinct lowercase words of the text minus function words,
 * filler-like words ("like", "you know"), self-correction cues ("no wait", "I mean") and
 * spoken-symbol words ("at", "dot", "dollars"). Case, punctuation and spacing are ignored:
 * the guard judges content, not formatting. Numbers count as one content item ("#num"), so
 * "three" -> "3" is neither a drop nor an add, but a model that invents a number, or loses
 * every number, is caught. A self-correction legitimately removes words ("Monday, no wait,
 * Tuesday"), so when the input contains a correction cue the allowed drop share is higher.
 *
 * The limits below were set on the dev half of `evals/cleanup/cases.json` and checked on
 * the test half; see `evals/results/2026-10-16-cleanup.md`.
 */

export type GuardReason = 'reasoning' | 'empty' | 'tooLong' | 'droppedContent' | 'addedContent';

export type GuardVerdict = { accepted: true; text: string } | { accepted: false; reason: GuardReason };

export interface GuardLimits {
  /** Largest share of the input's content words the output may lose. */
  maxDropShare: number;
  /** The same, when the input has a self-correction cue. */
  maxDropShareWithCorrection: number;
  /** Share of the output's content words that may be new (rounded down). */
  maxAddedShare: number;
  /** Output length limit as a multiple of the input length, plus `lengthSlack` scalars. */
  maxLengthRatio: number;
  lengthSlack: number;
}

export const STANDARD_GUARD_LIMITS: GuardLimits = {
  maxDropShare: 0.15,
  maxDropShareWithCorrection: 0.5,
  maxAddedShare: 0.1,
  maxLengthRatio: 1.5,
  lengthSlack: 16,
};

export function evaluateCleanupOutput(
  rulesText: string,
  modelOutput: string,
  limits: GuardLimits = STANDARD_GUARD_LIMITS,
): GuardVerdict {
  const output = trimSpace(modelOutput);
  const lowered = lowerAscii(output);
  if (lowered.includes('<think>') || lowered.includes('</think>')) return reject('reasoning');

  const input = words(rulesText);
  if (input.length === 0) return output === '' ? { accepted: true, text: '' } : reject('addedContent');
  if (output === '') return reject('empty');

  if (Array.from(output).length > Math.floor(Array.from(rulesText).length * limits.maxLengthRatio) + limits.lengthSlack) {
    return reject('tooLong');
  }

  const inputAll = new Set(input.map((w) => w.text));
  const outputWords = words(output);
  const outputAll = new Set(outputWords.map((w) => w.text));
  const inputContent = contentSet(input);
  const outputContent = contentSet(outputWords);
  if (hasNumber(input)) inputAll.add(NUMBER_ITEM);
  if (hasNumber(outputWords)) outputAll.add(NUMBER_ITEM);

  if (inputContent.size > 0) {
    let dropped = 0;
    for (const w of inputContent) if (!outputAll.has(w)) dropped += 1;
    const share = dropped / inputContent.size;
    const limit = hasCorrectionCue(input) ? limits.maxDropShareWithCorrection : limits.maxDropShare;
    if (dropped > 0 && share > limit) return reject('droppedContent');
  }

  let added = 0;
  for (const w of outputContent) if (!inputAll.has(w)) added += 1;
  if (added > Math.floor(limits.maxAddedShare * outputContent.size)) return reject('addedContent');

  return { accepted: true, text: output };
}

function reject(reason: GuardReason): GuardVerdict {
  return { accepted: false, reason };
}

// MARK: Words

const NUMBER_ITEM = '#num';

interface Word {
  text: string;
  hasDigit: boolean;
  commaBefore: boolean;
  commaAfter: boolean;
}

function isSpace(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\u00A0';
}

function isLetter(ch: string): boolean {
  return /^\p{L}$/u.test(ch);
}

function isDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
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

/** Runs of letters and digits; apostrophes inside a word are dropped ("don't" -> "dont"). */
function words(text: string): Word[] {
  const chars = Array.from(text);
  const out: Word[] = [];
  let i = 0;
  while (i < chars.length) {
    const ch = chars[i] ?? '';
    if (!isLetter(ch) && !isDigit(ch)) {
      i += 1;
      continue;
    }
    const start = i;
    let word = '';
    let hasDigit = false;
    while (i < chars.length) {
      const c = chars[i] ?? '';
      if (isLetter(c) || isDigit(c)) {
        word += c;
        if (isDigit(c)) hasDigit = true;
        i += 1;
      } else if (isApostrophe(c) && isLetter(chars[i + 1] ?? '') && word !== '') {
        i += 1;
      } else {
        break;
      }
    }
    let k = start - 1;
    while (k >= 0 && isSpace(chars[k] ?? '')) k -= 1;
    out.push({
      text: lowerAscii(word),
      hasDigit,
      commaBefore: k >= 0 && chars[k] === ',',
      commaAfter: chars[i] === ',',
    });
  }
  return out;
}

const w = (list: string): Set<string> => new Set(list.split(' '));

const STOP = w(
  'a an the and or but nor so yet of to in on at by for with from into onto over under about as than then ' +
    'that this these those there here is are was were be been being am do does did done have has had having ' +
    'will would shall should can could may might must i me my mine we us our you your he him his she her it its ' +
    'they them their who whom whose which what when where why how if not just also very really too quite some any ' +
    'all each both few more most other such only own same up down out off again once now well oh okay ok yeah yes ' +
    'im ive ill id youre youve hes shes theyre dont doesnt didnt cant wont isnt arent wasnt werent hasnt havent ' +
    'hadnt couldnt wouldnt shouldnt thats whats lets theres heres um uh erm hmm like know basically literally ' +
    'honestly anyway kind sort',
);

const CUES = w('wait sorry scratch oops whoops rather mean actually correction instead');

const SYMBOLS = w(
  'at dot dash slash backslash underscore hash colon semicolon hyphen comma period percent dollar dollars ' +
    'cent cents euro euros pound pounds oclock am pm',
);

const NUMBER_WORDS = w(
  'zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen ' +
    'seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand ' +
    'million billion first second third fourth fifth sixth seventh eighth ninth tenth eleventh twelfth ' +
    'thirteenth fourteenth fifteenth sixteenth seventeenth eighteenth nineteenth twentieth thirtieth',
);

function isNumber(word: Word): boolean {
  return word.hasDigit || NUMBER_WORDS.has(word.text);
}

function hasNumber(list: Word[]): boolean {
  return list.some(isNumber);
}

function contentSet(list: Word[]): Set<string> {
  const out = new Set<string>();
  for (const word of list) {
    if (isNumber(word)) out.add(NUMBER_ITEM);
    else if (!STOP.has(word.text) && !CUES.has(word.text) && !SYMBOLS.has(word.text)) out.add(word.text);
  }
  return out;
}

/** "no wait", "sorry", "I mean", "make that", or a "no" set off by commas ("Thursday, no, Friday"). */
function hasCorrectionCue(list: Word[]): boolean {
  for (let i = 0; i < list.length; i += 1) {
    const word = list[i];
    if (!word) continue;
    if (CUES.has(word.text)) return true;
    if (word.text === 'no' && (word.commaBefore || word.commaAfter)) return true;
    if (word.text === 'make' && list[i + 1]?.text === 'that') return true;
  }
  return false;
}
