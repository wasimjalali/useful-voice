/**
 * A prefilter that says, cheaply, "this phrase cannot be in this text", so the word-boundary
 * matcher can skip the regex for it. Mirrors `LanguageMemoryTextIndex.swift`.
 *
 * Why: a lived-in dictionary has thousands of rules and term candidates, and each one ran its
 * own regular expression over the whole transcript on every dictation. Nearly all of them match
 * nothing. This answers "could it match?" from a few hash lookups and a short scan.
 *
 * The contract is one-sided, which is what keeps the output identical to the unindexed matcher:
 * `mayContain` may return true for a phrase that does not match (the caller then runs the real
 * regex, as before), but never returns false for a phrase the regex would match.
 *
 * How it stays one-sided under a case-insensitive unicode regex: the regex compares simple
 * case-folded code points. Both the phrase and the text are reduced to the same *skeleton*,
 * one code point at a time: the full uppercase mapping, then the full lowercase mapping of
 * that, repeated until it stops changing. The skeleton is coarser than simple case folding,
 * never finer, so a regex match implies the phrase's skeleton is a substring of the text's.
 *
 * Two stages. The first looks the phrase's 1-, 2- or 3-code-point windows up in sets that only
 * ever grow (`absorb`): rules rewrite the text as they go, so those sets cover every version of
 * the text seen so far. The second looks for the phrase's skeleton in the skeleton of the
 * *current* text and refuses an occurrence flanked by an ASCII letter, digit or underscore,
 * which the regex's word boundaries would refuse too.
 *
 * The window sets key a window by a 32-bit hash. A collision can only make a window look
 * present, which costs a needless second stage, never a wrong answer.
 */
export interface PhraseSignature {
  readonly skeleton: Uint32Array;
}

const MAX_FIXPOINT_DEPTH = 4;

function isASCIIWord(cp: number): boolean {
  return (cp >= 0x30 && cp <= 0x39) || (cp >= 0x41 && cp <= 0x5a) || (cp >= 0x61 && cp <= 0x7a) || cp === 0x5f;
}

/** Returns false when a code point did not reduce within the depth limit (its skeleton is not canonical). */
function appendSkeleton(cp: number, out: number[], depth: number): boolean {
  const ch = String.fromCodePoint(cp);
  const mapped = ch.toUpperCase().toLowerCase();
  if (mapped === ch) {
    out.push(cp);
    return true;
  }
  if (depth >= MAX_FIXPOINT_DEPTH) {
    out.push(cp);
    return false;
  }
  let settled = true;
  for (const next of mapped) {
    const nextCp = next.codePointAt(0) as number;
    if (nextCp === cp) out.push(nextCp);
    else if (!appendSkeleton(nextCp, out, depth + 1)) settled = false;
  }
  return settled;
}

export interface Skeleton {
  skeleton: Uint32Array;
  ascii: Uint8Array;
  /** For each UTF-16 index of the text (plus its length), where that code point's skeleton starts. */
  starts: Uint32Array;
  /** True when some code point did not reduce within the depth limit: the skeleton is not trustworthy. */
  capped: boolean;
}

export function skeletonOf(text: string): Skeleton {
  const out: number[] = [];
  const flags: number[] = [];
  const starts = new Uint32Array(text.length + 1);
  let unit = 0;
  let capped = false;
  for (const ch of text) {
    const cp = ch.codePointAt(0) as number;
    const before = out.length;
    if (cp < 0x80) {
      out.push(cp >= 0x41 && cp <= 0x5a ? cp + 0x20 : cp);
      flags.push(isASCIIWord(cp) ? 1 : 0);
    } else {
      if (!appendSkeleton(cp, out, 0)) capped = true;
      for (let i = before; i < out.length; i += 1) flags.push(0);
    }
    starts[unit] = before;
    if (ch.length === 2) starts[unit + 1] = before;
    unit += ch.length;
  }
  starts[text.length] = out.length;
  return { skeleton: Uint32Array.from(out), ascii: Uint8Array.from(flags), starts, capped };
}

/**
 * Replaces `remove` entries at `at` with `insert`, in place when the buffer has room. A rule
 * rewrites a few words of a text of thousands of characters, and allocating three fresh
 * arrays of that size per rewrite cost more than the regexes the index saved.
 */
function splice<T extends Uint32Array | Uint8Array>(
  buffer: T, length: number, at: number, remove: number, insert: T,
): { buffer: T; length: number } {
  const newLength = length - remove + insert.length;
  let target = buffer;
  if (newLength > buffer.length) {
    const Ctor = buffer.constructor as new (n: number) => T;
    target = new Ctor(Math.max(newLength, buffer.length * 2));
    target.set(buffer.subarray(0, at), 0);
    target.set(buffer.subarray(at + remove, length), at + insert.length);
  } else {
    target.copyWithin(at + insert.length, at + remove, length);
  }
  target.set(insert, at);
  return { buffer: target, length: newLength };
}

function isHighSurrogate(unit: number): boolean {
  return unit >= 0xd800 && unit <= 0xdbff;
}

function isLowSurrogate(unit: number): boolean {
  return unit >= 0xdc00 && unit <= 0xdfff;
}

/**
 * Signatures by phrase, because a dictation re-derives one per rule, per candidate and per
 * pass and the dictionary does not change between dictations. Bounded by refusing new
 * entries, not by evicting, so a huge dictionary cannot churn it.
 */
const SIGNATURE_CACHE = new Map<string, PhraseSignature | null>();
const SIGNATURE_CACHE_LIMIT = 50_000;

/** The signature of `phrase` as the matcher sees it (trimmed), or null for an empty phrase. */
export function phraseSignature(phrase: string): PhraseSignature | null {
  const cached = SIGNATURE_CACHE.get(phrase);
  if (cached !== undefined) return cached;
  const trimmed = phrase.trim();
  const signature = trimmed.length === 0 ? null : phraseSignatureOf(trimmed);
  if (SIGNATURE_CACHE.size < SIGNATURE_CACHE_LIMIT) SIGNATURE_CACHE.set(phrase, signature);
  return signature;
}

/** The signature, with a straight loop for the common all-ASCII phrase; null when the skeleton is uncertain. */
function phraseSignatureOf(text: string): PhraseSignature | null {
  const out = new Uint32Array(text.length);
  for (let i = 0; i < text.length; i += 1) {
    const unit = text.charCodeAt(i);
    if (unit >= 0x80) {
      const full = skeletonOf(text);
      return full.capped ? null : { skeleton: full.skeleton };
    }
    out[i] = unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit;
  }
  return { skeleton: out };
}

function hash2(a: number, b: number): number {
  return (Math.imul(a, 0x9e3779b1) ^ Math.imul(b + 0x7f4a7c15, 0x85ebca6b)) >>> 0;
}

function hash3(a: number, b: number, c: number): number {
  return (Math.imul(a, 0x9e3779b1) ^ Math.imul(b + 0x7f4a7c15, 0x85ebca6b) ^ Math.imul(c + 0x1b873593, 0xc2b2ae35)) >>> 0;
}

export class TextIndex {
  private readonly unigrams = new Set<number>();
  private readonly bigrams = new Set<number>();
  private readonly trigrams = new Set<number>();
  private text = '';
  private current: Uint32Array = new Uint32Array(0);
  private currentLength = 0;
  private currentASCII: Uint8Array = new Uint8Array(0);
  private starts: Uint32Array = new Uint32Array(1);
  private startsLength = 1;
  /** Set once any version of the text held a code point that did not reduce: the index then rules nothing out. */
  private uncertain = false;

  constructor(text: string) {
    this.absorb(text);
  }

  /**
   * Makes `text` the current text and adds the windows of its skeleton to the index.
   *
   * Rules rewrite a few words of a long text, so only the stretch that changed is
   * re-derived: the common prefix and suffix of the old and new text keep their skeleton,
   * and only windows that touch the changed stretch are added. Every other window of the
   * new text was already in the old one.
   */
  absorb(text: string): void {
    if (text === this.text) return;
    const old = this.text;
    const oldLength = old.length;
    const newLength = text.length;
    const limit = Math.min(oldLength, newLength);

    let prefix = 0;
    while (prefix < limit && old.charCodeAt(prefix) === text.charCodeAt(prefix)) prefix += 1;
    // Never split a surrogate pair: back up to its first half.
    if (prefix > 0 && isHighSurrogate(text.charCodeAt(prefix - 1))) prefix -= 1;
    let suffix = 0;
    while (suffix < limit - prefix
      && old.charCodeAt(oldLength - 1 - suffix) === text.charCodeAt(newLength - 1 - suffix)) suffix += 1;
    if (suffix > 0 && isLowSurrogate(text.charCodeAt(newLength - suffix))) suffix -= 1;

    const middle = skeletonOf(text.slice(prefix, newLength - suffix));
    if (middle.capped) this.uncertain = true;
    const keepHead = this.starts[prefix] as number;
    const keepTailFrom = this.starts[oldLength - suffix] as number;
    const removedSkeleton = keepTailFrom - keepHead;

    const skeleton = splice(this.current, this.currentLength, keepHead, removedSkeleton, middle.skeleton);
    const ascii = splice(this.currentASCII, this.currentLength, keepHead, removedSkeleton, middle.ascii);
    this.current = skeleton.buffer;
    this.currentASCII = ascii.buffer;
    this.currentLength = skeleton.length;

    // Entries for the rewritten scalars, then every later entry moves by the length change.
    const middleStarts = new Uint32Array(newLength - suffix - prefix);
    for (let i = 0; i < middleStarts.length; i += 1) middleStarts[i] = (middle.starts[i] as number) + keepHead;
    const startsNow = splice(this.starts, this.startsLength, prefix, oldLength - suffix - prefix, middleStarts);
    this.starts = startsNow.buffer;
    this.startsLength = startsNow.length;
    const shift = middle.skeleton.length - removedSkeleton;
    if (shift !== 0) {
      for (let i = newLength - suffix; i < this.startsLength; i += 1) {
        this.starts[i] = (this.starts[i] as number) + shift;
      }
    }
    this.text = text;

    const total = this.currentLength;
    const from = Math.max(0, keepHead - 2);
    const to = Math.min(total - 1, keepHead + middle.skeleton.length);
    for (let i = from; i <= to; i += 1) {
      const a = this.current[i] as number;
      this.unigrams.add(a);
      if (i + 1 < total) {
        const b = this.current[i + 1] as number;
        this.bigrams.add(hash2(a, b));
        if (i + 2 < total) this.trigrams.add(hash3(a, b, this.current[i + 2] as number));
      }
    }
  }

  /** The skeleton of the current text, for the tests that compare it with a fresh build. */
  currentSkeleton(): { skeleton: Uint32Array; ascii: Uint8Array; starts: Uint32Array } {
    return {
      skeleton: this.current.subarray(0, this.currentLength),
      ascii: this.currentASCII.subarray(0, this.currentLength),
      starts: this.starts.subarray(0, this.startsLength),
    };
  }

  /** False only when the regex for this phrase certainly finds nothing in the current text. */
  mayContain(signature: PhraseSignature): boolean {
    const p = signature.skeleton;
    if (p.length === 0 || this.uncertain) return true;
    return this.windowsPresent(p) && this.occursInCurrentText(p);
  }

  /** Stage one: every 1-, 2- or 3-window of `p` has been seen in some version of the text. */
  windowsPresent(p: Uint32Array): boolean {
    if (p.length === 1) return this.unigrams.has(p[0] as number);
    if (p.length === 2) return this.bigrams.has(hash2(p[0] as number, p[1] as number));
    for (let i = 0; i + 2 < p.length; i += 1) {
      if (!this.trigrams.has(hash3(p[i] as number, p[i + 1] as number, p[i + 2] as number))) return false;
    }
    return true;
  }

  private occursInCurrentText(p: Uint32Array): boolean {
    const n = this.currentLength;
    const m = p.length;
    if (m > n) return false;
    const first = p[0] as number;
    for (let i = 0; i <= n - m; i += 1) {
      if (this.current[i] !== first) continue;
      let j = 1;
      while (j < m && this.current[i + j] === p[j]) j += 1;
      if (j !== m) continue;
      const leftBlocked = i > 0 && this.currentASCII[i - 1] === 1;
      const rightBlocked = i + m < n && this.currentASCII[i + m] === 1;
      if (!leftBlocked && !rightBlocked) return true;
    }
    return false;
  }
}

/** With fewer candidate phrases than this, building an index costs more than the scans it saves. */
export const INDEX_MIN_CANDIDATES = 16;
