import type { MemoryLanguage, MemorySnippet } from '../models.js';
import { escapeRegExp, languageMatches } from '../dictionary/termMatcher.js';

export interface SnippetOutcome {
  text: string;
  appliedSnippetIds: string[];
}

interface CompiledSnippet {
  snippet: MemorySnippet;
  trigger: string;
  expansion: string;
}

/**
 * Expand spoken shortcuts ("my sig" -> a full sign-off).
 *
 * Two ordering rules, both of which were broken in the macOS implementation and
 * produced visibly wrong output:
 *
 * 1. Triggers are matched longest first. In store order (newest first) a shorter
 *    trigger shadows a longer one that contains it, so `sig` inside "my sig"
 *    expanded first and the snippet the user actually meant never fired.
 * 2. Each snippet scans the ORIGINAL text position by position in a single pass,
 *    not the output of the previous snippet. Re-scanning allowed chained
 *    expansion: with `addr -> 123 Main St` and `Main -> Main Street`, the first
 *    expansion's output was re-expanded into "123 Main Street St".
 */
export function applySnippets(
  snippets: readonly MemorySnippet[],
  text: string,
  language: MemoryLanguage,
): SnippetOutcome {
  const enabled: CompiledSnippet[] = [];
  for (const snippet of snippets) {
    if (!snippet.isEnabled) continue;
    if (!languageMatches(snippet.language, language)) continue;
    const trigger = snippet.trigger.trim();
    const expansion = snippet.expansion.trim();
    if (trigger.length === 0 || expansion.length === 0) continue;
    enabled.push({ snippet, trigger, expansion });
  }
  if (enabled.length === 0 || text.length === 0) {
    return { text, appliedSnippetIds: [] };
  }

  enabled.sort((a, b) => {
    if (a.trigger.length !== b.trigger.length) return b.trigger.length - a.trigger.length;
    return a.snippet.id < b.snippet.id ? -1 : a.snippet.id > b.snippet.id ? 1 : 0;
  });

  // One combined pattern, so a match is found at each position and the LONGEST
  // trigger at that position wins. Single pass means no chained expansion.
  const alternatives = enabled.map((entry) => escapeRegExp(entry.trigger)).join('|');
  let combined: RegExp;
  try {
    combined = new RegExp(`(?<![\\p{L}\\p{N}_])(?:${alternatives})(?![\\p{L}\\p{N}_])`, 'giu');
  } catch {
    return { text, appliedSnippetIds: [] };
  }

  const byCanonicalTrigger = new Map<string, CompiledSnippet>();
  for (const entry of enabled) {
    // Case-insensitive lookup: the pattern matches case-insensitively.
    byCanonicalTrigger.set(entry.trigger.toLowerCase(), entry);
  }

  const appliedSnippetIds: string[] = [];
  const output = text.replace(combined, (match) => {
    const entry = byCanonicalTrigger.get(match.toLowerCase());
    if (!entry) return match;
    if (!appliedSnippetIds.includes(entry.snippet.id)) {
      appliedSnippetIds.push(entry.snippet.id);
    }
    return entry.expansion;
  });

  return { text: output, appliedSnippetIds };
}
