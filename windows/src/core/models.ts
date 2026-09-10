/**
 * Core domain models for Useful Voice.
 *
 * This directory is deliberately free of any Electron, Node or DOM import. It is
 * the part of the app that must behave identically on every platform, so it is
 * pure TypeScript and fully covered by unit tests that run anywhere.
 */

import { DEEPGRAM_LANGUAGES, isSupportedLanguage } from './transcription/languages.js';

/**
 * The language a setting, term or replacement is scoped to.
 *
 * A plain string rather than a closed union, matching macOS. The offered set is the
 * *provider's* catalogue (`DEEPGRAM_LANGUAGES`), not an app concern: a union listing
 * ten languages silently withheld the other fifty-odd Nova-3 supports, and widening
 * it is a source change in every place that switches on it. `'auto'` and `'multi'`
 * are modes carried in the same field.
 */
export type MemoryLanguage = string;

/** Every value the language pickers offer: the modes, then the languages. */
export const MEMORY_LANGUAGES: readonly MemoryLanguage[] = [
  'auto',
  'multi',
  ...DEEPGRAM_LANGUAGES.map((language) => language.code),
];

/** The modes, which the pickers show above the languages. */
export const LANGUAGE_MODES: readonly MemoryLanguage[] = ['auto', 'multi'];

/**
 * Normalise a stored language value to something sendable.
 *
 * Two things this has to get right, both learned the hard way:
 *
 * 1. **`'multi'` is not `'auto'`.** An earlier build offered `'multi'` in the picker
 *    labelled "Detect automatically". `multi` is code-switching — for audio where
 *    the speaker changes language mid-sentence — while auto-detection is
 *    `detect_language`. A user who chose what they were told was auto-detection was
 *    silently transcribing in the wrong mode. The value survives as a real choice,
 *    but it no longer claims to be detection.
 * 2. **An unknown code must never be sent.** The provider would error, or fall back
 *    to a weaker model that does not support `keyterm` — silently dropping the
 *    dictionary feature.
 *
 * Regions keep their case: folding `zh-HK` to `zh-hk` matches nothing and would
 * quietly demote Cantonese to detection.
 */
export function normaliseMemoryLanguage(value: unknown): MemoryLanguage {
  if (typeof value !== 'string') return 'auto';
  const trimmed = value.trim();
  if (trimmed.length === 0) return 'auto';
  if (trimmed.toLowerCase() === 'auto') return 'auto';
  if (isSupportedLanguage(trimmed)) return trimmed;
  const folded = DEEPGRAM_LANGUAGES.find(
    (language) => language.code.toLowerCase() === trimmed.toLowerCase(),
  );
  return folded ? folded.code : 'auto';
}

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
  /**
   * Opens the language picker while dictating.
   *
   * macOS has had this from the start; Windows did not, so a Windows user had to
   * open Settings and leave the app they were typing into in order to change
   * language. Optional because it is a convenience, and an empty accelerator means
   * disabled rather than an error.
   */
  languageSwitchHotkey?: HotkeyBinding;
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
  languageSwitchHotkey: { accelerator: 'Control+Alt+L', pushToTalk: false },
  dictionaryBiasBudget: 100,
};
