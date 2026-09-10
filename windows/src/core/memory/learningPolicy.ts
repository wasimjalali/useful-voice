import type { MemoryLanguage, MemoryTerm, ReplacementRule } from '../models.js';
import { canonical, matches } from '../dictionary/termMatcher.js';
import { extractPairs, isPlausibleMishearing } from './correctionLearner.js';

export type LearningEntry =
  | { kind: 'term'; term: MemoryTerm }
  | { kind: 'replacement'; rule: ReplacementRule };

export interface LearnResult {
  entries: LearningEntry[];
  /** Pairs the user typed deliberately. */
  confirmedPairs: Array<{ observed: string; corrected: string }>;
  /**
   * Word-level pairs inferred from a longer edit. Each needs the user's
   * confirmation before it becomes a global rule.
   */
  suggestedPairs: Array<{ observed: string; corrected: string; reason: string }>;
}

/**
 * Words that are ordinary parts of speech rather than names or jargon.
 *
 * Auto-learning a substitution between two of these is almost always wrong: the
 * user fixed a one-off slip while editing, and the learned rule then rewrites
 * that word in *every* future dictation. The edit-distance gate cannot tell a
 * mishearing from an intentional textual edit between short common words —
 * "then"/"than" scores 0.25, "there"/"three" 0.4, "form"/"from" 0.5, all well
 * inside the allowance — so one fix used to make the app say "and than I went"
 * forever after. Pairs drawn from this list are learned only on confirmation.
 */
export const COMMON_WORDS: ReadonlySet<string> = new Set([
  // English function words and easily confused neighbours.
  'a', 'an', 'and', 'are', 'as', 'at', 'be', 'been', 'but', 'by', 'can',
  'could', 'did', 'do', 'does', 'for', 'form', 'from', 'had', 'has', 'have',
  'he', 'her', 'here', 'hers', 'him', 'his', 'how', 'i', 'if', 'in', 'into',
  'is', 'it', 'its', 'just', 'know', 'like', 'me', 'more', 'most', 'much',
  'my', 'no', 'not', 'now', 'of', 'off', 'on', 'one', 'only', 'or', 'other',
  'our', 'out', 'over', 'own', 'quiet', 'quite', 'said', 'same', 'say', 'she',
  'should', 'so', 'some', 'such', 'than', 'that', 'the', 'their', 'them',
  'then', 'there', 'these', 'they', 'this', 'those', 'though', 'thought',
  'three', 'through', 'to', 'too', 'trial', 'trail', 'two', 'up', 'us',
  'very', 'was', 'we', 'were', 'what', 'when', 'where', 'which', 'while',
  'who', 'why', 'will', 'with', 'would', 'you', 'your',
  // German function words, for the same reason.
  'aber', 'als', 'auch', 'auf', 'aus', 'bei', 'bin', 'bis', 'bist', 'das',
  'dass', 'dem', 'den', 'der', 'des', 'die', 'dies', 'doch', 'ein', 'eine',
  'einem', 'einen', 'einer', 'eines', 'er', 'es', 'für', 'hat', 'habe',
  'haben', 'ich', 'ihr', 'ihre', 'im', 'in', 'ist', 'ja', 'kann', 'mit',
  'nach', 'nicht', 'noch', 'nur', 'oder', 'schon', 'sein', 'sie', 'sind',
  'so', 'über', 'und', 'uns', 'von', 'vor', 'war', 'waren', 'was', 'wenn',
  'wer', 'wie', 'wir', 'wo', 'zu', 'zum', 'zur',
]);

/**
 * Whether a pair is a swap between two ordinary words, which must be confirmed
 * before it can rewrite anything globally.
 *
 * Only a swap where BOTH sides are common is risky: "agent" -> "Agent Smith"
 * touches a common word but is a real name fix.
 */
export function requiresConfirmation(observed: string, corrected: string): boolean {
  const left = canonical(observed);
  const right = canonical(corrected);
  if (left.length === 0 || right.length === 0 || left === right) return false;
  return COMMON_WORDS.has(left) && COMMON_WORDS.has(right);
}

export interface LearnOptions {
  observed: string;
  corrected: string;
  language?: MemoryLanguage;
  existingDictionary?: readonly string[];
  now?: Date;
  idFactory?: () => string;
}

/**
 * Build the dictionary updates for one observed -> corrected pair.
 *
 * Two kinds of output, deliberately separated:
 *
 * - The phrase the user actually entered is taught outright. That is explicit
 *   teaching, and it is what the "Fix a mistake" field is for.
 * - Word-level substitutions extracted from a longer edit are INFERENCES. They
 *   are returned as suggestions rather than applied, because one edit used to
 *   create up to four persistent artefacts — a whole-phrase rule, a whole-phrase
 *   term, a word rule, and a word term whose pronunciation generated yet another
 *   correction rule through the dictionary corrector. One action should create
 *   one rule the user can see and undo.
 */
export function learnFromCorrection(options: LearnOptions): LearnResult {
  const {
    language = 'auto',
    existingDictionary = [],
    now = new Date(),
    idFactory = defaultIdFactory,
  } = options;

  const observed = options.observed.trim();
  const corrected = options.corrected.trim();
  if (observed.length === 0 || corrected.length === 0 || observed === corrected) {
    return { entries: [], confirmedPairs: [], suggestedPairs: [] };
  }

  const timestamp = now.toISOString();
  const entries: LearningEntry[] = [];

  // Case-only (or punctuation-only) difference: the user is telling us how to
  // spell it, so teach the term and its casing, not a substitution.
  if (canonical(observed) === canonical(corrected)) {
    entries.push({
      kind: 'term',
      term: buildTerm(corrected, [], language, timestamp, idFactory),
    });
    return { entries, confirmedPairs: [], suggestedPairs: [] };
  }

  const words = (value: string) => value.split(/\s+/).filter(Boolean).length;
  const isShortPhrase = words(observed) <= 6 && words(corrected) <= 6;

  if (isShortPhrase) {
    entries.push({
      kind: 'replacement',
      rule: buildRule(observed, corrected, language, timestamp, idFactory),
    });
    entries.push({
      kind: 'term',
      term: buildTerm(
        corrected,
        // The user typed the correction themselves, so the observed form IS the
        // pronunciation they want recognised.
        matches(observed, corrected) ? [] : [observed],
        language,
        timestamp,
        idFactory,
      ),
    });
    return {
      entries,
      confirmedPairs: [{ observed, corrected }],
      suggestedPairs: [],
    };
  }

  // Longer edit: extract word-level candidates and hand them back as
  // suggestions instead of writing global rules the user never asked for.
  const candidates = extractPairs(observed, corrected, existingDictionary);
  const suggestedPairs = candidates.map((pair) => ({
    observed: pair.observed,
    corrected: pair.corrected,
    reason: requiresConfirmation(pair.observed, pair.corrected)
      ? 'Both words are common words, so this could be a one-off edit rather than a mishearing.'
      : 'Inferred from a longer correction. Confirm before it applies to every dictation.',
  }));

  // Still teach the corrected phrase as a term so recognition improves, but do
  // not create a long phrase substitution rule: it would almost never match.
  entries.push({
    kind: 'term',
    term: buildTerm(corrected, [], language, timestamp, idFactory),
  });

  return { entries, confirmedPairs: [], suggestedPairs };
}

function buildTerm(
  phrase: string,
  pronunciations: string[],
  language: MemoryLanguage,
  timestamp: string,
  idFactory: () => string,
): MemoryTerm {
  return {
    id: idFactory(),
    phrase,
    aliases: [],
    pronunciations,
    language,
    priority: 'high',
    notes: 'Learned from a correction',
    usageCount: 0,
    createdAt: timestamp,
    updatedAt: timestamp,
  };
}

function buildRule(
  observed: string,
  corrected: string,
  language: MemoryLanguage,
  timestamp: string,
  idFactory: () => string,
): ReplacementRule {
  return {
    id: idFactory(),
    match: observed,
    replacement: corrected,
    // Word boundaries, never a substring replace: a short observed form inside a
    // longer word must not be rewritten.
    matchMode: 'wordBoundaryPhrase',
    language,
    isEnabled: true,
    usageCount: 0,
    createdAt: timestamp,
    updatedAt: timestamp,
  };
}

function defaultIdFactory(): string {
  return globalThis.crypto.randomUUID();
}

export { isPlausibleMishearing };
