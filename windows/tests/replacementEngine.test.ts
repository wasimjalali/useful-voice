import { describe, expect, it } from 'vitest';
import { RuleSet, applyReplacements } from '../src/core/memory/replacementEngine.js';
import type { MemoryLanguage, ReplacementRule } from '../src/core/models.js';

let counter = 0;
function rule(partial: Partial<ReplacementRule> & { match: string; replacement: string }): ReplacementRule {
  counter += 1;
  return {
    id: partial.id ?? `rule-${counter}`,
    match: partial.match,
    replacement: partial.replacement,
    matchMode: partial.matchMode ?? 'wordBoundaryPhrase',
    language: partial.language ?? 'auto',
    isEnabled: partial.isEnabled ?? true,
    usageCount: partial.usageCount ?? 0,
    createdAt: partial.createdAt ?? '2026-01-01T00:00:00.000Z',
    updatedAt: partial.updatedAt ?? '2026-01-01T00:00:00.000Z',
  };
}

describe('applyReplacements', () => {
  it('replaces whole words', () => {
    const result = applyReplacements(
      [rule({ match: 'cloud code', replacement: 'Claude Code' })],
      'I love cloud code.',
      'en',
    );
    expect(result.text).toBe('I love Claude Code.');
    expect(result.appliedRuleIds).toHaveLength(1);
  });

  it('does not replace inside a longer word', () => {
    const result = applyReplacements(
      [rule({ match: 'sig', replacement: 'signature' })],
      'the signal was clear',
      'en',
    );
    expect(result.text).toBe('the signal was clear');
    expect(result.appliedRuleIds).toEqual([]);
  });

  it('prefers the longest match so phrases beat their own fragments', () => {
    const rules = [
      rule({ id: 'short', match: 'code', replacement: 'CODE' }),
      rule({ id: 'long', match: 'claude code', replacement: 'Claude Code' }),
    ];
    const result = applyReplacements(rules, 'try claude code now', 'en');
    expect(result.text).toBe('try Claude Code now');
  });

  it('does not rewrite text another rule produced, but still handles the rest', () => {
    // Guards the cascade semantics: a rule must not re-match inside a previous
    // rule's output ("Claude Code" -> "Claude CODE"), while still applying to
    // genuine occurrences elsewhere in the transcript.
    const rules = [
      rule({ id: 'short', match: 'code', replacement: 'CODE' }),
      rule({ id: 'long', match: 'claude code', replacement: 'Claude Code' }),
    ];
    const result = applyReplacements(rules, 'claude code and the code', 'en');
    expect(result.text).toBe('Claude Code and the CODE');
  });

  it('protects every occurrence a rule produced', () => {
    const rules = [
      rule({ id: 'short', match: 'code', replacement: 'CODE' }),
      rule({ id: 'long', match: 'claude code', replacement: 'Claude Code' }),
    ];
    const result = applyReplacements(rules, 'claude code, claude code', 'en');
    expect(result.text).toBe('Claude Code, Claude Code');
  });

  it('never leaves the internal protection marker in output', () => {
    const rules = [
      rule({ id: 'short', match: 'code', replacement: 'CODE' }),
      rule({ id: 'long', match: 'claude code', replacement: 'Claude Code' }),
    ];
    const result = applyReplacements(rules, 'claude code and code', 'en');
    expect(result.text).not.toMatch(/[\u0000-\u001f]/u);
  });

  it('keeps user replacements literal, including dollar signs', () => {
    // `String.replace` treats `$1` and `$&` specially in the replacement string;
    // user text must survive verbatim.
    const result = applyReplacements(
      [rule({ match: 'price', replacement: '$1.00 & more' })],
      'the price is set',
      'en',
    );
    expect(result.text).toBe('the $1.00 & more is set');
  });

  it('skips disabled rules and non-matching languages', () => {
    const rules = [
      rule({ id: 'off', match: 'alpha', replacement: 'ALPHA', isEnabled: false }),
      rule({ id: 'de', match: 'beta', replacement: 'BETA', language: 'de' as MemoryLanguage }),
    ];
    const result = applyReplacements(rules, 'alpha beta', 'en');
    expect(result.text).toBe('alpha beta');
    expect(result.appliedRuleIds).toEqual([]);
  });

  it('applies auto-language rules for any target language', () => {
    const result = applyReplacements(
      [rule({ match: 'alpha', replacement: 'ALPHA', language: 'auto' })],
      'alpha',
      'de',
    );
    expect(result.text).toBe('ALPHA');
  });

  it('is deterministic for equal-length matches regardless of input order', () => {
    const a = rule({ id: 'aaa', match: 'DF unit', replacement: 'Delta Force' });
    const b = rule({ id: 'bbb', match: 'BS unit', replacement: 'Bravo Squad' });
    const first = applyReplacements([a, b], 'send DF unit and BS unit', 'en').text;
    const second = applyReplacements([b, a], 'send DF unit and BS unit', 'en').text;
    expect(first).toBe(second);
  });

  it('treats regex metacharacters in the match as literals', () => {
    const result = applyReplacements(
      [rule({ match: 'a.b', replacement: 'A-B' })],
      'axb and a.b',
      'en',
    );
    expect(result.text).toBe('axb and A-B');
  });

  it('supports case-only normalization without touching larger words', () => {
    // The form the dictionary uses for casing: match === replacement.
    const rules = [rule({ match: 'claude code', replacement: 'Claude Code' })];
    expect(applyReplacements(rules, 'open claude code', 'en').text).toBe('open Claude Code');
    expect(applyReplacements(rules, 'open claudecodes', 'en').text).toBe('open claudecodes');
  });

  it('excludes rules by id, for the post-processor second pass', () => {
    const a = rule({ id: 'fired', match: 'Karko', replacement: 'Karko AI' });
    const result = applyReplacements([a], 'Karko', 'en', new Set(['fired']));
    expect(result.text).toBe('Karko');
  });
});

describe('RuleSet', () => {
  it('compiles once and reuses across passes', () => {
    const set = new RuleSet([rule({ match: 'alpha', replacement: 'ALPHA' })], 'en');
    expect(set.size).toBe(1);
    expect(set.apply('alpha').text).toBe('ALPHA');
    expect(set.apply('alpha again').text).toBe('ALPHA again');
  });

  it('never throws on a pathological phrase', () => {
    const set = new RuleSet([rule({ match: '((((', replacement: 'x' })], 'en');
    expect(() => set.apply('(((( and other text')).not.toThrow();
  });
});
