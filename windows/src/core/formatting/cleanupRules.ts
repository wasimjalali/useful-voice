/**
 * Deterministic English cleanup rules. Mirrors
 * `Sources/UsefulVoiceCore/Formatting/CleanupRules.swift` rule for rule.
 *
 * Deepgram only formats. This is the "rules" step of the cleanup order (vocabulary,
 * rules, local model, user rules): it removes filler sounds and collapses stutters,
 * and nothing else. It deletes, it never adds, reorders or re-cases a word the speaker
 * said. The cleanup guidance it follows is the published SpeakoFlow rules layer
 * (https://speakoflow.com/blog/dictation-cleanup-rules-and-llm, MIT), made stricter:
 * a missed "um" is invisible, a deleted word is a bug report, so every rule leaves the
 * text alone when it is unsure.
 *
 * Fillers. A token is a filler only when it is exactly one of `FILLERS` (lowercase or
 * Capitalised, never ALL CAPS: "ER" is the emergency room) with at most a comma, a full
 * stop or an ellipsis after it. "uh-huh", "um.txt", "(um)" and "Hmm?" are not touched.
 * "like", "you know", "I mean" and "sort of" are real words as often as fillers, so they
 * stay, and so does a sentence-initial "hmm" ("Hmm, interesting question."). Deleting a filler tidies only the punctuation it leaves behind:
 *   - its own trailing comma goes with it: "Well, um, I think" -> "Well, I think";
 *   - a comma before it goes when the filler ends the text or the sentence ("went home,
 *     um." -> "went home.") or when the word before is one that never takes a comma
 *     ("the, um, store" -> "the store");
 *   - a filler that ends a sentence ("I went, um.") hands its full stop to the word before.
 * Sentence-initial capital: when the deleted filler was Capitalised and started a
 * sentence ("Um, so we"), the next word gets the capital back ("So we"). That restores the
 * sentence casing the speaker's first word carried; it does not re-case a word they said.
 * A filler that was already lowercase hands over nothing. The capital only moves onto a
 * plain lowercase word (letters and apostrophes, optional trailing punctuation): "iPhone",
 * "app.ts" and "git-flow" are left as they were. A plain lowercase identifier such as
 * "npm" does get the capital ("Um, npm install" -> "Npm install"), which is the known cost
 * of restoring sentence casing without a dictionary.
 *
 * Stutters. A run of the same word, case-insensitively, collapses to its first
 * occurrence: three or more in a row (except emphasis words: "no no no", "very very
 * very"), or two in a row when the word is a function word that never legitimately
 * doubles ("the the", "I I", "to to"). "had had", "that that", "is is" and "no no" are
 * grammatical or emphatic, so pairs of those stay. A comma between the repeats is part of
 * the stutter ("I, I think" -> "I think"), a full stop is not.
 *
 * Whitespace is only ever removed together with the token it belonged to. Text with no
 * filler or stutter comes back byte for byte. Text that is nothing but fillers becomes "".
 * English only: other languages have real words that look like these fillers ("um" is
 * Portuguese for "a").
 */

export function applyCleanupRules(text: string, language: string | null | undefined): string {
  const code = language?.toLowerCase();
  if (!code) return text;
  if (code === 'en' || code.startsWith('en-')) return english(text);
  return text;
}

const FILLERS = new Set(['um', 'umm', 'uhm', 'uh', 'uhh', 'erm', 'er', 'hmm', 'hmmm']);

/** Words that never take a comma after them, so "the, um, store" loses both commas. */
const NO_COMMA_AFTER = new Set([
  'the', 'a', 'an', 'to', 'of', 'in', 'on', 'at', 'for', 'with', 'by', 'from', 'into', 'onto',
  'over', 'than', 'my', 'your', 'his', 'her', 'our', 'their', 'its', 'this', 'that', 'these',
  'those', 'and', 'or', 'but', 'because', 'if', 'when', 'as', 'which', 'is', 'are', 'was',
  'were', 'be', 'i', 'we', 'you', 'they', 'he', 'she', 'it',
]);

/** Function words whose doubling is always a stutter. */
const DOUBLE_STUTTER = new Set([
  'the', 'a', 'an', 'i', 'we', 'you', 'they', 'he', 'she', 'to', 'of', 'in', 'on', 'at', 'for',
  'with', 'by', 'from', 'and', 'or', 'my', 'your', 'our', 'their', 'his', 'her', 'its', 'if', 'as',
  "i'm", "i've", "i'll", "i'd", "we're", "it's", "don't", "can't", "didn't", "won't",
]);

/** Words repeated three or more times on purpose. */
const EMPHASIS = new Set([
  'no', 'yes', 'very', 'so', 'bye', 'ha', 'never', 'more', 'really', 'hey', 'oh', 'wow', 'go',
  'please', 'sorry', 'okay', 'ok', 'again', 'yeah', 'blah', 'la', 'na',
]);

interface Token {
  space: string;
  text: string;
}

function english(text: string): string {
  const [tokens, trailing] = splitTokens(text);
  if (tokens.length === 0) return text;
  const withoutFillers = removeFillers(tokens);
  const collapsed = collapseStutters(withoutFillers);
  if (collapsed.length === 0) return '';
  return collapsed.map((t) => t.space + t.text).join('') + trailing;
}

// MARK: Characters (code points; Swift mirrors this on unicode scalars)

function isSpace(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r' || ch === '\u00A0';
}

function isAsciiUpper(ch: string): boolean {
  return ch >= 'A' && ch <= 'Z';
}

function isAsciiLower(ch: string): boolean {
  return ch >= 'a' && ch <= 'z';
}

function isLetter(ch: string): boolean {
  return /^\p{L}$/u.test(ch);
}

function isApostrophe(ch: string): boolean {
  return ch === "'" || ch === '\u2019';
}

function lowerAscii(s: string): string {
  let out = '';
  for (const ch of s) out += isAsciiUpper(ch) ? String.fromCharCode(ch.charCodeAt(0) + 32) : ch;
  return out;
}

function upperAscii(ch: string): string {
  return isAsciiLower(ch) ? String.fromCharCode(ch.charCodeAt(0) - 32) : ch;
}

function containsNewline(s: string): boolean {
  return s.includes('\n') || s.includes('\r');
}

function splitTokens(text: string): [Token[], string] {
  const tokens: Token[] = [];
  let space = '';
  let word = '';
  for (const ch of text) {
    if (isSpace(ch)) {
      if (word !== '') {
        tokens.push({ space, text: word });
        space = '';
        word = '';
      }
      space += ch;
    } else {
      word += ch;
    }
  }
  if (word !== '') {
    tokens.push({ space, text: word });
    return [tokens, ''];
  }
  return [tokens, space];
}

// MARK: Fillers

interface Filler {
  capitalised: boolean;
  trail: string;
  /** Lowercase filler word. */
  word: string;
}

function parseFiller(text: string): Filler | null {
  const chars = Array.from(text);
  let end = chars.length;
  while (end > 0 && (chars[end - 1] === ',' || chars[end - 1] === '.' || chars[end - 1] === '\u2026')) end -= 1;
  const trail = chars.slice(end).join('');
  if (end === 0) return null;
  const core = chars.slice(0, end);
  if (!core.every((c) => isAsciiLower(c) || isAsciiUpper(c))) return null;
  const word = core.join('');
  const lower = lowerAscii(word);
  if (!FILLERS.has(lower)) return null;
  const capitalised = isAsciiUpper(core[0] ?? '');
  const casingOk = word === lower || word === upperAscii(lower.charAt(0)) + lower.slice(1);
  if (!casingOk) return null;
  if (trail !== '' && trail !== ',' && trail !== '.' && trail !== '...' && trail !== '\u2026') return null;
  return { capitalised, trail, word: lower };
}

/** The last character after any closing quote or bracket. */
function lastMeaningful(text: string): string {
  const chars = Array.from(text);
  let i = chars.length;
  while (i > 0 && '"\')]\u201D\u2019'.includes(chars[i - 1] ?? '')) i -= 1;
  return i > 0 ? (chars[i - 1] ?? '') : '';
}

function endsSentence(text: string): boolean {
  const last = lastMeaningful(text);
  return last === '.' || last === '!' || last === '?';
}

function endsWithStop(text: string): boolean {
  const chars = Array.from(text);
  const last = chars[chars.length - 1] ?? '';
  return last !== '' && '.!?\u2026:;'.includes(last);
}

function bareWord(text: string): string {
  let out = '';
  for (const ch of text) if (isLetter(ch) || isApostrophe(ch)) out += ch === '\u2019' ? "'" : ch;
  return lowerAscii(out);
}

function dropLastChar(text: string): string {
  const chars = Array.from(text);
  chars.pop();
  return chars.join('');
}

function removeFillers(tokens: Token[]): Token[] {
  const out: Token[] = [];
  let pendingCapital = false;
  let carriedSpace: string | null = null;
  for (let i = 0; i < tokens.length; i += 1) {
    const tok = tokens[i];
    if (!tok) continue;
    const prev = out[out.length - 1];
    const atSentenceStart = prev === undefined || endsSentence(prev.text) || containsNewline(tok.space);
    let filler = parseFiller(tok.text);
    // "Hmm, interesting question." is as often a reaction as a hesitation, so a sentence-initial
    // "hmm" stays. Mid-sentence ("Okay, hmm, that works") it is a filler.
    if (filler && filler.word.startsWith('hm') && atSentenceStart) filler = null;
    if (!filler) {
      let kept: Token = tok;
      if (carriedSpace !== null) kept = { space: carriedSpace, text: kept.text };
      carriedSpace = null;
      if (pendingCapital) kept = { space: kept.space, text: capitaliseIfPlain(kept.text) };
      pendingCapital = false;
      out.push({ space: kept.space, text: kept.text });
      continue;
    }

    const isLast = i === tokens.length - 1;
    const terminal =
      filler.trail === '.' || (isLast && (filler.trail === '...' || filler.trail === '\u2026'))
        ? filler.trail
        : '';

    if (prev !== undefined) {
      const endsComma = prev.text.endsWith(',');
      if (terminal !== '') {
        if (endsComma) prev.text = dropLastChar(prev.text) + terminal;
        else if (!endsWithStop(prev.text)) prev.text += terminal;
      } else if (endsComma && (isLast || NO_COMMA_AFTER.has(bareWord(prev.text)))) {
        prev.text = dropLastChar(prev.text);
      }
    }
    if (atSentenceStart && filler.capitalised && terminal === '') pendingCapital = true;
    if (carriedSpace === null && (prev === undefined || containsNewline(tok.space))) {
      carriedSpace = tok.space;
    }
  }
  return out;
}

/** "so," -> "So,". Anything that is not a plain lowercase word ("iPhone", "app.ts", "3d") is returned as is. */
function capitaliseIfPlain(text: string): string {
  const chars = Array.from(text);
  let end = chars.length;
  while (end > 0 && !isLetter(chars[end - 1] ?? '') && !isApostrophe(chars[end - 1] ?? '')) end -= 1;
  const core = chars.slice(0, end);
  if (core.length === 0) return text;
  if (!core.every((c) => isAsciiLower(c) || isApostrophe(c))) return text;
  const first = core[0] ?? '';
  if (!isAsciiLower(first)) return text;
  chars[0] = upperAscii(first);
  return chars.join('');
}

// MARK: Stutters

interface Shape {
  lead: string;
  core: string;
  trail: string;
}

/** Splits "(the," into lead "(", core "the", trail ","; null unless the core is letters and apostrophes. */
function shape(text: string): Shape | null {
  const chars = Array.from(text);
  let start = 0;
  while (start < chars.length && !isLetter(chars[start] ?? '')) start += 1;
  let end = chars.length;
  while (end > start && !isLetter(chars[end - 1] ?? '')) end -= 1;
  if (start >= end) return null;
  const core = chars.slice(start, end);
  if (!core.every((c) => isLetter(c) || isApostrophe(c))) return null;
  return { lead: chars.slice(0, start).join(''), core: core.join(''), trail: chars.slice(end).join('') };
}

function stutterKey(core: string): string {
  return lowerAscii(core.replace(/\u2019/g, "'"));
}

function collapseStutters(tokens: Token[]): Token[] {
  const out: Token[] = [];
  let i = 0;
  while (i < tokens.length) {
    const tok = tokens[i];
    if (!tok) break;
    const first = shape(tok.text);
    if (!first) {
      out.push(tok);
      i += 1;
      continue;
    }
    const key = stutterKey(first.core);
    let j = i + 1;
    let lastShape = first;
    while (j < tokens.length) {
      const next = tokens[j];
      if (!next) break;
      const s = shape(next.text);
      if (!s || s.lead !== '' || stutterKey(s.core) !== key) break;
      if (lastShape.trail !== '' && lastShape.trail !== ',') break;
      lastShape = s;
      j += 1;
    }
    const run = j - i;
    const collapse = (run >= 3 && !EMPHASIS.has(key)) || (run >= 2 && DOUBLE_STUTTER.has(key));
    if (collapse) {
      out.push({ space: tok.space, text: first.lead + first.core + lastShape.trail });
    } else {
      for (let k = i; k < j; k += 1) {
        const t = tokens[k];
        if (t) out.push(t);
      }
    }
    i = j;
  }
  return out;
}
