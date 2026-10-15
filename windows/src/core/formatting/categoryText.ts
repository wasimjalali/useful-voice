/**
 * Character helpers shared by the per-category formatter files. Mirrors
 * `Sources/UsefulVoiceCore/Formatting/CategoryText.swift`. Text is handled as an array of
 * characters (grapheme clusters) so the TypeScript and Swift rules index the same way.
 */

// Text is split into grapheme clusters, the way Swift's Character does, and each test looks
// at the cluster's first code point, which is what Swift's Character properties do. That
// keeps "e" plus a combining accent, "\r\n" and emoji flags one unit on both platforms.
const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });

export function isWS(c: string): boolean {
  return /^\p{White_Space}/u.test(c);
}

export function isNewline(c: string): boolean {
  return c === '\n' || c === '\r' || c === '\r\n';
}

export function isLetter(c: string): boolean {
  return /^\p{Alphabetic}/u.test(c);
}

export function isUpper(c: string): boolean {
  return /^\p{Uppercase}/u.test(c);
}

export function isNumber(c: string): boolean {
  return /^\p{N}/u.test(c);
}

export function isAlnum(c: string): boolean {
  return isLetter(c) || isNumber(c);
}

export function chars(text: string): string[] {
  return Array.from(segmenter.segment(text), (part) => part.segment);
}

export function trimWS(text: string): string {
  const cs = chars(text);
  let start = 0;
  let end = cs.length;
  while (start < end && isWS(cs[start] as string)) start++;
  while (end > start && isWS(cs[end - 1] as string)) end--;
  return cs.slice(start, end).join('');
}

/** The text split on runs of whitespace, without empty pieces. */
export function splitWords(text: string): string[] {
  const words: string[] = [];
  let current = '';
  for (const c of chars(text)) {
    if (isWS(c)) {
      if (current !== '') words.push(current);
      current = '';
    } else {
      current += c;
    }
  }
  if (current !== '') words.push(current);
  return words;
}

export function containsNewline(text: string): boolean {
  return chars(text).some(isNewline);
}
