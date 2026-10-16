import { describe, it } from 'vitest';
import { writeFileSync } from 'node:fs';
import { applyMemory } from '../src/core/memory/memoryPostProcessor.js';
import { applyMemory as legacyApplyMemory } from './legacy/legacyMemoryPostProcessor.js';
import type {
  LanguageMemorySnapshot,
  MemoryLanguage,
  MemoryTerm,
  ReplacementRule,
} from '../src/core/models.js';

/**
 * Language Memory benchmark for the Windows core, the counterpart of the Swift
 * `LanguageMemoryBenchTests`. Off unless UV_LM_BENCH=1:
 *
 *   UV_LM_BENCH=1 UV_LM_BENCH_OUT=out.jsonl npx vitest run tests/languageMemoryBench.test.ts
 *
 * A 15,149-character transcript, 1,000 and 5,000 terms (a third English, a third
 * German, a third language-neutral), auto scope and detected `de`. It prints one
 * `LMBENCH {json}` line per case. UV_LM_BENCH_SIDE=legacy times the pre-index code kept in
 * tests/legacy instead (the "before" side). The corpus is generated from a fixed seed; it follows
 * the Swift corpus's shape but is not byte-identical to it.
 */
const enabled = process.env.UV_LM_BENCH === '1';

class SplitMix64 {
  private state: bigint;
  constructor(seed: bigint) { this.state = BigInt.asUintN(64, seed); }
  next(): bigint {
    this.state = BigInt.asUintN(64, this.state + 0x9e3779b97f4a7c15n);
    let z = this.state;
    z = BigInt.asUintN(64, (z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n);
    z = BigInt.asUintN(64, (z ^ (z >> 27n)) * 0x94d049bb133111ebn);
    return z ^ (z >> 31n);
  }
  /** Uniform integer in [0, n). */
  int(n: number): number { return Number(this.next() % BigInt(n)); }
  range(lo: number, hi: number): number { return lo + this.int(hi - lo + 1); }
  float(): number { return Number(this.next() >> 11n) / 2 ** 53; }
  pick<T>(xs: readonly T[]): T { return xs[this.int(xs.length)] as T; }
}

const ONSETS = ['b', 'br', 'c', 'ch', 'cl', 'd', 'dr', 'f', 'fl', 'g', 'gr', 'h', 'j', 'k', 'kr', 'l', 'm', 'n', 'p', 'pl',
  'pr', 'r', 's', 'sch', 'sh', 'sp', 'st', 'str', 't', 'th', 'tr', 'v', 'w', 'z'];
const NUCLEI = ['a', 'e', 'i', 'o', 'u', 'ai', 'ea', 'ou', 'au', 'ei', 'ie', 'oo'];
const CODAS = ['', '', 'n', 'r', 'l', 's', 't', 'd', 'm', 'k', 'nd', 'st', 'ng', 'rt', 'ck'];
const GERMAN = ['ä', 'ö', 'ü', 'ß', 'tz', 'sch', 'ung', 'keit', 'ge', 'ver'];

function word(rng: SplitMix64, german: boolean): string {
  let w = '';
  for (let i = rng.range(1, 3); i > 0; i -= 1) w += rng.pick(ONSETS) + rng.pick(NUCLEI) + rng.pick(CODAS);
  if (german && rng.int(3) === 0) w += rng.pick(GERMAN);
  return w;
}

function capitalize(s: string): string {
  return s.replace(/(^|\s)(\S)/gu, (_m, a: string, b: string) => a + b.toUpperCase());
}

function transcript(length: number): string {
  const rng = new SplitMix64(1n);
  const vocabRng = new SplitMix64(77n);
  const seen = new Set<string>();
  const vocab: string[] = [];
  while (vocab.length < 2500) {
    const w = word(vocabRng, vocab.length % 3 === 0);
    if (!seen.has(w)) { seen.add(w); vocab.push(w); }
  }
  let out = '';
  let start = true;
  while (out.length < length) {
    let w = vocab[Math.min(vocab.length - 1, Math.floor(rng.float() ** 2.6 * vocab.length))] as string;
    if (start) w = w.charAt(0).toUpperCase() + w.slice(1);
    out += w;
    start = false;
    const k = rng.int(14);
    if (k === 0) { out += '. '; start = true; } else if (k === 1) out += ', '; else out += ' ';
  }
  return out.slice(0, length);
}

function snapshot(count: number, text: string): LanguageMemorySnapshot {
  const rng = new SplitMix64(5n);
  const words = text.split(/[ .,]+/u).filter(Boolean);
  const terms: MemoryTerm[] = [];
  const seen = new Set<string>();
  const now = '2026-01-01T00:00:00.000Z';
  while (terms.length < count) {
    const german = terms.length % 3 === 1;
    let phrase: string;
    if (rng.int(100) < 8) {
      const at = rng.int(words.length - 3);
      phrase = words.slice(at, at + rng.range(1, 2)).join(' ');
      phrase = rng.int(2) === 0 ? capitalize(phrase) : phrase.toUpperCase();
    } else {
      phrase = Array.from({ length: rng.range(1, 3) }, () => word(rng, german)).join(' ');
      if (rng.int(2) === 0) phrase = capitalize(phrase);
      if (rng.int(10) === 0) phrase += `-${rng.range(2, 9)}`;
    }
    if (seen.has(phrase.toLowerCase())) continue;
    seen.add(phrase.toLowerCase());
    const aliases = Array.from({ length: rng.range(0, 2) }, () =>
      Array.from({ length: rng.range(1, 2) }, () => word(rng, german)).join(' '));
    const pronunciations = rng.int(3) === 0 ? [`${word(rng, german)} ${word(rng, german)}`] : [];
    const language: MemoryLanguage = terms.length % 3 === 0 ? 'auto' : german ? 'de' : 'en';
    terms.push({
      id: `t${terms.length}`, phrase, aliases, pronunciations, language, priority: 'normal', notes: '',
      usageCount: 0, createdAt: now, updatedAt: now,
    });
  }
  const rules: ReplacementRule[] = [];
  const rrng = new SplitMix64(99n);
  for (let i = 0; i < 50; i += 1) {
    const heard = rrng.pick(words);
    rules.push({
      id: `r${i}`, match: heard, replacement: `${capitalize(heard)}!`, matchMode: 'wordBoundaryPhrase',
      language: 'auto', isEnabled: true, usageCount: 0, createdAt: now, updatedAt: now,
    });
  }
  const snippets = Array.from({ length: 20 }, (_v, i) => ({
    id: `s${i}`, trigger: `snip ${rrng.pick(words)}`, expansion: `expansion ${i}`, language: 'auto' as MemoryLanguage,
    isEnabled: true, usageCount: 0, createdAt: now, updatedAt: now,
  }));
  return { terms, replacements: rules, snippets, suggestions: [] };
}

function fingerprint(r: ReturnType<typeof applyMemory>): string {
  let h = 0xcbf29ce484222325n;
  const mix = (s: string): void => {
    for (const b of Buffer.from(s, 'utf8')) h = BigInt.asUintN(64, (h ^ BigInt(b)) * 0x100000001b3n);
    h = BigInt.asUintN(64, (h ^ 0xffn) * 0x100000001b3n);
  };
  mix(r.text);
  [...r.appliedRuleIds, ...r.memoryHitIds, ...r.appliedSnippetIds].forEach(mix);
  return h.toString(16);
}

const side = process.env.UV_LM_BENCH_SIDE === 'legacy' ? 'legacy' : 'production';
const run = side === 'legacy' ? legacyApplyMemory : applyMemory;

describe.skipIf(!enabled)('Language Memory benchmark', () => {
  it('times applyMemory', () => {
    const text = transcript(15_149);
    const runs = Number(process.env.UV_LM_BENCH_RUNS ?? 5);
    const lines: string[] = [];
    for (const size of (process.env.UV_LM_BENCH_SIZES ?? '1000,5000').split(',').map(Number)) {
      const snap = snapshot(size, text);
      for (const [scope, language] of [['auto', 'auto'], ['de', 'de']] as const) {
        const samples: number[] = [];
        let last: ReturnType<typeof applyMemory> | undefined;
        for (let i = 0; i < runs; i += 1) {
          const start = performance.now();
          last = run(text, snap, language);
          samples.push(performance.now() - start);
        }
        const sorted = [...samples].sort((a, b) => a - b);
        const line = JSON.stringify({
          side, terms: size, scope, chars: text.length,
          first_ms: Number(samples[0]?.toFixed(2)), median_ms: Number((sorted[Math.floor(runs / 2)] as number).toFixed(2)),
          min_ms: Number((sorted[0] as number).toFixed(2)), runs, fired: last!.appliedRuleIds.length,
          hits: last!.memoryHitIds.length, snippets: last!.appliedSnippetIds.length, fingerprint: fingerprint(last!),
        });
        console.log(`LMBENCH ${line}`);
        lines.push(line);
      }
    }
    if (process.env.UV_LM_BENCH_OUT) writeFileSync(process.env.UV_LM_BENCH_OUT, `${lines.join('\n')}\n`);
  }, 600_000);
});
