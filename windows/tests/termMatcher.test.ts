import { describe, expect, it } from 'vitest';
import {
  canonical,
  containsWordBoundaryPhrase,
  escapeRegExp,
  languageMatches,
  matches,
  tokenize,
} from '../src/core/dictionary/termMatcher.js';

describe('canonical', () => {
  it('lowercases and collapses separators', () => {
    expect(canonical('  Claude   Code  ')).toBe('claude code');
    expect(canonical('GPT-4')).toBe('gpt 4');
    expect(canonical('fine_tune')).toBe('fine tune');
  });

  it('strips a trailing possessive', () => {
    expect(canonical("Claude Code's")).toBe('claude code');
    expect(canonical('Claude Code’s')).toBe('claude code');
  });

  /**
   * JavaScript's `===` does NOT treat NFC and NFD as equal, unlike Swift. macOS
   * text fields produce NFC while STT output and file round-trips often produce
   * NFD, so without explicit composition the same German word becomes two
   * dictionary entries and two correction rules that rewrite each other.
   */
  it('folds NFC and NFD to the same key', () => {
    const nfc = 'M\u00FCller';
    const nfd = 'Mu\u0308ller';
    // Guard: the fixtures really are different code unit sequences.
    expect(nfc).not.toBe(nfd);
    expect(canonical(nfc)).toBe(canonical(nfd));
  });

  it('folds normalization together with case and spacing', () => {
    const decomposed = '  Zu\u0308rich-Office  ';
    const composed = 'Z\u00FCrich Office';
    expect(canonical(decomposed)).toBe(canonical(composed));
  });
});

describe('matches', () => {
  it('matches identical and plurals', () => {
    expect(matches('Claude Code', 'claude code')).toBe(true);
    expect(matches('term', 'terms')).toBe(true);
    expect(matches('box', 'boxes')).toBe(true);
    expect(matches('city', 'cities')).toBe(true);
  });

  it('does not match unrelated words', () => {
    expect(matches('then', 'than')).toBe(false);
    expect(matches('form', 'from')).toBe(false);
  });

  it('never matches on empty input', () => {
    expect(matches('', 'anything')).toBe(false);
    expect(matches('anything', '')).toBe(false);
  });
});

describe('tokenize', () => {
  it('splits on any separator run', () => {
    expect(tokenize('claude   code')).toEqual(['claude', 'code']);
    expect(tokenize('gpt-4o mini')).toEqual(['gpt', '4o', 'mini']);
    expect(tokenize('   ')).toEqual([]);
  });
});

describe('containsWordBoundaryPhrase', () => {
  it('matches whole words only', () => {
    expect(containsWordBoundaryPhrase('cloud code', 'use cloud code today')).toBe(true);
    expect(containsWordBoundaryPhrase('cloud', 'cloudflare')).toBe(false);
    expect(containsWordBoundaryPhrase('sig', 'signal')).toBe(false);
  });

  it('is case insensitive', () => {
    expect(containsWordBoundaryPhrase('claude code', 'CLAUDE CODE works')).toBe(true);
  });

  it('handles German umlauts and technical punctuation', () => {
    expect(containsWordBoundaryPhrase('M\u00FCller', 'ask M\u00FCller now')).toBe(true);
    expect(containsWordBoundaryPhrase('C++', 'use C++ here')).toBe(true);
    expect(containsWordBoundaryPhrase('gpt-4o', 'choose gpt-4o today')).toBe(true);
  });

  it('treats regex metacharacters as literals', () => {
    // A term like "a.b" must not match "axb"; unescaped it would.
    expect(containsWordBoundaryPhrase('a.b', 'axb')).toBe(false);
    expect(containsWordBoundaryPhrase('a.b', 'a.b')).toBe(true);
    expect(containsWordBoundaryPhrase('$1.00', 'pay $1.00 now')).toBe(true);
  });

  it('returns false for empty input without throwing', () => {
    expect(containsWordBoundaryPhrase('', 'anything')).toBe(false);
    expect(containsWordBoundaryPhrase('   ', 'anything')).toBe(false);
  });
});

describe('languageMatches', () => {
  it('treats auto on either side as a match', () => {
    expect(languageMatches('auto', 'en')).toBe(true);
    expect(languageMatches('de', 'auto')).toBe(true);
    expect(languageMatches('auto', 'auto')).toBe(true);
  });

  it('matches only equal languages otherwise', () => {
    expect(languageMatches('en', 'en')).toBe(true);
    expect(languageMatches('en', 'de')).toBe(false);
  });
});

describe('escapeRegExp', () => {
  it('escapes every metacharacter', () => {
    const input = '.*+?^${}()|[]\\';
    expect(new RegExp(escapeRegExp(input)).test(input)).toBe(true);
  });
});
