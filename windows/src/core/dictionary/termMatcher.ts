import type { MemoryLanguage } from '../models.js';

/**
 * Canonicalisation of user-entered phrases.
 *
 * Two spellings of the same phrase must produce the same key, because this key
 * is what de-duplicates the dictionary, what the correction engine matches on,
 * and what the keyterm budget counts. Everything that compares phrases goes
 * through here.
 */

/** Collapse runs of whitespace or hyphens to a single space. */
export function normaliseSeparators(input: string): string {
  return input
    .trim()
    .replace(/[-_\s]+/g, ' ')
    .trim();
}

/**
 * The canonical key for a phrase.
 *
 * Composes to NFC before lowercasing. macOS text fields tend to produce NFC
 * while speech-to-text output and file/clipboard round-trips often produce NFD
 * ("u" + combining diaeresis instead of "ü"). JavaScript's `===` does *not*
 * treat those as equal — unlike Swift — so without this step the same German
 * word becomes two dictionary entries, two keyterm slots, and two correction
 * rules that rewrite each other. German is a first-class language here, so this
 * is not hypothetical.
 *
 * Also strips a trailing possessive so "Claude Code's" matches "Claude Code".
 */
export function canonical(phrase: string): string {
  const composed = phrase.normalize('NFC');
  const withoutPossessive = composed.replace(/['’]s\b/giu, '');
  return normaliseSeparators(withoutPossessive).toLowerCase();
}

/** Whitespace-separated tokens, for word-level comparisons. */
export function tokenize(input: string): string[] {
  return normaliseSeparators(input)
    .split(' ')
    .map((word) => word.trim())
    .filter((word) => word.length > 0);
}

/**
 * Whether two phrases are the same term.
 *
 * Exact canonical equality, or a plural variation (`term` vs `terms`,
 * `box` vs `boxes`). Plural tolerance exists so a user who dictates "terms" once
 * does not end up with a second dictionary entry.
 */
export function matches(a: string, b: string): boolean {
  const left = canonical(a);
  const right = canonical(b);
  if (left === right) return true;
  if (left.length === 0 || right.length === 0) return false;
  return stripPlural(left) === stripPlural(right);
}

function stripPlural(word: string): string {
  if (word.endsWith('ies') && word.length > 4) return `${word.slice(0, -3)}y`;
  if (word.endsWith('es') && word.length > 3) return word.slice(0, -2);
  if (word.endsWith('s') && word.length > 2) return word.slice(0, -1);
  return word;
}

/**
 * Escape a literal string for use inside a regular expression.
 *
 * Every user-supplied phrase ends up in a pattern, so this is not optional:
 * a term like "C++" or "a.b" would otherwise be interpreted as regex syntax.
 */
export function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * The word-boundary pattern for a phrase.
 *
 * `\p{L}\p{N}_` is the definition of a word character used on the inside of the
 * lookarounds, which handles German umlauts and technical terms correctly:
 * "sig" does not match inside "signal", but "C++" and "gpt-4o" still match.
 */
export function wordBoundaryPattern(phrase: string): string {
  return `(?<![\\p{L}\\p{N}_])${escapeRegExp(phrase)}(?![\\p{L}\\p{N}_])`;
}

/** Whether `phrase` occurs in `text` on word boundaries, case-insensitively. */
export function containsWordBoundaryPhrase(phrase: string, text: string): boolean {
  const trimmed = phrase.trim();
  if (trimmed.length === 0) return false;
  try {
    return new RegExp(wordBoundaryPattern(trimmed), 'iu').test(text);
  } catch {
    // Never throw on user data: an unrepresentable phrase simply does not match.
    return false;
  }
}

/**
 * Whether a rule's language applies to the current dictation language.
 *
 * `auto` on either side matches everything: a term saved while the language was
 * auto-detected must still work once the user pins a language, and vice versa.
 */
export function languageMatches(ruleLanguage: MemoryLanguage, current: MemoryLanguage): boolean {
  return ruleLanguage === 'auto' || current === 'auto' || ruleLanguage === current;
}
