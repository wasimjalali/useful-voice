import { describe, expect, it } from 'vitest';
import { applySnippets } from '../src/core/memory/snippetExpansionEngine.js';
import { applyMemory } from '../src/core/memory/memoryPostProcessor.js';
import { effectiveRules } from '../src/core/memory/dictionaryCorrector.js';
import type {
  LanguageMemorySnapshot,
  MemorySnippet,
  MemoryTerm,
} from '../src/core/models.js';

let counter = 0;
function term(partial: Partial<MemoryTerm> & { phrase: string }): MemoryTerm {
  counter += 1;
  return {
    id: partial.id ?? `term-${counter}`,
    phrase: partial.phrase,
    aliases: partial.aliases ?? [],
    pronunciations: partial.pronunciations ?? [],
    language: partial.language ?? 'auto',
    priority: partial.priority ?? 'normal',
    notes: partial.notes ?? '',
    usageCount: partial.usageCount ?? 0,
    createdAt: partial.createdAt ?? '2026-01-01T00:00:00.000Z',
    updatedAt: partial.updatedAt ?? '2026-01-01T00:00:00.000Z',
  };
}

function snippet(partial: Partial<MemorySnippet> & { trigger: string; expansion: string }): MemorySnippet {
  counter += 1;
  return {
    id: partial.id ?? `snippet-${counter}`,
    trigger: partial.trigger,
    expansion: partial.expansion,
    language: partial.language ?? 'auto',
    isEnabled: partial.isEnabled ?? true,
    usageCount: partial.usageCount ?? 0,
    createdAt: partial.createdAt ?? '2026-01-01T00:00:00.000Z',
    updatedAt: partial.updatedAt ?? '2026-01-01T00:00:00.000Z',
  };
}

function snapshot(partial: Partial<LanguageMemorySnapshot>): LanguageMemorySnapshot {
  return {
    terms: partial.terms ?? [],
    replacements: partial.replacements ?? [],
    snippets: partial.snippets ?? [],
    suggestions: partial.suggestions ?? [],
  };
}

describe('applySnippets', () => {
  it('expands a trigger on word boundaries', () => {
    const result = applySnippets([snippet({ trigger: 'my sig', expansion: 'Best,\nWasim' })], 'thanks my sig', 'en');
    expect(result.text).toBe('thanks Best,\nWasim');
    expect(result.appliedSnippetIds).toHaveLength(1);
  });

  it('does not expand inside a longer word', () => {
    const result = applySnippets([snippet({ trigger: 'sig', expansion: 'signature' })], 'the signal', 'en');
    expect(result.text).toBe('the signal');
    expect(result.appliedSnippetIds).toEqual([]);
  });

  /**
   * Store order is newest-first, so a short trigger added later used to shadow a
   * longer one that contains it and the snippet the user meant never fired.
   */
  it('prefers the longest trigger when one contains another', () => {
    const snippets = [
      snippet({ id: 'short', trigger: 'sig', expansion: 'signature' }),
      snippet({ id: 'long', trigger: 'my sig', expansion: 'Best,\nWasim' }),
    ];
    const result = applySnippets(snippets, 'thanks my sig', 'en');
    expect(result.text).toBe('thanks Best,\nWasim');
    expect(result.appliedSnippetIds).toEqual(['long']);
  });

  /**
   * Chained expansion produced "123 Main Street St": the first snippet's output
   * was re-scanned by the second snippet. Expansion now happens in a single pass
   * over the original text.
   */
  it('does not re-expand text produced by another snippet', () => {
    const snippets = [
      snippet({ id: 'addr', trigger: 'addr', expansion: '123 Main St' }),
      snippet({ id: 'main', trigger: 'Main', expansion: 'Main Street' }),
    ];
    const result = applySnippets(snippets, 'ship to addr', 'en');
    expect(result.text).toBe('ship to 123 Main St');
    expect(result.text).not.toContain('Street St');
  });

  it('ignores disabled snippets and language mismatches', () => {
    const snippets = [
      snippet({ id: 'off', trigger: 'alpha', expansion: 'A', isEnabled: false }),
      snippet({ id: 'de', trigger: 'beta', expansion: 'B', language: 'de' }),
    ];
    const result = applySnippets(snippets, 'alpha beta', 'en');
    expect(result.text).toBe('alpha beta');
  });

  it('keeps regex metacharacters in triggers literal', () => {
    const result = applySnippets([snippet({ trigger: 'a.b', expansion: 'X' })], 'axb and a.b', 'en');
    expect(result.text).toBe('axb and X');
  });

  it('expands every occurrence and reports the snippet once', () => {
    const result = applySnippets([snippet({ id: 's', trigger: 'brb', expansion: 'be right back' })], 'brb brb', 'en');
    expect(result.text).toBe('be right back be right back');
    expect(result.appliedSnippetIds).toEqual(['s']);
  });
});

describe('effectiveRules', () => {
  it('turns a pronunciation into a correction', () => {
    const snap = snapshot({ terms: [term({ phrase: 'Kubernetes', pronunciations: ['kubernets'] })] });
    const result = applyMemory('Scale the kubernets cluster', snap, 'en');
    expect(result.text).toBe('Scale the Kubernetes cluster');
  });

  it('turns an alias into a correction', () => {
    const snap = snapshot({ terms: [term({ phrase: 'Claude Code', aliases: ['cloud code'] })] });
    const result = applyMemory('I love cloud code.', snap, 'en');
    expect(result.text).toBe('I love Claude Code.');
  });

  /**
   * The dictionary's case-normalisation rule used to be a plain substring
   * replacement, so a short term corrupted every word containing it:
   * "said" -> "sAId", "email" -> "emAIl", "therapist" -> "therAPIst".
   */
  it('normalizes casing without rewriting substrings of longer words', () => {
    const snap = snapshot({ terms: [term({ phrase: 'AI', priority: 'always' })] });
    const result = applyMemory('I said email is available and certain', snap, 'en');
    expect(result.text).toBe('I said email is available and certain');
  });

  it('still fixes real casing', () => {
    const snap = snapshot({ terms: [term({ phrase: 'Claude Code', priority: 'always' })] });
    const result = applyMemory('open claude code please', snap, 'en');
    expect(result.text).toBe('open Claude Code please');
  });

  it('does not corrupt larger words for a short technical term', () => {
    const snap = snapshot({ terms: [term({ phrase: 'API' })] });
    const result = applyMemory('the therapist was rapid', snap, 'en');
    expect(result.text).toBe('the therapist was rapid');
  });

  it('lets an explicit user rule win over a synthetic term rule', () => {
    const snap = snapshot({
      terms: [term({ phrase: 'Claude Code', pronunciations: ['cloud code'] })],
      replacements: [{
        id: 'user-rule',
        match: 'cloud code',
        replacement: 'Claude',
        matchMode: 'wordBoundaryPhrase',
        language: 'auto',
        isEnabled: true,
        usageCount: 0,
        createdAt: '2026-01-01T00:00:00.000Z',
        updatedAt: '2026-01-01T00:00:00.000Z',
      }],
    });
    expect(applyMemory('cloud code', snap, 'en').text).toBe('Claude');
  });

  it('produces a stable rule order for a fixed snapshot', () => {
    const snap = snapshot({
      terms: [
        term({ phrase: 'Delta Force', aliases: ['DF unit'] }),
        term({ phrase: 'Bravo Squad', aliases: ['BS unit'] }),
      ],
    });
    const first = effectiveRules(snap, 'en').map((rule) => rule.match);
    const second = effectiveRules(snap, 'en').map((rule) => rule.match);
    expect(first).toEqual(second);
  });
});

describe('applyMemory', () => {
  /**
   * Rule application is not idempotent when a replacement contains its own
   * match — the normal case for this product. The second pass used to produce
   * "Karko AI AI" and "Useful Voice Voice" in delivered text.
   */
  it('does not double-apply a self-containing rule', () => {
    const snap = snapshot({ terms: [term({ phrase: 'Karko AI', aliases: ['Karko'], priority: 'always' })] });
    expect(applyMemory('Karko', snap, 'en').text).toBe('Karko AI');
  });

  it('does not double-apply a pronunciation that contains the phrase', () => {
    const snap = snapshot({ terms: [term({ phrase: 'Useful Voice', pronunciations: ['Useful'], priority: 'always' })] });
    expect(applyMemory('Useful is great', snap, 'en').text).toBe('Useful Voice is great');
  });

  it('still corrects text introduced by a snippet expansion', () => {
    const snap = snapshot({
      terms: [term({ phrase: 'Claude Code', pronunciations: ['cloud code'] })],
      snippets: [snippet({ trigger: 'my tool', expansion: 'cloud code' })],
    });
    expect(applyMemory('use my tool', snap, 'en').text).toBe('use Claude Code');
  });

  it('reports which rules and snippets fired, and which terms were hit', () => {
    const t = term({ id: 'term-kubernetes', phrase: 'Kubernetes', pronunciations: ['kubernets'] });
    const snap = snapshot({
      terms: [t],
      snippets: [snippet({ id: 'snip', trigger: 'k8s', expansion: 'Kubernetes' })],
    });
    const result = applyMemory('deploy kubernets with k8s', snap, 'en');
    expect(result.text).toBe('deploy Kubernetes with Kubernetes');
    expect(result.appliedSnippetIds).toEqual(['snip']);
    expect(result.memoryHitIds).toContain('term-kubernetes');
    expect(result.appliedRuleIds.length).toBeGreaterThan(0);
  });

  it('leaves text alone when memory is empty', () => {
    const text = 'Nothing to correct here.';
    expect(applyMemory(text, snapshot({}), 'en').text).toBe(text);
  });

  it('handles an empty transcript', () => {
    const snap = snapshot({ terms: [term({ phrase: 'AI' })] });
    expect(applyMemory('', snap, 'en').text).toBe('');
  });
});
