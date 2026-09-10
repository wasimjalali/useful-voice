/**
 * Deepgram's `keyterm` prompting has a hard per-request token limit.
 *
 * Exceeding it is not a soft failure. The API rejects the entire request with
 * `Keyterm limit exceeded. The maximum number of tokens across all keyterms is
 * 500.` — so an oversized personal dictionary breaks *every* dictation, not just
 * the one with the long term list.
 *
 * The token count is produced by Deepgram's own tokenizer, which cannot be run
 * locally, so this estimates and stays well clear of the ceiling.
 * https://developers.deepgram.com/docs/keyterm#key-term-limits
 */
export const HARD_TOKEN_LIMIT = 500;

/**
 * Headroom. Real tokenization differs from any local estimate (punctuation,
 * unusual casing, digits, non-ASCII scripts), and Deepgram's own guidance is to
 * stay "well under" the limit and focus on the most important 20-50 terms.
 */
export const SAFETY_MARGIN_TOKENS = 100;

/** The token budget this app is willing to spend on keyterms in one request. */
export const TOKEN_BUDGET = HARD_TOKEN_LIMIT - SAFETY_MARGIN_TOKENS;

/**
 * Upper bound on how many keyterm strings are sent, regardless of token cost.
 *
 * Every keyterm is URL-encoded onto the request line, so an unbounded list also
 * risks a URL that an intermediary proxy rejects.
 */
export const MAX_TERMS = 100;

/** A keyterm so long it can only be a pasted paragraph, not a dictionary term. */
export const MAX_TERM_LENGTH = 64;

/**
 * Conservative per-term token estimate.
 *
 * Deliberately over-estimates. Deepgram tokenizes into subword units, and
 * technical terms, CamelCase identifiers, digits and non-Latin scripts all split
 * much more aggressively than plain lowercase English. Under-counting is the
 * dangerous direction: it would let the list pass this check and then be rejected
 * by the API.
 */
export function estimateTokens(term: string): number {
  const trimmed = term.trim();
  if (trimmed.length === 0) return 0;

  const words = trimmed.split(/\s+/).filter((word) => word.length > 0).length;
  const separators = (trimmed.match(/[^\p{L}\p{N}]/gu) ?? []).length;

  // Per-script cost. The previous version assumed ~5 characters per token for
  // every script, which undercounts CJK by roughly 5x: a 5-character Japanese
  // term was estimated at 1 token when its real cost is closer to 5. Japanese and
  // Chinese are reachable through the `auto` language pin, so a CJK dictionary
  // could blow the ceiling while the estimator reported a comfortable margin.
  let lengthTokens = 0;
  for (const char of trimmed) {
    lengthTokens += tokenWeight(char);
  }
  const byLength = Math.ceil(lengthTokens / 5);

  return Math.max(1, Math.max(words, byLength) + separators);
}

/**
 * How many BPE tokens one character plausibly costs, in units of "average Latin
 * characters per token" (~5 for the conservative end of common vocabularies).
 * Dividing by 5 afterwards keeps one consistent currency.
 */
function tokenWeight(char: string): number {
  const code = char.codePointAt(0) ?? 0;
  // Han, Hiragana, Katakana, Hangul: roughly one token per character.
  if (
    (code >= 0x3040 && code <= 0x30ff) || // kana
    (code >= 0x3400 && code <= 0x4dbf) || // CJK ext A
    (code >= 0x4e00 && code <= 0x9fff) || // CJK unified
    (code >= 0xf900 && code <= 0xfaff) || // CJK compat
    (code >= 0xac00 && code <= 0xd7af) || // Hangul syllables
    (code >= 0x1100 && code <= 0x11ff)    // Hangul jamo
  ) {
    return 5;
  }
  // Cyrillic, Greek, Arabic, Hebrew, Thai, Devanagari: split more than Latin.
  if (code >= 0x0370 && code <= 0x0fff) return 3;
  if (code >= 0x0e00 && code <= 0x109f) return 3;
  return 1;
}

/** Total estimated cost of a keyterm list. */
export function estimateListTokens(terms: readonly string[]): number {
  return terms.reduce((total, term) => total + estimateTokens(term), 0);
}

/** True when a list would exceed the budget this app is willing to spend. */
export function exceedsBudget(terms: readonly string[]): boolean {
  return terms.length > MAX_TERMS || estimateListTokens(terms) > TOKEN_BUDGET;
}

/**
 * Reject entries the provider cannot use, before they reach a request: empty
 * strings, punctuation-only strings, control characters (which would corrupt the
 * query string), and absurdly long values.
 */
export function isSendableKeyterm(term: string): boolean {
  const trimmed = term.trim();
  if (trimmed.length === 0 || trimmed.length > MAX_TERM_LENGTH) return false;
  if (!/[\p{L}\p{N}]/u.test(trimmed)) return false;
  // eslint-disable-next-line no-control-regex
  return !/[\u0000-\u001f\u007f]/u.test(trimmed);
}
