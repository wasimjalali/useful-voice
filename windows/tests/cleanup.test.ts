import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { applyCleanupRules } from '../src/core/formatting/cleanupRules.js';
import {
  evaluateCleanupOutput,
  STANDARD_GUARD_LIMITS,
  type GuardReason,
} from '../src/core/formatting/cleanupGuard.js';
import {
  S1_MINI_SYSTEM_PROMPT,
  s1ControlLine,
  s1Settings,
  s1UserMessage,
} from '../src/core/formatting/cleanupControlLine.js';

// The fixtures are shared with the Swift tests (CleanupTests.swift), so the two cores
// are held to the same rows rather than two hand-copied lists.
function fixture<T>(name: string): T {
  return JSON.parse(
    readFileSync(new URL(`../../evals/cleanup/fixtures/${name}`, import.meta.url), 'utf8'),
  ) as T;
}

interface RulesRow { name: string; input: string; expected: string }
interface GuardRow { name: string; rulesText: string; output: string; verdict: string; text?: string }
interface ControlRow { category: string | null; style: string | null; line: string }

const rules = fixture<RulesRow[]>('rules.json');
const guardRows = fixture<GuardRow[]>('guard.json');
const control = fixture<{ systemPrompt: string; rows: ControlRow[] }>('controlline.json');

/** Letters and digits only, lowercase, so punctuation and case do not matter. */
function wordList(text: string): string[] {
  return text
    .toLowerCase()
    .split(/\s+/)
    .map((w) => w.replace(/[^\p{L}\p{N}']/gu, ''))
    .filter((w) => w !== '');
}

function isSubsequence(small: string[], big: string[]): boolean {
  let i = 0;
  for (const w of big) if (w === small[i]) i += 1;
  return i === small.length;
}

describe('applyCleanupRules fixtures', () => {
  it('has at least 120 rows', () => {
    expect(rules.length).toBeGreaterThanOrEqual(120);
  });

  for (const row of rules) {
    it(row.name, () => {
      expect(applyCleanupRules(row.input, 'en')).toBe(row.expected);
    });
  }

  it('only ever deletes words: the output words are a subsequence of the input words', () => {
    for (const row of rules) {
      const out = wordList(applyCleanupRules(row.input, 'en'));
      expect(isSubsequence(out, wordList(row.input)), row.name).toBe(true);
    }
  });

  it('is idempotent', () => {
    for (const row of rules) {
      const once = applyCleanupRules(row.input, 'en');
      expect(applyCleanupRules(once, 'en'), row.name).toBe(once);
    }
  });
});

/**
 * Seeded generator shared with CleanupTests.swift (same LCG, vocabulary and separators), so both
 * suites check the same 3,000 generated inputs.
 */
const PROPERTY_VOCAB = [
  'um', 'Um', 'um,', 'Um,', 'uh', 'Uh,', 'er', 'Er', 'erm,', 'hmm', 'Hmm,', 'hmm.', 'um.', 'uh...',
  'huh', 'huh?', 'mm', 'the', 'The', 'the,', 'I', 'I,', 'it', 'It', 'so', 'So', 'that', 'is', 'and,',
  'and', 'five', 'Five', '5', '0', 'ho', 'Ho', 'word', 'said', 'said,', 'Dr.', 'Mrs.', 'etc.', 'well,',
  'Well,', 'apples,', 'pears,', 'go.', 'stop.', 'Okay.', 'okay', 'We', 'we', 'ship', 'Friday,', 'or',
  'Monday.', 'app.ts', 'iPhone', "don't", 'I\u2019m', 'caf\u00E9', 'No', 'no,', 'my', 'My', '(um)',
];
const PROPERTY_SEPARATORS = [' ', ' ', ' ', '  ', '\n', '\r\n', '\u00A0'];

function propertyInputs(seed: number, count: number): string[] {
  let state = seed >>> 0;
  const next = (n: number): number => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return (state >>> 8) % n;
  };
  const out: string[] = [];
  for (let k = 0; k < count; k += 1) {
    const length = 1 + next(12);
    let text = '';
    for (let t = 0; t < length; t += 1) {
      if (t > 0) text += PROPERTY_SEPARATORS[next(PROPERTY_SEPARATORS.length)];
      text += PROPERTY_VOCAB[next(PROPERTY_VOCAB.length)];
    }
    out.push(text);
  }
  return out;
}

describe('applyCleanupRules properties (seeded)', () => {
  const inputs = propertyInputs(20261016, 3000);
  it('is idempotent on generated inputs', () => {
    for (const input of inputs) {
      const once = applyCleanupRules(input, 'en');
      expect(applyCleanupRules(once, 'en'), JSON.stringify(input)).toBe(once);
    }
  });
  it('only deletes words on generated inputs', () => {
    for (const input of inputs) {
      const out = wordList(applyCleanupRules(input, 'en'));
      expect(isSubsequence(out, wordList(input)), JSON.stringify(input)).toBe(true);
    }
  });
});

describe('applyCleanupRules language gate', () => {
  const text = 'Um, so we the the go.';
  it('cleans English codes', () => {
    expect(applyCleanupRules(text, 'en')).toBe('So we the go.');
    expect(applyCleanupRules(text, 'EN-us')).toBe('So we the go.');
    expect(applyCleanupRules(text, 'en-GB')).toBe('So we the go.');
  });
  it('leaves other languages, empty codes and unknown language alone', () => {
    expect(applyCleanupRules(text, 'de')).toBe(text);
    expect(applyCleanupRules('um, a casa', 'pt-BR')).toBe('um, a casa');
    expect(applyCleanupRules(text, null)).toBe(text);
    expect(applyCleanupRules(text, undefined)).toBe(text);
    expect(applyCleanupRules(text, '')).toBe(text);
  });
});

describe('evaluateCleanupOutput fixtures', () => {
  for (const row of guardRows) {
    it(row.name, () => {
      const verdict = evaluateCleanupOutput(row.rulesText, row.output);
      if (row.verdict === 'accept') {
        expect(verdict).toEqual({ accepted: true, text: row.text });
      } else {
        expect(verdict).toEqual({ accepted: false, reason: row.verdict as GuardReason });
      }
    });
  }

  it('covers every rejection reason', () => {
    const reasons = new Set(guardRows.map((r) => r.verdict));
    for (const reason of ['accept', 'reasoning', 'empty', 'tooLong', 'noWordChange', 'droppedContent', 'addedContent']) {
      expect(reasons.has(reason), reason).toBe(true);
    }
  });

  it('honours custom limits', () => {
    const input = 'Ship the release candidate tonight.';
    const output = 'Ship the release tonight.';
    expect(evaluateCleanupOutput(input, output).accepted).toBe(false);
    expect(evaluateCleanupOutput(input, output, { ...STANDARD_GUARD_LIMITS, maxDropShare: 0.5 }).accepted).toBe(true);
  });

  it('is case blind and format blind', () => {
    const verdict = evaluateCleanupOutput('so um we ship friday', 'SO, WE SHIP: FRIDAY!!');
    expect(verdict.accepted).toBe(true);
  });

  it('can allow format-only edits', () => {
    const input = 'Buy milk, eggs and bread.';
    const output = 'Buy milk, eggs, and bread.';
    expect(evaluateCleanupOutput(input, output)).toEqual({ accepted: false, reason: 'noWordChange' });
    expect(evaluateCleanupOutput(input, output, { ...STANDARD_GUARD_LIMITS, requireWordChange: false }).accepted).toBe(true);
  });
});

describe('S1-mini control line', () => {
  it('copies the model card system prompt byte for byte', () => {
    expect(S1_MINI_SYSTEM_PROMPT).toBe(control.systemPrompt);
    expect(S1_MINI_SYSTEM_PROMPT).toBe(
      'You are a text normalizer for speech-to-text transcripts. The input begins with a control line ' +
        'specifying the styling, structure, and context settings; clean the transcript to match those ' +
        'settings and output only the cleaned text.',
    );
  });

  for (const row of control.rows) {
    it(`maps ${JSON.stringify(row.category)} / ${JSON.stringify(row.style)}`, () => {
      expect(s1ControlLine(row.category, row.style)).toBe(row.line);
    });
  }

  it('only produces values the model was trained on', () => {
    const trained = /^\[Styling: (casual|semi-casual|semi-formal|formal)\] \[Structure: prose\] \[Context: (general|email)\]$/;
    for (const category of [null, 'email', 'chat', 'coding', 'x', '', 'Notes']) {
      for (const style of [null, 'casual', 'formal', 'semi-casual', 'semi-formal', 'weird']) {
        expect(s1ControlLine(category, style)).toMatch(trained);
      }
    }
  });

  it('puts the control line and the transcript on separate lines', () => {
    expect(s1UserMessage('email', null, 'hello')).toBe(
      '[Styling: semi-formal] [Structure: prose] [Context: email]\nhello',
    );
    expect(s1Settings('chat', 'formal')).toEqual({ styling: 'formal', structure: 'prose', context: 'general' });
  });
});
