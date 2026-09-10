/**
 * Core domain models for Useful Voice.
 *
 * This directory is deliberately free of any Electron, Node or DOM import. It is
 * the part of the app that must behave identically on every platform, so it is
 * pure TypeScript and fully covered by unit tests that run anywhere.
 */

/** BCP-47-ish language selection plus `auto` for provider-side detection. */
export type MemoryLanguage = 'auto' | 'en' | 'de' | 'es' | 'fr' | 'it' | 'pt' | 'nl' | 'ja' | 'zh';

export const MEMORY_LANGUAGES: readonly MemoryLanguage[] = [
  'auto', 'en', 'de', 'es', 'fr', 'it', 'pt', 'nl', 'ja', 'zh',
];

/**
 * How strongly a term should bias transcription.
 *
 * `always` is reserved for terms the user explicitly promoted; it sorts first
 * when the keyterm list has to be trimmed to fit the provider's token ceiling.
 */
export type MemoryPriority = 'always' | 'high' | 'normal';

const PRIORITY_RANK: Record<MemoryPriority, number> = {
  always: 0,
  high: 1,
  normal: 2,
};

export function priorityRank(priority: MemoryPriority): number {
  return PRIORITY_RANK[priority] ?? PRIORITY_RANK.normal;
}

export interface MemoryTerm {
  id: string;
  /** The correct, canonical spelling. This is what lands in the transcript. */
  phrase: string;
  /** Alternate correct spellings (e.g. "GPT-4" and "GPT4"). */
  aliases: string[];
  /**
   * Misheard forms. These drive local correction and are NEVER sent to the
   * provider as keyterms: a keyterm biases the model *toward* that string, so
   * sending a mishearing would make the mistake more likely.
   */
  pronunciations: string[];
  language: MemoryLanguage;
  priority: MemoryPriority;
  notes: string;
  usageCount: number;
  createdAt: string;
  updatedAt: string;
}

export type MatchMode = 'caseInsensitivePhrase' | 'wordBoundaryPhrase' | 'exact';

export interface ReplacementRule {
  id: string;
  /** What was heard (or typed wrong). */
  match: string;
  /** What it must become. */
  replacement: string;
  matchMode: MatchMode;
  language: MemoryLanguage;
  isEnabled: boolean;
  usageCount: number;
  createdAt: string;
  updatedAt: string;
}

export interface MemorySnippet {
  id: string;
  /** Short spoken trigger, e.g. "my sig". */
  trigger: string;
  /** Full text it expands to. */
  expansion: string;
  language: MemoryLanguage;
  isEnabled: boolean;
  usageCount: number;
  createdAt: string;
  updatedAt: string;
}

export interface MemorySuggestion {
  id: string;
  observed: string;
  corrected: string;
  /** How many times this pair has been seen. Drives the confirmation gate. */
  evidenceCount: number;
  createdAt: string;
}

export interface LanguageMemorySnapshot {
  terms: MemoryTerm[];
  replacements: ReplacementRule[];
  snippets: MemorySnippet[];
  suggestions: MemorySuggestion[];
}

export function emptySnapshot(): LanguageMemorySnapshot {
  return { terms: [], replacements: [], snippets: [], suggestions: [] };
}

/** Result of running the deterministic memory pass over a transcript. */
export interface MemoryProcessingResult {
  text: string;
  appliedRuleIds: string[];
  appliedSnippetIds: string[];
  memoryHitIds: string[];
}

export interface DictationRecord {
  id: string;
  text: string;
  /** Transcript before formatting/memory, kept for the "reprocess" feature. */
  rawText: string;
  /** Text after memory but before the optional formatter. */
  intermediateText: string;
  language: MemoryLanguage;
  appName: string;
  durationSeconds: number;
  mode: 'raw' | 'formatted';
  createdAt: string;
  audioPath?: string;
  replacementRuleIds: string[];
  memoryHitIds: string[];
  snippetIds: string[];
}

export interface Note {
  id: string;
  title: string;
  body: string;
  createdAt: string;
  updatedAt: string;
}

export interface AppSettings {
  languagePin: MemoryLanguage;
  formattingEnabled: boolean;
  /**
   * Convert spoken punctuation commands ("period", "new line") into the
   * characters themselves, via Deepgram's Dictation feature.
   *
   * Off by default: it changes what the words mean rather than how they are
   * formatted, so it should be asked for. English only.
   */
  spokenPunctuationEnabled: boolean;
  silenceTimeoutSeconds: number;
  maxRecordingSeconds: number;
  recordingsToKeep: number;
  soundEffectsEnabled: boolean;
  launchAtLogin: boolean;
  hotkey: HotkeyBinding;
  /** Terms sent as keyterms on top of the dictionary, capped by KeytermBudget. */
  dictionaryBiasBudget: number;
}

export interface HotkeyBinding {
  /**
   * Accelerator string understood by both Electron's globalShortcut and the
   * settings UI, e.g. "Control+Alt+Space" or "F8".
   */
  accelerator: string;
  /**
   * When true the hotkey behaves as push-to-talk: hold to record, release to
   * stop. When false it toggles on each press.
   */
  pushToTalk: boolean;
}

export const DEFAULT_SETTINGS: AppSettings = {
  languagePin: 'auto',
  formattingEnabled: true,
  spokenPunctuationEnabled: false,
  silenceTimeoutSeconds: 60,
  maxRecordingSeconds: 600,
  recordingsToKeep: 10,
  soundEffectsEnabled: true,
  launchAtLogin: false,
  hotkey: { accelerator: 'Control+Alt+Space', pushToTalk: false },
  dictionaryBiasBudget: 100,
};
