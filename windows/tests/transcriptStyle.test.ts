import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { applyTranscriptStyle } from '../src/core/formatting/transcriptStyle.js';

// Recorded Deepgram output from evals/formatting, run through the real code so the
// check covers what Deepgram actually returned. Mirrors TranscriptStyleEvalTests.swift.
interface Row {
  id: string;
  lang: string;
  got: string;
  expected: string;
  accept?: string[];
  known_gap?: string;
}
const rows: Row[] = JSON.parse(
  readFileSync(
    new URL('../../evals/results/raw/2026-09-29-formatting-candidate.json', import.meta.url),
    'utf8',
  ),
).rows;

describe('applyTranscriptStyle on recorded Deepgram output', () => {
  it('ends up as expected', () => {
    expect(rows).toHaveLength(83);
    const failures = rows
      .filter((row) => !row.known_gap)
      .map((row) => ({ row, styled: applyTranscriptStyle(row.got, row.lang) }))
      .filter(({ row, styled }) => ![row.expected, ...(row.accept ?? [])].includes(styled))
      .map(({ row, styled }) => `${row.id}: got "${styled}", want "${row.expected}"`);
    expect(failures).toEqual([]);
  });

  it('keeps known gaps as digits rather than guessing an ending', () => {
    expect(rows.filter((r) => r.known_gap)).toHaveLength(3);
    for (const row of rows.filter((r) => r.known_gap)) {
      // "der 3." and "die 3." have no certain ending, so the digit must survive.
      const styled = applyTranscriptStyle(row.got, row.lang);
      const gaps = row.got.match(/\b(?:der|die) \d\./gi) ?? [];
      expect(gaps.length).toBeGreaterThan(0);
      for (const gap of gaps) expect(styled).toContain(gap);
    }
  });

  it('keeps digits for the false positives found in review and changes only what is safe', () => {
    const { cases } = JSON.parse(
      readFileSync(new URL('../../evals/formatting/style-guards.json', import.meta.url), 'utf8'),
    ) as { cases: { lang: string; input: string; expected: string }[] };
    expect(cases).toHaveLength(168);
    const failures = cases
      .map((c) => ({ c, styled: applyTranscriptStyle(c.input, c.lang) }))
      .filter(({ c, styled }) => styled !== c.expected)
      .map(({ c, styled }) => `${c.input} -> ${styled}, want ${c.expected}`);
    expect(failures).toEqual([]);
  });

  it('leaves other languages untouched', () => {
    expect(applyTranscriptStyle('Es waren 3 Leute dabei.', 'auto')).toBe('Es waren 3 Leute dabei.');
    expect(applyTranscriptStyle('Il y a 3 personnes.', 'fr')).toBe('Il y a 3 personnes.');
  });
});
