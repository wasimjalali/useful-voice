/**
 * The guard between a language model's answer and the user's document.
 *
 * A formatter that answers the dictation, adds a preamble or drops half the text must never
 * reach the paste. Pure, so every rejection rule is unit-tested.
 */

export type GuardResult = { ok: true; text: string } | { ok: false; reason: string };

const PREAMBLE = /^(here is|here's|sure|certainly|i've|i have|of course)\b/i;

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
  if (PREAMBLE.test(text) && !PREAMBLE.test(input.trim())) {
    return { ok: false, reason: 'output starts with an assistant preamble' };
  }
  return { ok: true, text };
}

/** Whether a transcript is long enough to be worth formatting. */
export function worthFormatting(text: string): boolean {
  return text.split(/\s+/).filter((token) => token.length > 0).length >= MIN_FORMATTER_WORDS;
}
