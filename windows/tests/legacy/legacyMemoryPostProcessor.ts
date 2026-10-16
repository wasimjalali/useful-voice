// The Language Memory pass exactly as it was before the index (main at bb754d9), kept as the
// oracle for languageMemoryIndex.test.ts. Only import paths changed, plus `matchingTermIds`
// copied from dictionaryCorrector.ts. Do not improve it: its value is that it is the old behaviour.
import type {
  LanguageMemorySnapshot,
  MemoryTerm,
  MemoryLanguage,
  MemoryProcessingResult,
} from '../../src/core/models.js';
import { effectiveRules } from '../../src/core/memory/dictionaryCorrector.js';
import { containsWordBoundaryPhrase, languageMatches } from '../../src/core/dictionary/termMatcher.js';
import { RuleSet } from './legacyReplacementEngine.js';
import { applySnippets } from '../../src/core/memory/snippetExpansionEngine.js';

/**
 * The deterministic memory pass that runs on every dictation.
 *
 * Order: replacements, then snippet expansion, then replacements again. The
 * second pass exists because a snippet's expansion can contain text that needs
 * correcting (a snippet expanding to a brand name spelled wrong).
 *
 * The second pass MUST NOT re-apply rules that already fired. Rule application is
 * not idempotent when a rule's replacement still contains its own match, which is
 * the normal case for this product ("Acme" -> "Acme Inc", "Useful" ->
 * "Useful Voice"). Re-applying produced "Acme Inc Inc" and
 * "Useful Voice Voice" in the delivered text. Since a rule matches a fixed
 * literal phrase, re-applying it to text it already produced can only duplicate.
 */
export function applyMemory(
  text: string,
  snapshot: LanguageMemorySnapshot,
  language: MemoryLanguage,
): MemoryProcessingResult {
  const rules = effectiveRules(snapshot, language);
  const ruleSet = new RuleSet(rules, language);

  const firstPass = ruleSet.apply(text);
  const snippet = applySnippets(snapshot.snippets, firstPass.text, language);

  // Exclude everything that already changed something. A rule whose match is
  // absent from the pass-one output (because something else rewrote it) is NOT
  // excluded and still gets a chance here, which is the behaviour the second
  // pass was added for.
  const alreadyApplied = new Set(firstPass.appliedRuleIds);
  const secondPass = rules.filter((rule) => !alreadyApplied.has(rule.id));
  const finalPass = new RuleSet(secondPass, language).apply(snippet.text);

  const memoryHitIds = matchingTermIds(
    snapshot.terms,
    [text, firstPass.text, snippet.text, finalPass.text],
    language,
  );

  return {
    text: finalPass.text,
    appliedRuleIds: unique([...firstPass.appliedRuleIds, ...finalPass.appliedRuleIds]),
    appliedSnippetIds: snippet.appliedSnippetIds,
    memoryHitIds,
  };
}

function unique(values: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const value of values) {
    if (seen.has(value)) continue;
    seen.add(value);
    out.push(value);
  }
  return out;
}

/** Dictionary terms whose phrase appears in one of the given texts (the old implementation). */
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
