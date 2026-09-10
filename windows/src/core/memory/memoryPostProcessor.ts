import type {
  LanguageMemorySnapshot,
  MemoryLanguage,
  MemoryProcessingResult,
} from '../models.js';
import { effectiveRules, matchingTermIds } from './dictionaryCorrector.js';
import { RuleSet } from './replacementEngine.js';
import { applySnippets } from './snippetExpansionEngine.js';

/**
 * The deterministic memory pass that runs on every dictation.
 *
 * Order: replacements, then snippet expansion, then replacements again. The
 * second pass exists because a snippet's expansion can contain text that needs
 * correcting (a snippet expanding to a brand name spelled wrong).
 *
 * The second pass MUST NOT re-apply rules that already fired. Rule application is
 * not idempotent when a rule's replacement still contains its own match, which is
 * the normal case for this product ("Karko" -> "Karko AI", "Useful" ->
 * "Useful Voice"). Re-applying produced "Karko AI AI" and
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
