import type {
  LanguageMemorySnapshot,
  MemoryLanguage,
  MemoryTerm,
  ReplacementRule,
} from '../models.js';
import { canonical, containsWordBoundaryPhrase, languageMatches } from '../dictionary/termMatcher.js';

/**
 * Build the effective local correction rules that run after transcription.
 *
 * Combines, in priority order:
 *
 * 1. Explicit user auto-corrections (replacements).
 * 2. Synthetic rules from dictionary term aliases and pronunciations
 *    ("sounds like X" -> the exact dictionary spelling).
 * 3. Case-normalisation of known dictionary phrases, so "claude code" becomes
 *    "Claude Code" once the term is saved.
 *
 * Explicit rules are appended first because the de-duplication key means the
 * first rule for a given heard phrase claims it, and a user-written rule must
 * win over one derived from a term.
 */
export function effectiveRules(
  snapshot: LanguageMemorySnapshot,
  language: MemoryLanguage,
): ReplacementRule[] {
  const rules: ReplacementRule[] = [];
  const seen = new Set<string>();

  const append = (rule: ReplacementRule): void => {
    if (!rule.isEnabled) return;
    if (!languageMatches(rule.language, language)) return;
    const match = rule.match.trim();
    const replacement = rule.replacement.trim();
    if (match.length === 0 || replacement.length === 0) return;

    const key = `${rule.matchMode}|${canonical(match)}`;
    if (seen.has(key)) return;
    seen.add(key);
    rules.push({ ...rule, match, replacement, isEnabled: true });
  };

  for (const rule of snapshot.replacements) append(rule);

  for (const term of snapshot.terms) {
    if (!languageMatches(term.language, language)) continue;
    const phrase = term.phrase.trim();
    if (phrase.length === 0) continue;

    for (const hint of [...term.aliases, ...term.pronunciations]) {
      const heard = hint.trim();
      // Everything that differs from the phrase becomes a local fix, so
      // "sounds like" entries and alternate spellings survive STT.
      if (heard.length === 0 || heard === phrase) continue;
      append({
        id: syntheticRuleId('alias', term.id, heard),
        match: heard,
        replacement: phrase,
        matchMode: 'wordBoundaryPhrase',
        language: term.language,
        isEnabled: true,
        usageCount: 0,
        createdAt: term.createdAt,
        updatedAt: term.updatedAt,
      });
    }

    // Case-normalise the phrase itself.
    //
    // MUST be word-boundary matched rather than a plain substring replace. A
    // short term like "AI", "PR" or "API" occurs inside unrelated words, and a
    // substring substitution corrupts them: "said" becomes "sAId", "email"
    // becomes "emAIl", "therapist" becomes "therAPIst". Word-boundary matching is
    // already case-insensitive, so the intended fix ("claude code" ->
    // "Claude Code") still works while substrings of longer words are left alone.
    append({
      id: syntheticRuleId('case', term.id, phrase),
      match: phrase,
      replacement: phrase,
      matchMode: 'wordBoundaryPhrase',
      language: term.language,
      isEnabled: true,
      usageCount: 0,
      createdAt: term.createdAt,
      updatedAt: term.updatedAt,
    });
  }

  return rules;
}

/**
 * Synthetic rules need stable ids so a rule that fires can be attributed back to
 * a term in history without persisting a rule record for every term.
 */
export function syntheticRuleId(kind: 'alias' | 'case', termId: string, phrase: string): string {
  return `${kind}:${termId}:${canonical(phrase)}`;
}

/** Which term a synthetic rule id refers to, for history attribution. */
export function termIdFromSyntheticRule(ruleId: string): string | null {
  const parts = ruleId.split(':');
  if (parts.length < 3) return null;
  const kind = parts[0];
  if (kind !== 'alias' && kind !== 'case') return null;
  return parts[1] ?? null;
}

/** Dictionary terms whose phrase appears in one of the given texts. */
export function matchingTermIds(
  terms: readonly MemoryTerm[],
  texts: readonly string[],
  language: MemoryLanguage,
): string[] {
  const hits: string[] = [];
  for (const term of terms) {
    if (!languageMatches(term.language, language)) continue;
    const candidates = [term.phrase, ...term.aliases, ...term.pronunciations];
    const found = candidates.some((candidate) =>
      texts.some((text) => containsWordBoundaryPhrase(candidate, text)));
    if (found && !hits.includes(term.id)) hits.push(term.id);
  }
  return hits;
}
