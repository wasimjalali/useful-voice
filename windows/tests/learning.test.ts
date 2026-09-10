import { describe, expect, it } from 'vitest';
import {
  editDistance,
  extractPairs,
  isKnown,
  isPlausibleMishearing,
} from '../src/core/memory/correctionLearner.js';
import {
  COMMON_WORDS,
  learnFromCorrection,
  requiresConfirmation,
} from '../src/core/memory/learningPolicy.js';
import { applyMemory } from '../src/core/memory/memoryPostProcessor.js';
import { emptySnapshot } from '../src/core/models.js';

let counter = 0;
const idFactory = () => {
  counter += 1;
  return `id-${counter}`;
};

describe('editDistance', () => {
  it('is zero for identical strings', () => {
    expect(editDistance('then', 'then')).toBe(0);
  });

  it('counts single substitutions and insertions', () => {
    expect(editDistance('then', 'than')).toBe(1);
    expect(editDistance('cat', 'cats')).toBe(1);
    expect(editDistance('', 'abc')).toBe(3);
  });

  it('handles an empty side', () => {
    expect(editDistance('abc', '')).toBe(3);
  });
});

describe('isPlausibleMishearing', () => {
  it('accepts a real mishearing of a technical term', () => {
    expect(isPlausibleMishearing('kubernets', 'Kubernetes')).toBe(true);
  });

  it('rejects identical words', () => {
    expect(isPlausibleMishearing('same', 'same')).toBe(false);
  });

  it('rejects short words, where the distance is meaningless', () => {
    // "cat"/"car" is a 0.33 ratio, which every threshold would accept.
    expect(isPlausibleMishearing('cat', 'car')).toBe(false);
    expect(isPlausibleMishearing('a', 'an')).toBe(false);
  });

  it('rejects two words that are merely different', () => {
    // Same length but almost no shared characters: ratio 0.875, well above the
    // 0.65 allowance.
    expect(isPlausibleMishearing('kubernets', 'githubcom')).toBe(false);
  });

  it('accepts a genuine mishearing at the edge of the allowance', () => {
    expect(isPlausibleMishearing('kubernets', 'kubernetes')).toBe(true);
  });
});

describe('extractPairs', () => {
  it('aligns words position by position', () => {
    const pairs = extractPairs('deploy the kubernets cluster', 'deploy the Kubernetes cluster');
    expect(pairs).toEqual([{ observed: 'kubernets', corrected: 'Kubernetes' }]);
  });

  it('skips words that are already correct', () => {
    const pairs = extractPairs('the cluster works', 'the cluster works');
    expect(pairs).toEqual([]);
  });

  it('skips a word that is already in the dictionary', () => {
    // The user says a real term that the dictionary knows: nothing to learn.
    const pairs = extractPairs('send it to Karko', 'send it to Karko AI', ['Karko']);
    expect(pairs).toEqual([]);
  });

  it('does not attempt alignment when the shapes are very different', () => {
    const pairs = extractPairs('one two three four five six', 'completely rewritten');
    expect(pairs).toEqual([]);
  });

  it('returns nothing for empty input', () => {
    expect(extractPairs('', 'something')).toEqual([]);
    expect(extractPairs('something', '')).toEqual([]);
  });

  it('de-duplicates repeated pairs', () => {
    const pairs = extractPairs('kubernets and kubernets', 'Kubernetes and Kubernetes');
    expect(pairs).toHaveLength(1);
  });
});

describe('isKnown', () => {
  it('matches through plural tolerance and casing', () => {
    expect(isKnown('terms', ['Term'])).toBe(true);
    expect(isKnown('Kubernetes', ['kubernetes'])).toBe(true);
    expect(isKnown('nothing', ['something'])).toBe(false);
  });
});

describe('requiresConfirmation', () => {
  /**
   * The dangerous class: one edit between two ordinary words becoming a global
   * rule. "then" -> "than" scores 0.25 on the edit-distance gate, so it passed
   * every automatic check and then rewrote every future "then".
   */
  it('flags common-word swaps', () => {
    expect(requiresConfirmation('then', 'than')).toBe(true);
    expect(requiresConfirmation('there', 'three')).toBe(true);
    expect(requiresConfirmation('form', 'from')).toBe(true);
    expect(requiresConfirmation('quite', 'quiet')).toBe(true);
  });

  it('does not flag a term-to-name fix', () => {
    // Only one side is common, and this is a real correction.
    expect(requiresConfirmation('agent', 'Agent Smith')).toBe(false);
    expect(requiresConfirmation('kubernets', 'Kubernetes')).toBe(false);
  });

  it('does not flag identical input', () => {
    expect(requiresConfirmation('then', 'then')).toBe(false);
  });

  it('does not flag empty input', () => {
    expect(requiresConfirmation('', 'than')).toBe(false);
  });

  it('includes German function words', () => {
    expect(COMMON_WORDS.has('für')).toBe(true);
    expect(COMMON_WORDS.has('und')).toBe(true);
  });
});

describe('learnFromCorrection', () => {
  it('teaches a short phrase explicitly', () => {
    const result = learnFromCorrection({
      observed: 'cloud code',
      corrected: 'Claude Code',
      idFactory,
    });
    expect(result.confirmedPairs).toHaveLength(1);
    expect(result.suggestedPairs).toHaveLength(0);
    const kinds = result.entries.map((entry) => entry.kind);
    expect(kinds).toContain('replacement');
    expect(kinds).toContain('term');
  });

  it('keeps the learned rule word-bounded so short forms cannot corrupt words', () => {
    const result = learnFromCorrection({ observed: 'cloud code', corrected: 'Claude Code', idFactory });
    const rule = result.entries.find((entry) => entry.kind === 'replacement');
    expect(rule).toBeDefined();
    if (rule?.kind === 'replacement') {
      // A substring mode here would rewrite "cloud codes" and any word containing
      // the observed phrase.
      expect(rule.rule.matchMode).toBe('wordBoundaryPhrase');
    }
  });

  it('treats a case-only fix as spelling knowledge, not a substitution', () => {
    // "ai" and "AI" are the same word, so there is nothing to substitute. Teaching
    // this as a rule would create a rule whose match and replacement are equal.
    const result = learnFromCorrection({ observed: 'ai', corrected: 'AI', idFactory });
    expect(result.entries).toHaveLength(1);
    expect(result.entries[0]?.kind).toBe('term');
  });

  it('teaches casing without inventing a substitution', () => {
    const result = learnFromCorrection({ observed: 'claude code', corrected: 'Claude Code', idFactory });
    // Same canonical form: only the term is taught, no rule needed.
    expect(result.entries).toHaveLength(1);
    expect(result.entries[0]?.kind).toBe('term');
  });

  it('returns nothing for empty or identical input', () => {
    expect(learnFromCorrection({ observed: '', corrected: 'x', idFactory }).entries).toEqual([]);
    expect(learnFromCorrection({ observed: 'x', corrected: '', idFactory }).entries).toEqual([]);
    expect(learnFromCorrection({ observed: 'same', corrected: 'same', idFactory }).entries).toEqual([]);
  });

  /**
   * One edit used to create up to four persistent artefacts, including a term
   * whose pronunciation generated yet another correction rule. One action should
   * produce one visible rule.
   */
  it('does not attach a pronunciation to an inferred word-level pair', () => {
    const longObserved = 'please deploy the kubernets cluster to staging now for the team';
    const longCorrected = 'please deploy the Kubernetes cluster to staging now for the team';
    const result = learnFromCorrection({
      observed: longObserved,
      corrected: longCorrected,
      idFactory,
    });
    const term = result.entries.find((entry) => entry.kind === 'term');
    if (term && term.kind === 'term') {
      expect(term.term.pronunciations).toEqual([]);
    }
  });

  it('proposes word-level pairs from a longer edit instead of applying them', () => {
    const result = learnFromCorrection({
      observed: 'please deploy the kubernets cluster to staging now',
      corrected: 'please deploy the Kubernetes cluster to staging now',
      idFactory,
    });
    expect(result.suggestedPairs.length).toBeGreaterThan(0);
    expect(result.suggestedPairs[0]?.observed).toBe('kubernets');
    // No global rule was written for the inferred pair.
    expect(result.entries.some((entry) => entry.kind === 'replacement')).toBe(false);
  });

  it('explains why a common-word suggestion needs confirmation', () => {
    const result = learnFromCorrection({
      observed: 'i went there first and it worked',
      corrected: 'i went three first and it worked',
      idFactory,
    });
    // "there"/"three" both common, but also only a single-word change in a longer
    // phrase, so it surfaces as a suggestion with a reason.
    for (const suggestion of result.suggestedPairs) {
      expect(suggestion.reason.length).toBeGreaterThan(0);
    }
  });

  it('generates unique ids for every entry', () => {
    const result = learnFromCorrection({ observed: 'cloud code', corrected: 'Claude Code', idFactory });
    const ids = result.entries.map((entry) => entry.kind === 'term' ? entry.term.id : entry.rule.id);
    expect(new Set(ids).size).toBe(ids.length);
  });
});

describe('learning end to end', () => {
  it('a confirmed correction actually fixes the next dictation', () => {
    const result = learnFromCorrection({
      observed: 'kubernets',
      corrected: 'Kubernetes',
      idFactory,
    });
    const snapshot = emptySnapshot();
    for (const entry of result.entries) {
      if (entry.kind === 'term') snapshot.terms.push(entry.term);
      if (entry.kind === 'replacement') snapshot.replacements.push(entry.rule);
    }
    expect(applyMemory('scale the kubernets cluster', snapshot, 'en').text)
      .toBe('scale the Kubernetes cluster');
  });

  it('a learned dictionary term does not corrupt words that contain it', () => {
    // The whole point of the word-boundary fix: a dictionary term "AI" is also a
    // substring of "said" and "email".
    const snapshot = emptySnapshot();
    snapshot.terms.push(termStub('AI'));
    expect(applyMemory('I said email', snapshot, 'en').text).toBe('I said email');
  });

  it('a learned rule does not fire inside a larger word', () => {
    const snapshot = emptySnapshot();
    snapshot.replacements.push({
      id: 'r',
      match: 'cloud code',
      replacement: 'Claude Code',
      matchMode: 'wordBoundaryPhrase',
      language: 'auto',
      isEnabled: true,
      usageCount: 0,
      createdAt: '2026-01-01T00:00:00.000Z',
      updatedAt: '2026-01-01T00:00:00.000Z',
    });
    expect(applyMemory('cloud codes are fine', snapshot, 'en').text).toBe('cloud codes are fine');
    expect(applyMemory('use cloud code', snapshot, 'en').text).toBe('use Claude Code');
  });
});

function termStub(phrase: string) {
  return {
    id: `stub-${phrase}`,
    phrase,
    aliases: [] as string[],
    pronunciations: [] as string[],
    language: 'auto' as const,
    priority: 'always' as const,
    notes: '',
    usageCount: 0,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
  };
}
