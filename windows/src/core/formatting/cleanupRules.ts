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
 * Fillers. A token is a filler candidate only when it is exactly one of `FILLERS` (lowercase
 * or Capitalised, never ALL CAPS: "ER" is the emergency room) with at most a comma, a full
 * stop or an ellipsis after it. "uh-huh", "um.txt", "(um)" and "Hmm?" are not touched.
 * "like", "you know", "I mean" and "sort of" are real words as often as fillers, so they
 * stay. A candidate is deleted only in two places:
 *   - mid-sentence, when it is lowercase ("so um I need" -> "so I need"). A Capitalised one
 *     mid-sentence is a name or a mention ("Dr. Er will see you", "Ask Er about it"), so it
 *     stays, and so does one right after a mention word ("The word um is", "I said hmm and");
 *   - at a real sentence start (text start, a new line, or after . ! ? that is not an
 *     abbreviation such as "Dr." or "etc."), when a comma follows it ("Um, so we") or the next
 *     word is not capitalised ("Uh so we"). "Um Kulthum" and "Um I think" stay. A
 *     sentence-initial "hmm" always stays ("Hmm, interesting question.").
 * A filler followed by "huh" or "hmm" is a backchannel, not a hesitation: "uh huh", "um hmm",
 * "mm hmm" and "Uh, huh?" stay whole.
 * Deleting a filler tidies only the punctuation it leaves behind:
 *   - its own trailing comma goes with it: "Well, um, I think" -> "Well, I think";
 *   - a comma before it goes when the filler ends the text or the sentence ("went home,
 *     um." -> "went home."), when the word before is one that never takes a comma
 *     ("the, um, store" -> "the store"), and when the filler sits between two commas that
 *     only bracket it ("I think, um, we should" -> "I think we should"). That last comma stays
 *     when it closes a real opening: after a sentence's first word ("Well,"), after a discourse
 *     word ("okay,", "actually,"), after an opening that starts with a greeting or answer word
 *     ("Dear John,", "Thanks Sam,", "Yes sir,"), after an intro phrase ("For example,", "As a
 *     result,", "In 2020,"), before a conjunction ("Friday, um, or Monday") and in a list
 *     ("apples, um, pears,");
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
 * Stutters. Only a closed list of function words ever collapses, to its first occurrence:
 * two in a row when the word never legitimately doubles ("the the", "I I", "to to"), three
 * or more in a row for a few more ("it it it", "that that that", "is is is").
 * Every other word is left alone however often it repeats: numbers ("five five five", "nine
 * nine nine"), emphasis and idiom ("Stop stop stop", "Knock knock knock", "Ho ho ho", "Well
 * well well", "My my", "so so so tired"), and a laugh ("he he he"). A missed stutter is
 * harmless; a lost word is not. "had had", "that that" and "is is" are grammatical, so pairs
 * of those stay. A comma between the repeats is part of the stutter ("I, I think" -> "I
 * think"); a full stop or a line break is not.
 *
 * Whitespace is only ever removed together with the token it belonged to. Text with no
 * filler or stutter comes back byte for byte. Text that is nothing but filler candidates
 * becomes "" ("Um.", "Um, uh, er."), unless one of them is protected: a sentence-initial
 * "hmm" or a backchannel ("Hmm.", "Um hmm.", "Hmm hmm" stay).
 *
 * For the caller: the result can be "" (and the cleanup guard accepts an empty output for an
 * empty input), so whenever the cleaned text is empty, History and the clipboard must keep
 * the raw transcript instead of an empty entry.
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

/**
 * Function words whose doubling is always a stutter. "my" is not one: "My my, look at that."
 * Neither is "he": "he he he" is a laugh.
 */
const DOUBLE_STUTTER = new Set([
  'the', 'a', 'an', 'i', 'we', 'you', 'they', 'she', 'to', 'of', 'in', 'on', 'at', 'for',
  'with', 'by', 'from', 'and', 'or', 'your', 'our', 'their', 'his', 'her', 'its', 'if', 'as',
  "i'm", "i've", "i'll", "i'd", "we're", "it's", "don't", "can't", "didn't", "won't",
]);

/**
 * Function words that collapse from three repeats on (the pairs list collapses from two).
 * "so" is not one: "so so so tired" is emphasis.
 */
const TRIPLE_STUTTER = new Set([...DOUBLE_STUTTER, 'it', 'that', 'is', 'but', 'was', 'this']);

/** A comma before a bracketed filler stays after these words ("Well, um, I think"). */
const KEEP_COMMA_BEFORE = new Set([
  'well', 'so', 'okay', 'ok', 'yes', 'yeah', 'no', 'oh', 'right', 'now', 'sure', 'anyway',
  'actually', 'however', 'also', 'alright', 'hi', 'hello', 'hey', 'thanks', 'honestly', 'basically',
]);

/** A comma before a bracketed filler stays when one of these follows it ("Friday, um, or Monday"). */
const CONJUNCTIONS = new Set([
  'and', 'or', 'but', 'so', 'then', 'because', 'which', 'who', 'where', 'when', 'while',
  'although', 'though', 'unless', 'if',
]);

/** An opening that starts with one of these is closed by its comma ("Dear John,", "Yes sir,"). */
const GREETING_STARTS = new Set([
  'dear', 'hi', 'hello', 'hey', 'thanks', 'yes', 'no', 'ok', 'okay', 'sure', 'sorry', 'well',
]);

/** Intro phrases whose comma closes them ("For example, um, the build"). */
const INTRO_PHRASES = new Set([
  'as a result', 'for example', 'for instance', 'in addition', 'in fact', 'of course', 'by the way',
  'on the other hand', 'at the moment', 'in general',
]);

/** "In 2020,", "By 5,": one of these plus a number is an intro phrase. */
const NUMBER_INTRO = new Set(['in', 'by', 'since', 'until']);

const NUMBER_WORDS = new Set([
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven',
  'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty',
  'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety', 'hundred', 'thousand',
]);

/** Words after which a filler is being mentioned, not used: "the word um", "I said hmm". */
const MENTION = new Set([
  'word', 'words', 'said', 'say', 'says', 'saying', 'type', 'typed', 'write', 'wrote', 'spell',
  'spelled', 'term', 'called', 'named',
]);

/** A full stop after these does not end the sentence. Compared lowercase, whole token. */
const ABBREVIATIONS = new Set([
  'dr.', 'mr.', 'mrs.', 'ms.', 'st.', 'prof.', 'sr.', 'jr.', 'vs.', 'etc.', 'mt.', 'e.g.', 'i.e.',
]);

/** "uh huh", "um hmm", "mm hmm": the first word with one of the second is a backchannel. */
const BACKCHANNEL_FIRST = new Set(['uh', 'um', 'uhm', 'mm', 'mhm', 'hm', 'hmm']);
const BACKCHANNEL_SECOND = new Set(['huh', 'hmm', 'hmmm', 'hm', 'mhm']);

interface Token {
  space: string;
  text: string;
}

function english(text: string): string {
  const [tokens, trailing] = splitTokens(text);
  if (tokens.length === 0) return text;
  const { tokens: withoutFillers, keptProtected } = removeFillers(tokens);
  // Text that is nothing but fillers ("Um.", "Um, uh, er.") was never meant to be typed,
  // unless one of them is protected ("Hmm.", "Um hmm.").
  if (!keptProtected && tokens.every((t) => parseFiller(t.text) !== null)) return '';
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

function isUpperLetter(ch: string): boolean {
  return /^[\p{Lu}\p{Lt}]$/u.test(ch);
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
  if (last !== '.' && last !== '!' && last !== '?') return false;
  return !ABBREVIATIONS.has(lowerAscii(text));
}

/** The word lowercased with trailing , . ! ? and ellipsis removed; null unless plain ASCII letters. */
function plainCore(text: string): string | null {
  const chars = Array.from(text);
  let end = chars.length;
  while (end > 0 && ',.!?\u2026'.includes(chars[end - 1] ?? '')) end -= 1;
  const core = chars.slice(0, end);
  if (core.length === 0 || !core.every((c) => isAsciiLower(c) || isAsciiUpper(c))) return null;
  return lowerAscii(core.join(''));
}

function startsCapitalised(text: string): boolean {
  const first = Array.from(text)[0] ?? '';
  return isUpperLetter(first);
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

/** Indices of tokens in a backchannel pair ("uh huh", "um hmm"), which are never fillers. */
function backchannelIndices(tokens: Token[]): Set<number> {
  const backchannel = new Set<number>();
  for (let i = 0; i + 1 < tokens.length; i += 1) {
    const a = plainCore(tokens[i]?.text ?? '');
    const b = plainCore(tokens[i + 1]?.text ?? '');
    if (a !== null && b !== null && BACKCHANNEL_FIRST.has(a) && BACKCHANNEL_SECOND.has(b)) {
      backchannel.add(i);
      backchannel.add(i + 1);
    }
  }
  return backchannel;
}

/**
 * The tokens without deletable fillers, and whether a protected filler candidate was kept:
 * one in a backchannel ("um hmm") or a sentence-initial "hmm".
 */
function removeFillers(tokens: Token[]): { tokens: Token[]; keptProtected: boolean } {
  const backchannel = backchannelIndices(tokens);
  let keptProtected = false;
  const out: Token[] = [];
  let pendingCapital = false;
  let carriedSpace: string | null = null;
  // A word that follows a deleted sentence-initial filler starts the sentence in its place.
  let startCarried = false;
  for (let i = 0; i < tokens.length; i += 1) {
    const tok = tokens[i];
    if (!tok) continue;
    const prev = out[out.length - 1];
    // The next word that is not itself a filler candidate: "Uh, um so we" decides on "so".
    let n = i + 1;
    while (n < tokens.length && parseFiller(tokens[n]?.text ?? '') !== null) n += 1;
    const next = tokens[n];
    const atSentenceStart: boolean =
      startCarried || prev === undefined || endsSentence(prev.text) || containsNewline(tok.space);
    const candidate = parseFiller(tok.text);
    let filler = backchannel.has(i) ? null : candidate;
    if (filler && !deletable(filler, atSentenceStart, prev, next)) filler = null;
    if (!filler) {
      if (candidate && (backchannel.has(i) || (atSentenceStart && candidate.word.startsWith('hm')))) {
        keptProtected = true;
      }
      let kept: Token = tok;
      if (carriedSpace !== null) kept = { space: carriedSpace, text: kept.text };
      carriedSpace = null;
      if (pendingCapital) kept = { space: kept.space, text: capitaliseIfPlain(kept.text) };
      pendingCapital = false;
      startCarried = false;
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
      } else if (
        endsComma &&
        (isLast ||
          (NO_COMMA_AFTER.has(bareWord(prev.text)) && !thankYouOpening(out)) ||
          (filler.trail === ',' && bracketOnly(out, next)))
      ) {
        prev.text = dropLastChar(prev.text);
      }
    }
    if (atSentenceStart && filler.capitalised && terminal === '') pendingCapital = true;
    startCarried = atSentenceStart;
    if (carriedSpace === null && (prev === undefined || containsNewline(tok.space))) {
      carriedSpace = tok.space;
    }
  }
  return { tokens: out, keptProtected };
}

/** Whether a filler candidate is a hesitation to delete (see the header comment). */
function deletable(filler: Filler, atSentenceStart: boolean, prev: Token | undefined, next: Token | undefined): boolean {
  if (atSentenceStart) {
    // "Hmm, interesting question." is as often a reaction as a hesitation.
    if (filler.word.startsWith('hm')) return false;
    if (filler.trail === ',') return true;
    return next !== undefined && !startsCapitalised(next.text);
  }
  if (filler.capitalised) return false;
  if (prev !== undefined && !prev.text.endsWith(',') && MENTION.has(bareWord(prev.text))) return false;
  return true;
}

/** "Thank you," alone at the start of a sentence: its comma stays although "you" never takes one. */
function thankYouOpening(out: Token[]): boolean {
  const n = out.length;
  if (n < 2 || bareWord(out[n - 1]?.text ?? '') !== 'you' || bareWord(out[n - 2]?.text ?? '') !== 'thank') return false;
  return n === 2 || endsSentence(out[n - 3]?.text ?? '') || containsNewline(out[n - 2]?.space ?? '');
}

/**
 * True when the comma before a ", um," filler was only there to bracket it, so it goes too.
 * It stays when it closes a real opening (see the header comment), before a conjunction and
 * in a list.
 */
function bracketOnly(out: Token[], next: Token | undefined): boolean {
  const prev = out[out.length - 1];
  if (!prev) return false;
  let start = out.length - 1;
  while (start > 0 && !endsSentence(out[start - 1]?.text ?? '') && !containsNewline(out[start]?.space ?? '')) start -= 1;
  if (start === out.length - 1) return false;
  if (KEEP_COMMA_BEFORE.has(bareWord(prev.text))) return false;
  if (closesOpening(out.slice(start))) return false;
  if (next === undefined) return false;
  if (CONJUNCTIONS.has(bareWord(next.text))) return false;
  if (next.text.endsWith(',')) return false;
  return true;
}

/**
 * Whether the words from the sentence start to the comma are an opening the comma closes:
 * one that starts with a greeting or answer word, a known intro phrase, or "in" / "by" /
 * "since" / "until" plus a number.
 */
function closesOpening(segment: Token[]): boolean {
  const words = segment.map((t) => bareWord(t.text));
  const first = words[0];
  if (first === undefined) return false;
  if (GREETING_STARTS.has(first)) return true;
  if (first === 'thank' && words[1] === 'you') return true;
  if (INTRO_PHRASES.has(words.join(' '))) return true;
  if (NUMBER_INTRO.has(first) && segment.length > 1 && segment.slice(1).every((t) => isNumberToken(t.text))) {
    return true;
  }
  return false;
}

/** "2020," "3.5" or a spoken number word such as "twenty". */
function isNumberToken(text: string): boolean {
  const chars = Array.from(text);
  let end = chars.length;
  while (end > 0 && ',.!?'.includes(chars[end - 1] ?? '')) end -= 1;
  const core = chars.slice(0, end);
  if (core.length === 0) return false;
  const isDigit = (c: string): boolean => c >= '0' && c <= '9';
  if (isDigit(core[0] ?? '') && core.every((c) => isDigit(c) || c === ',' || c === '.')) return true;
  return NUMBER_WORDS.has(lowerAscii(core.join('')));
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
      if (!s || s.lead !== '' || stutterKey(s.core) !== key || containsNewline(next.space)) break;
      if (lastShape.trail !== '' && lastShape.trail !== ',') break;
      lastShape = s;
      j += 1;
    }
    const run = j - i;
    const collapse = (run >= 3 && TRIPLE_STUTTER.has(key)) || (run >= 2 && DOUBLE_STUTTER.has(key));
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
