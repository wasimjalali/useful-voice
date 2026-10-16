import { describe, expect, it } from 'vitest';
import { applyMemory } from '../src/core/memory/memoryPostProcessor.js';
import { matchingTermIds } from '../src/core/memory/dictionaryCorrector.js';
import { RuleSet } from '../src/core/memory/replacementEngine.js';
import { phraseSignature, skeletonOf, TextIndex } from '../src/core/memory/textIndex.js';
import { containsWordBoundaryPhrase } from '../src/core/dictionary/termMatcher.js';
import { applyMemory as legacyApplyMemory, matchingTermIds as legacyMatchingTermIds } from './legacy/legacyMemoryPostProcessor.js';
import { RuleSet as LegacyRuleSet } from './legacy/legacyReplacementEngine.js';
import type {
  LanguageMemorySnapshot, MatchMode, MemoryLanguage, MemorySnippet, MemoryTerm, ReplacementRule,
} from '../src/core/models.js';

/**
 * The indexed Language Memory pass against the old one (tests/legacy, the code as it was before
 * the index) over random dictionaries and texts. They must agree on everything: the text, the
 * rules that fired, the term hits, the snippets. UV_LM_DIFF_CASES raises the case count.
 */
const CASES = Number(process.env.UV_LM_DIFF_CASES ?? 150);

function rngFrom(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const ATOMS = [
  'claude', 'Claude', 'code', 'cloud', 'teh', 'the', 'cat', 'a', 'I', 'AI', 'PR', 'api', 'x',
  'useful', 'voice', 'acme', 'inc', 'new', 'york', 'newyork',
  'straße', 'STRASSE', 'Strasse', 'strasse', 'ß', 'ẞ', 'SS', 'ss', 's', 'ſ', 'weiß', 'größe', 'GRÖSSE',
  'ﬁnal', 'final', 'ﬂow', 'flow', 'ﬃ', 'ffi', 'office', 'oﬃce',
  'K', 'k', 'kelvin', 'Kelvin',
  'İstanbul', 'istanbul', 'ISTANBUL', 'ıı', 'ii',
  'ΣΊΣΥΦΟΣ', 'σίσυφος', 'ς', 'σ', 'Σ', 'οδός', 'ΟΔΟΣ',
  'привет', 'Привет', 'ПРИВЕТ', 'мир', 'Ёлка', 'ёлка',
  '東京', 'ありがとう', 'ｱｲｳ', 'Ǆ', 'ǆ', 'ǅ', 'ŉ', 'ʼn',
  'café', 'café', 'CAFÉ', 'Café', 'naïve', 'naïve', 'ü', 'ü', 'Ü',
  '🙂', '👍🏽', 'a‍b', 'x️', '𐐨𐐩', '𐐀𐐁',
  'C++', 'c++', 'gpt-4o', 'GPT-4O', 'a.b', '(x)', '[y]', '$1', '\\', '\\d', '*', 'a+b', 'q?', '^z', 'p|q', '{2}',
  'a/b', '#tag', '&co', "O'Neil", 'o’neil', 'snake_case', '100%', '€5', 'e-mail', 'a_b', '1,000',
  '123', 'v2', '2fast', 'ü2',
];
const SEPARATORS = [' ', ' ', ' ', ' ', ', ', '. ', '\n', '\t', '  ', ' - ', ' ', '　', '', ':', '(', ')'];
const LANGUAGES: MemoryLanguage[] = ['auto', 'auto', 'en', 'de', 'ja' as MemoryLanguage, 'tr' as MemoryLanguage];
const NOW = '2026-01-01T00:00:00.000Z';

interface Scenario {
  snapshot: LanguageMemorySnapshot;
  text: string;
  language: MemoryLanguage;
}

function scenario(seed: number, size: number): Scenario {
  const rnd = rngFrom(seed * 2654435761 + 17);
  const int = (n: number): number => Math.floor(rnd() * n);
  const range = (lo: number, hi: number): number => lo + int(hi - lo + 1);
  const pick = <T,>(xs: readonly T[]): T => xs[int(xs.length)] as T;

  const recase = (s: string): string => {
    switch (int(8)) {
      case 0: return s.toLowerCase();
      case 1: return s.toUpperCase();
      case 2: return s.charAt(0).toUpperCase() + s.slice(1);
      case 3: return [...s].map((c) => (rnd() < 0.5 ? c.toUpperCase() : c.toLowerCase())).join('');
      case 4: return s.normalize('NFD');
      case 5: return s.normalize('NFC');
      default: return s;
    }
  };
  const phrase = (): string => {
    let out = '';
    for (let i = range(1, 3); i > 0; i -= 1) {
      if (out) out += pick(SEPARATORS);
      out += pick(ATOMS);
    }
    switch (int(20)) {
      case 0: return `  ${out} \n`;
      case 1: return '';
      case 2: return 'word '.repeat(50);
      default: return out;
    }
  };

  const heard: string[] = [];
  const terms: MemoryTerm[] = [];
  for (let i = int(size + 1); i > 0; i -= 1) {
    const p = phrase();
    const aliases = Array.from({ length: int(3) }, phrase);
    const pronunciations = Array.from({ length: int(2) }, phrase);
    heard.push(p, ...aliases, ...pronunciations);
    terms.push({
      id: `t${terms.length}`, phrase: p, aliases, pronunciations, language: pick(LANGUAGES), priority: 'normal',
      notes: '', usageCount: 0, createdAt: NOW, updatedAt: NOW,
    });
  }
  const rules: ReplacementRule[] = [];
  for (let i = int(Math.floor(size / 2) + 2); i > 0; i -= 1) {
    const match = rnd() < 0.5 && heard.length ? pick(heard) : phrase();
    let replacement = rnd() < 0.5 ? phrase() : `${match} ${pick(ATOMS)}`;
    if (int(10) === 0) replacement = '$0 \\1 $&';
    const modeRoll = int(10);
    const matchMode: MatchMode = modeRoll === 0 ? 'exact' : modeRoll === 1 ? 'caseInsensitivePhrase' : 'wordBoundaryPhrase';
    rules.push({
      id: `r${rules.length}`, match, replacement, matchMode, language: pick(LANGUAGES), isEnabled: int(12) !== 0,
      usageCount: 0, createdAt: NOW, updatedAt: NOW,
    });
  }
  const snippets: MemorySnippet[] = [];
  for (let i = int(4); i > 0; i -= 1) {
    snippets.push({
      id: `s${snippets.length}`, trigger: rnd() < 0.5 && heard.length ? pick(heard) : phrase(), expansion: phrase(),
      language: pick(LANGUAGES), isEnabled: int(10) !== 0, usageCount: 0, createdAt: NOW, updatedAt: NOW,
    });
  }
  let text = '';
  for (let i = int(61); i > 0; i -= 1) {
    const piece = heard.length && int(3) === 0 ? recase(pick(heard)) : recase(pick(ATOMS));
    text += piece + (int(6) === 0 ? '' : pick(SEPARATORS));
  }
  return { snapshot: { terms, replacements: rules, snippets, suggestions: [] }, text, language: pick(LANGUAGES) };
}

const SIZES = [4, 12, 40, 120];

describe('indexed Language Memory against the old matcher', () => {
  it('applyMemory agrees on random memory', () => {
    for (let seed = 0; seed < CASES; seed += 1) {
      const s = scenario(seed, SIZES[seed % 4] as number);
      const expected = legacyApplyMemory(s.text, s.snapshot, s.language);
      const actual = applyMemory(s.text, s.snapshot, s.language);
      expect(actual, `seed ${seed}`).toEqual(expected);
    }
  });

  it('RuleSet agrees on random rule sets', () => {
    for (let seed = 0; seed < CASES; seed += 1) {
      const s = scenario(seed + 1_000_000, SIZES[seed % 4] as number);
      const expected = new LegacyRuleSet(s.snapshot.replacements, s.language).apply(s.text);
      const actual = new RuleSet(s.snapshot.replacements, s.language).apply(s.text);
      expect(actual, `seed ${seed}`).toEqual(expected);
    }
  });

  it('matchingTermIds agrees on random dictionaries', () => {
    for (let seed = 0; seed < CASES; seed += 1) {
      const s = scenario(seed + 2_000_000, SIZES[seed % 4] as number);
      const texts = [s.text, s.text.toUpperCase(), '', s.text.slice(0, 20)];
      expect(matchingTermIds(s.snapshot.terms, texts, s.language), `seed ${seed}`)
        .toEqual(legacyMatchingTermIds(s.snapshot.terms, texts, s.language));
    }
  });

  it('the index never rejects a phrase the regex matches', () => {
    let matched = 0;
    let rejected = 0;
    for (let seed = 0; seed < CASES; seed += 1) {
      const s = scenario(seed + 3_000_000, 40);
      for (const text of [s.text, s.text.toUpperCase(), s.text.toLowerCase()]) {
        const index = new TextIndex(text);
        for (const term of s.snapshot.terms) {
          for (const phrase of [term.phrase, ...term.aliases, ...term.pronunciations]) {
            const signature = phraseSignature(phrase);
            if (!signature) continue;
            const regexMatches = containsWordBoundaryPhrase(phrase, text);
            const may = index.mayContain(signature);
            if (regexMatches) {
              matched += 1;
              expect(may, `index rejected ${JSON.stringify(phrase)} in ${JSON.stringify(text)}`).toBe(true);
            } else if (!may) rejected += 1;
          }
        }
      }
    }
    expect(matched).toBeGreaterThan(100);
    expect(rejected).toBeGreaterThan(100);
  });

  it('an incrementally updated index equals a fresh one and keeps every window', () => {
    for (let seed = 0; seed < CASES; seed += 1) {
      const rnd = rngFrom(seed + 4_000_000);
      const pieces = ['ab', 'ß', 'ﬁ', '🙂', 'K', 'İ', ' ', 'x́', 'Σ', 'cafe', 'é'];
      let text = Array.from({ length: Math.floor(rnd() * 30) }, () => pieces[Math.floor(rnd() * pieces.length)]).join('');
      const index = new TextIndex(text);
      const everSeen: Uint32Array[] = [skeletonOf(text).skeleton];
      for (let step = 0; step < 8; step += 1) {
        // Rewrite a random stretch, sometimes not at all, sometimes the lot.
        const units = [...text];
        const from = Math.floor(rnd() * (units.length + 1));
        const to = Math.min(units.length, from + Math.floor(rnd() * 5));
        const insert = Array.from({ length: Math.floor(rnd() * 4) }, () => pieces[Math.floor(rnd() * pieces.length)]).join('');
        text = units.slice(0, from).join('') + insert + units.slice(to).join('');
        index.absorb(text);
        const fresh = skeletonOf(text);
        const now = index.currentSkeleton();
        expect([...now.skeleton], `seed ${seed} step ${step}`).toEqual([...fresh.skeleton]);
        expect([...now.ascii]).toEqual([...fresh.ascii]);
        expect([...now.starts]).toEqual([...fresh.starts]);
        everSeen.push(fresh.skeleton);
        // Every window of every version seen so far is still in the sets.
        let lost = 0;
        for (const sk of everSeen) {
          for (let i = 0; i < sk.length; i += 1) {
            for (const len of [1, 2, 3]) {
              if (i + len <= sk.length && !index.windowsPresent(sk.subarray(i, i + len))) lost += 1;
            }
          }
        }
        expect(lost, `seed ${seed} step ${step}: windows lost`).toBe(0);
      }
    }
  });

  it('the skeleton covers every case folding the regex knows', () => {
    // Every code point that changes under case mapping, as one-letter words.
    const cased: string[] = [];
    for (let cp = 0x20; cp <= 0x1ffff; cp += 1) {
      if (cp >= 0xd800 && cp <= 0xdfff) continue;
      const ch = String.fromCodePoint(cp);
      if (ch.toUpperCase() !== ch || ch.toLowerCase() !== ch) cased.push(ch);
    }
    expect(cased.length).toBeGreaterThan(2000);
    const patterns = new Set<string>(cased);
    for (let a = 0x61; a <= 0x7a; a += 1) {
      patterns.add(String.fromCharCode(a));
      for (let b = 0x61; b <= 0x7a; b += 1) patterns.add(String.fromCharCode(a, b));
    }
    for (const extra of ['ffi', 'ffl', 'fff', 'sss', 'ij', 'ss', 'st', 'fi', 'fl', 'ff']) patterns.add(extra);
    for (const ch of cased) { patterns.add(ch.toLowerCase()); patterns.add(ch.toUpperCase()); }

    let checked = 0;
    const failures: string[] = [];
    for (const pattern of patterns) {
      const signature = phraseSignature(pattern);
      if (!signature) continue;
      const escaped = pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const regex = new RegExp(escaped, 'giu');
      // Search every cased code point (and every pair, for the two-letter patterns) as the text.
      for (const found of [...cased.join(' ').matchAll(regex)]) {
        checked += 1;
        if (!new TextIndex(found[0]).mayContain(signature)) {
          failures.push(`${JSON.stringify(pattern)} matches ${JSON.stringify(found[0])}`);
        }
      }
    }
    expect(checked).toBeGreaterThan(3000);
    expect(failures.slice(0, 10)).toEqual([]);
  });
});
