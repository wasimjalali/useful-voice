import type {
  LanguageMemorySnapshot,
  MemoryLanguage,
  MemoryPriority,
  MemorySnippet,
  MemoryTerm,
  ReplacementRule,
} from '../models.js';
import { priorityRank } from '../models.js';
import { canonical, languageMatches } from '../dictionary/termMatcher.js';
import { TOKEN_BUDGET, estimateTokens, isSendableKeyterm } from '../transcription/keytermBudget.js';

/**
 * Shipped vocabulary of terms speech models commonly mis-hear.
 *
 * These are keyterms only — they never become replacement rules — so they cannot
 * auto-correct the user's text; they only bias recognition.
 *
 * Generic common words (agent, token, repo, PR, prompt) are deliberately absent.
 * Deepgram's own guidance is to avoid generic words that are rarely misrecognized,
 * and each one would consume a slot in the token budget that a user's own term
 * should have. A third-party product name has also been removed: it shipped to
 * every user, spent budget, and biased recognition toward a brand the user never
 * said.
 */
export const BASE_VOCABULARY: readonly string[] = [
  'Next.js',
  'Vercel',
  'Stripe',
  'Bedrock',
  'Tailwind',
  'TypeScript',
  'JavaScript',
  'SwiftUI',
  'Xcode',
  'GitHub',
  'GitLab',
  'Supabase',
  'Postgres',
  'PostgreSQL',
  'Kubernetes',
  'Docker',
  'Terraform',
  'GraphQL',
  'WebSocket',
  'OAuth',
  'JSON',
  'YAML',
  'CLI',
  'SDK',
  'API',
  'localhost',
  'npm',
  'pnpm',
  'Vite',
  'Vitest',
];

export interface KeytermSelection {
  terms: string[];
  estimatedTokens: number;
  /**
   * Valid entries left out because they did not fit the count or token budget.
   * Only this is something the user can act on.
   */
  droppedCount: number;
  /** Entries the provider cannot use at all (too long, no alphanumerics). */
  rejectedCount: number;
  /** Entries skipped because an equivalent term was already selected. */
  duplicateCount: number;
  limit: number;
}

/** Everything that did not make it into the request. */
export function omittedCount(selection: KeytermSelection): number {
  return selection.droppedCount + selection.rejectedCount;
}

export function isOverCapacity(selection: KeytermSelection): boolean {
  return selection.droppedCount > 0;
}

export interface BiasInput {
  terms: readonly MemoryTerm[];
  replacements?: readonly ReplacementRule[];
  snippets?: readonly MemorySnippet[];
  baseVocabulary?: readonly string[];
  language: MemoryLanguage;
  /** Maximum number of keyterm strings, in addition to the token ceiling. */
  budget: number;
}

/**
 * Choose the keyterms for one transcription request.
 *
 * Only CORRECT forms are ever sent. Pronunciations are misheard forms, and a
 * keyterm biases the model toward that exact string, so sending one would make
 * the mistake it was recorded to fix more likely. Aliases are alternate correct
 * spellings and are safe.
 *
 * Admission requires fitting both the count budget and the token ceiling, and a
 * term that does not fit is dropped rather than truncated: half a term as a
 * keyterm would bias the model toward a wrong string.
 */
export function selectKeyterms(input: BiasInput): KeytermSelection {
  const { language, budget } = input;
  const baseVocabulary = input.baseVocabulary ?? BASE_VOCABULARY;

  if (budget <= 0) {
    return {
      terms: [],
      estimatedTokens: 0,
      droppedCount: 0,
      rejectedCount: 0,
      duplicateCount: 0,
      limit: TOKEN_BUDGET,
    };
  }

  const sortedTerms = [...input.terms]
    .filter((term) => languageMatches(term.language, language))
    .sort(compareTerms);

  const seen = new Set<string>();
  const terms: string[] = [];
  let spentTokens = 0;
  let droppedCount = 0;
  let rejectedCount = 0;
  let duplicateCount = 0;

  const append = (value: string): void => {
    const trimmed = value.trim();
    if (!isSendableKeyterm(trimmed)) {
      rejectedCount += 1;
      return;
    }
    const key = canonical(trimmed);
    if (key.length === 0) {
      rejectedCount += 1;
      return;
    }
    if (seen.has(key)) {
      duplicateCount += 1;
      return;
    }
    if (terms.length >= budget) {
      droppedCount += 1;
      return;
    }
    const cost = estimateTokens(trimmed);
    if (spentTokens + cost > TOKEN_BUDGET) {
      droppedCount += 1;
      return;
    }
    seen.add(key);
    terms.push(trimmed);
    spentTokens += cost;
  };

  // 1. Personal dictionary phrases, then their alternate correct spellings.
  for (const term of sortedTerms) {
    append(term.phrase);
    for (const alias of term.aliases) append(alias);
  }

  // 2. Auto-correction targets: what the model should produce.
  const sortedReplacements = [...(input.replacements ?? [])]
    .filter((rule) => rule.isEnabled && languageMatches(rule.language, language))
    .sort((a, b) => b.usageCount - a.usageCount);
  for (const rule of sortedReplacements) append(rule.replacement);

  // 3. Snippet triggers, so spoken shortcuts survive transcription.
  for (const snippet of input.snippets ?? []) {
    if (!snippet.isEnabled || !languageMatches(snippet.language, language)) continue;
    append(snippet.trigger);
  }

  // 4. Shipped vocabulary fills whatever budget is left.
  for (const word of baseVocabulary) append(word);

  return {
    terms,
    estimatedTokens: spentTokens,
    droppedCount,
    rejectedCount,
    duplicateCount,
    limit: TOKEN_BUDGET,
  };
}

/** Ranking within the same priority: most used first, then most recently edited. */
function compareTerms(a: MemoryTerm, b: MemoryTerm): number {
  const rankDelta = priorityRank(a.priority) - priorityRank(b.priority);
  if (rankDelta !== 0) return rankDelta;
  if (a.usageCount !== b.usageCount) return b.usageCount - a.usageCount;
  const updated = b.updatedAt.localeCompare(a.updatedAt);
  if (updated !== 0) return updated;
  // Total order: without this the result depends on the input array's order,
  // which made the keyterm list (and therefore transcripts) non-reproducible.
  return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

/** Convenience: the plain keyterm list for a snapshot. */
export function biasList(snapshot: LanguageMemorySnapshot, language: MemoryLanguage, budget: number): string[] {
  return selectKeyterms({
    terms: snapshot.terms,
    replacements: snapshot.replacements,
    snippets: snapshot.snippets,
    language,
    budget,
  }).terms;
}

export type { MemoryPriority };
