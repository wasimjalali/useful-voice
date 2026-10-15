import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import type { AppCategory, FormattingStyle } from '../src/core/apps/appCategory.js';
import { formatCoding } from '../src/core/formatting/categoryCoding.js';
import {
  applyContinuation,
  capitalizeFirstWord,
  isAtLineStart,
  isMidSentence,
  lowercaseFirstWord,
  needsLeadingSpace,
} from '../src/core/formatting/categoryContinuation.js';
import { structureEmail } from '../src/core/formatting/categoryEmail.js';
import { formatForCategory } from '../src/core/formatting/categoryFormatter.js';
import { applyStyle, dropTrailingFullStop } from '../src/core/formatting/categoryStyle.js';

// The same cases drive CategoryFormatterTests.swift, so the two platforms cannot drift.
interface Case {
  id: string;
  category: AppCategory;
  style?: FormattingStyle;
  userName?: string;
  before?: string;
  words?: string[];
  input: string;
  expected: string;
}
const cases: Case[] = JSON.parse(
  readFileSync(
    new URL('../../Tests/Fixtures/app-awareness/formatter-cases.json', import.meta.url),
    'utf8',
  ),
).cases;

function run(c: Case): string {
  return formatForCategory(c.input, {
    category: c.category,
    style: c.style ?? null,
    userName: c.userName ?? null,
    textBeforeCursor: c.before ?? null,
    dictionaryWords: c.words ?? [],
  });
}

describe('formatForCategory on the shared cases', () => {
  it('has the cases it should', () => {
    expect(cases).toHaveLength(257);
    const prefixes = new Set(cases.map((c) => c.id.split('-')[0]));
    for (const p of ['empty', 'blank', 'code', 'nocode', 'style', 'cont', 'email']) {
      expect(prefixes.has(p), p).toBe(true);
    }
  });

  it('gives the expected text for every case', () => {
    const failures = cases
      .map((c) => ({ c, got: run(c) }))
      .filter(({ c, got }) => got !== c.expected)
      .map(({ c, got }) => `${c.id}: got ${JSON.stringify(got)}, want ${JSON.stringify(c.expected)}`);
    expect(failures).toEqual([]);
  });

  it('is stable: formatting a second time with no context changes nothing more', () => {
    // Email layout, Coding conversion and the chat full stop are all one-way, so a second pass
    // over their own output must not keep rewriting. Skip cases that add context-only changes.
    const unstable = cases
      .filter((c) => c.before === undefined && c.category !== 'email')
      .map((c) => {
        const once = run(c);
        const twice = formatForCategory(once, {
          category: c.category,
          style: c.style ?? null,
          dictionaryWords: c.words ?? [],
        });
        return { id: c.id, once, twice };
      })
      .filter(({ once, twice }) => once !== twice);
    expect(unstable).toEqual([]);
  });
});

describe('restraint', () => {
  it('leaves already-clean text alone in every category', () => {
    const clean = ['Hello there', 'Thanks for the update', 'ok', 'See you at 5 pm'];
    for (const category of ['email', 'workChat', 'personalChat', 'coding', 'docsNotes', 'other'] as const) {
      for (const text of clean) {
        expect(formatForCategory(text, { category, style: 'formal' }), `${category}: ${text}`).toBe(text);
      }
    }
  });

  it('never adds a greeting, sign-off or name that was not dictated', () => {
    const text = 'We reviewed the plan this morning and agreed that the schedule is tight but still workable if nobody changes the scope again this month and the team stays on track.';
    const out = formatForCategory(text, { category: 'email', userName: 'Wasim' });
    expect(out).toBe(text);
    expect(out).not.toContain('Wasim');
  });

  it('does not touch spoken symbols outside Coding', () => {
    for (const category of ['email', 'workChat', 'personalChat', 'docsNotes', 'other'] as const) {
      expect(formatForCategory('a dot on the map, src slash app dot tsx', { category, style: 'formal' })).toBe(
        'a dot on the map, src slash app dot tsx',
      );
    }
  });

  it('keeps every word the speaker said in Coding when no symbol converts', () => {
    const prose = 'look at the docs and tag the release, he slash she, a dot on the map';
    expect(formatCoding(prose)).toBe(prose);
  });
});

describe('continuation helpers', () => {
  it('isMidSentence', () => {
    expect(isMidSentence(null)).toBe(false);
    expect(isMidSentence(undefined)).toBe(false);
    expect(isMidSentence('')).toBe(false);
    expect(isMidSentence('   ')).toBe(false);
    expect(isMidSentence('Hello')).toBe(true);
    expect(isMidSentence('Hello ')).toBe(true);
    expect(isMidSentence('Hello,')).toBe(true);
    for (const end of ['.', '!', '?', ':']) expect(isMidSentence(`Hello${end}`), end).toBe(false);
    expect(isMidSentence('Hello\n')).toBe(false);
    expect(isMidSentence('Hello \n  ')).toBe(false);
    expect(isMidSentence('He said "ok."')).toBe(false);
    expect(isMidSentence('(done.)')).toBe(false);
    expect(isMidSentence('(see below)')).toBe(true);
    expect(isMidSentence('- ')).toBe(false);
    expect(isMidSentence('Buy - ')).toBe(true);
  });

  it('isAtLineStart', () => {
    expect(isAtLineStart(null)).toBe(false);
    expect(isAtLineStart('')).toBe(true);
    expect(isAtLineStart('  ')).toBe(true);
    expect(isAtLineStart('Hi\n')).toBe(true);
    expect(isAtLineStart('Hi\n  ')).toBe(true);
    expect(isAtLineStart('Hi')).toBe(false);
    expect(isAtLineStart('Hi. ')).toBe(false);
  });

  it('needsLeadingSpace', () => {
    expect(needsLeadingSpace('', 'Hello')).toBe(false);
    expect(needsLeadingSpace('Hello', '')).toBe(false);
    expect(needsLeadingSpace('Hello', 'world')).toBe(true);
    expect(needsLeadingSpace('Hello ', 'world')).toBe(false);
    expect(needsLeadingSpace('Hello\n', 'world')).toBe(false);
    expect(needsLeadingSpace('Hello', ' world')).toBe(false);
    expect(needsLeadingSpace('Hello', ', world')).toBe(false);
    expect(needsLeadingSpace('Hello', '(world)')).toBe(true);
    expect(needsLeadingSpace('a (', 'world')).toBe(false);
    expect(needsLeadingSpace('say "', 'world')).toBe(false);
    expect(needsLeadingSpace('say "hi"', 'world')).toBe(true);
    expect(needsLeadingSpace('src/', 'app')).toBe(false);
  });

  it('lowercaseFirstWord and capitalizeFirstWord', () => {
    expect(lowercaseFirstWord('Hello', [])).toBe('hello');
    expect(lowercaseFirstWord('  Hello', [])).toBe('  hello');
    expect(lowercaseFirstWord('', [])).toBe('');
    expect(lowercaseFirstWord('hello', [])).toBe('hello');
    expect(lowercaseFirstWord('I am', [])).toBe('I am');
    expect(lowercaseFirstWord('I\u2019d go', [])).toBe('I\u2019d go');
    expect(lowercaseFirstWord('NASA', [])).toBe('NASA');
    expect(lowercaseFirstWord('iPhone', [])).toBe('iPhone');
    expect(lowercaseFirstWord('Sam', ['sam'])).toBe('Sam');
    expect(lowercaseFirstWord('Sam', [' '])).toBe('sam');
    expect(capitalizeFirstWord('thanks', [])).toBe('Thanks');
    expect(capitalizeFirstWord('iPhone', [])).toBe('iPhone');
    expect(capitalizeFirstWord('npm', ['npm'])).toBe('npm');
    expect(capitalizeFirstWord('5 pm', [])).toBe('5 pm');
    expect(capitalizeFirstWord('', [])).toBe('');
  });

  it('applyContinuation leaves unknown context alone and can skip lowercasing', () => {
    expect(applyContinuation(null, 'Hello', [])).toBe('Hello');
    expect(applyContinuation(undefined, 'Hello', [])).toBe('Hello');
    expect(applyContinuation('and', 'Hello', [])).toBe(' hello');
    expect(applyContinuation('and', 'Hello', [], { lowercase: false })).toBe(' Hello');
  });
});

describe('style helpers', () => {
  it('dropTrailingFullStop', () => {
    expect(dropTrailingFullStop('Sounds good.')).toBe('Sounds good');
    expect(dropTrailingFullStop('Sounds good')).toBe('Sounds good');
    expect(dropTrailingFullStop('Sounds good?')).toBe('Sounds good?');
    expect(dropTrailingFullStop('')).toBe('');
    expect(dropTrailingFullStop('.')).toBe('.');
    expect(dropTrailingFullStop('Wait..')).toBe('Wait..');
  });

  it('applyStyle', () => {
    expect(applyStyle('Sounds good.', 'formal', [])).toBe('Sounds good.');
    expect(applyStyle('Sounds good.', 'casual', [])).toBe('Sounds good');
    expect(applyStyle('Sounds good.', 'veryCasual', [])).toBe('sounds good');
  });
});

describe('email layout', () => {
  it('needs 25 words or a greeting', () => {
    const body = (n: number) => `Word ${Array.from({ length: n - 2 }, () => 'word').join(' ')} word.`;
    const atLimit = `${body(23)} Thanks, Sam`;
    expect(atLimit.split(' ')).toHaveLength(25);
    expect(structureEmail(atLimit, null)).toBe(`${body(23)}\n\nThanks,\nSam`);
    const underLimit = `${body(22)} Thanks, Sam`;
    expect(underLimit.split(' ')).toHaveLength(24);
    expect(structureEmail(underLimit, null)).toBe(underLimit);
    expect(structureEmail(`Hi Sam, ${body(2)}`, null)).toBe('Hi Sam,\n\nWord word.');
  });

  it('keeps text unchanged when it has a line break', () => {
    expect(structureEmail('Hi Sam,\nthanks', 'Wasim')).toBe('Hi Sam,\nthanks');
  });
});
