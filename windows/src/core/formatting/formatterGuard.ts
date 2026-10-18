/**
 * The guard between a language model's answer and the user's document.
 *
 * A formatter that answers the dictation, adds a preamble or drops half the text must never
 * reach the paste. Pure, so every rejection rule is unit-tested.
 */

export type GuardResult = { ok: true; text: string } | { ok: false; reason: string };

const PREAMBLE = /^(here is|here['\u2019]s|sure|certainly|i['\u2019]ve|i have|of course)(?![\p{L}\p{N}])/iu;
/** Leading fillers a dictation may start with before the words that look like a preamble. */
const LEADING_FILLER = /^(?:(?:umm?|uhh?|erm?|hmm)\b[\s,]*)+/i;

/** Words in a dictation at or under this count are not sent to a model at all. */
export const MIN_FORMATTER_WORDS = 3;

function stripWrappingFence(text: string): string {
  const match = /^```[^\n`]*\n([\s\S]*?)\n?```$/.exec(text);
  return match ? (match[1] ?? '').trim() : text;
}

function stripWrappingDictationTag(text: string): string {
  const match = /^<dictation>([\s\S]*)<\/dictation>$/i.exec(text);
  return match ? (match[1] ?? '').trim() : text;
}

/** Check a model's output against the text it was given. Returns the cleaned text or the reason it was refused. */
export function guardFormatted(input: string, output: string): GuardResult {
  let text = output.trim();
  text = stripWrappingFence(text);
  text = stripWrappingDictationTag(text);
  text = text.trim();

  if (text.length === 0) return { ok: false, reason: 'empty output' };
  if (text.length > input.length * 2 + 40) return { ok: false, reason: 'output much longer than the input' };
  if (input.length >= 20 && text.length < input.length * 0.4) return { ok: false, reason: 'output much shorter than the input' };
  // A dictation that really starts "I have to go" must not be refused for sounding like a preamble.
  if (PREAMBLE.test(text) && !PREAMBLE.test(input.trim().replace(LEADING_FILLER, ''))) {
    return { ok: false, reason: 'output starts with an assistant preamble' };
  }
  // The prompt's own scaffolding must never reach the document.
  if (/<vocabulary>|<\/dictation>/i.test(text)) return { ok: false, reason: 'output contains the prompt markers' };
  // A reply that has nothing to do with what was said (the model answered it, or made something up).
  const outputWords = wordsOf(text);
  if (outputWords.length >= 5) {
    const known = new Set(wordsOf(input));
    const shared = outputWords.filter((word) => known.has(word)).length;
    if (shared < outputWords.length * 0.6) return { ok: false, reason: 'unrelated' };
  }
  return { ok: true, text };
}

function wordsOf(text: string): string[] {
  return text
    .toLowerCase()
    .replace(/\u2019/g, "'")
    .replace(/[^\p{L}\p{N}\s]/gu, '')
    .split(/\s+/)
    .filter((word) => word.length > 0);
}

/** Scripts written without spaces between words: a word count means nothing there. */
const UNSPACED_SCRIPTS = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Thai}\p{Script=Lao}\p{Script=Khmer}\p{Script=Myanmar}]/u;
export const MIN_FORMATTER_CHARACTERS = 6;

/** Whether a transcript is long enough to be worth formatting: 3 words, or 6 characters in an unspaced script. */
export function worthFormatting(text: string): boolean {
  if (UNSPACED_SCRIPTS.test(text)) return [...text.replace(/\s+/g, '')].length >= MIN_FORMATTER_CHARACTERS;
  return text.split(/\s+/).filter((token) => token.length > 0).length >= MIN_FORMATTER_WORDS;
}
