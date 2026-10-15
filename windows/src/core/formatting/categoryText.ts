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

/** ASCII 0-9 only. Swift's Character.isNumber and \p{N} disagree on CJK numerals, so both sides use this. */
export function isDigit(c: string): boolean {
  return c.length === 1 && c >= '0' && c <= '9';
}

export function isAlnum(c: string): boolean {
  return isLetter(c) || isDigit(c);
}

/** Lower-cases A-Z only. Full Unicode folding would turn the Kelvin sign (U+212A) into "k". */
export function asciiLower(text: string): string {
  return text.replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
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
