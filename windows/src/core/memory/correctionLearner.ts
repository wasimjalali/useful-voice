import { canonical, matches, tokenize } from '../dictionary/termMatcher.js';

export interface CorrectionPair {
  observed: string;
  corrected: string;
}

/** Levenshtein distance, used only as a cheap similarity gate. */
export function editDistance(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;

  let previous = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i += 1) {
    const current = [i];
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      current[j] = Math.min(
        (current[j - 1] as number) + 1,
        (previous[j] as number) + 1,
        (previous[j - 1] as number) + cost,
      );
    }
    previous = current;
  }
  return previous[b.length] as number;
}

/** Maximum relative edit distance still treated as a possible mishearing. */
export const MAX_RELATIVE_DISTANCE = 0.65;

/**
 * Extract word-level substitutions from a phrase the user corrected.
 *
 * This is how one Library correction can teach several recurring mistakes. The
 * pairs it produces are INFERENCES, not something the user typed, so the caller
 * must treat them accordingly: they get no pronunciation, and a pair between two
 * ordinary words needs confirmation before it becomes a global rule.
 */
export function extractPairs(
  original: string,
  corrected: string,
  existingDictionary: readonly string[] = [],
): CorrectionPair[] {
  const originalWords = tokenize(original);
  const correctedWords = tokenize(corrected);
  if (originalWords.length === 0 || correctedWords.length === 0) return [];

  // Only attempt word alignment when the shapes are comparable. For a wholesale
  // rewrite, per-word pairs would be noise.
  if (Math.abs(originalWords.length - correctedWords.length) > 2) return [];

  const known = new Set(existingDictionary.map((term) => canonical(term)));
  const pairs: CorrectionPair[] = [];
  const seen = new Set<string>();

  const limit = Math.min(originalWords.length, correctedWords.length);
  for (let i = 0; i < limit; i += 1) {
    const observed = originalWords[i] as string;
    const correct = correctedWords[i] as string;
    if (observed.toLowerCase() === correct.toLowerCase()) continue;
    if (!isPlausibleMishearing(observed, correct)) continue;
    // A word already in the dictionary on the "observed" side is a real term the
    // user wants kept, not a mistake to rewrite.
    if (known.has(canonical(observed))) continue;

    const key = `${observed.toLowerCase()}=>${correct.toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    pairs.push({ observed, corrected: correct });
  }

  return pairs;
}

/**
 * Shortest word that can be paired automatically.
 *
 * Three-letter pairs are excluded outright. English three-letter words are
 * overwhelmingly function words, where "the same word, misheard" and "a
 * deliberate edit to a different word" are indistinguishable — "cat"/"car",
 * "not"/"now", "then"/"them" all sit around a 0.25-0.33 ratio, which any
 * threshold accepts. Those are precisely the pairs that must not become global
 * rules, and `COMMON_WORDS` covers the ones the user might legitimately fix.
 */
export const MINIMUM_PAIR_LENGTH = 4;

/**
 * Whether two words could plausibly be the same word misheard.
 *
 * Requires both words to be at least `MINIMUM_PAIR_LENGTH` characters and the
 * relative edit distance to be under the threshold, so the inference stays on the
 * side of real mishearings like "kubernets"/"Kubernetes".
 */
export function isPlausibleMishearing(observed: string, corrected: string): boolean {
  const left = observed.toLowerCase();
  const right = corrected.toLowerCase();
  if (left === right) return false;
  if (left.length < MINIMUM_PAIR_LENGTH || right.length < MINIMUM_PAIR_LENGTH) return false;
  const distance = editDistance(left, right);
  const longest = Math.max(left.length, right.length);
  if (longest === 0) return false;
  return distance / longest <= MAX_RELATIVE_DISTANCE;
}

/** Whether the corrected word is already represented in the dictionary. */
export function isKnown(phrase: string, existingDictionary: readonly string[]): boolean {
  return existingDictionary.some((term) => matches(term, phrase));
}
