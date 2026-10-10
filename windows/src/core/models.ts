/**
 * Core domain models for Useful Voice.
 *
 * This directory is deliberately free of any Electron, Node or DOM import. It is
 * the part of the app that must behave identically on every platform, so it is
 * pure TypeScript and fully covered by unit tests that run anywhere.
 */

import { DEEPGRAM_LANGUAGES, normaliseLanguageCode } from './transcription/languages.js';

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
 * A thin wrapper over `normaliseLanguageCode` rather than a second implementation.
 * There were briefly two copies of this rule — one here and one in `languages.ts` —
 * which is how a stored-language rule drifts: the settings path and the picker path
 * would have answered differently for the same input.
 *
 * Two things the rule has to get right, both learned the hard way:
 *
 * 1. **`'multi'` is not `'auto'`.** An earlier build offered `'multi'` in the picker
 *    labelled "Detect automatically". `multi` is code-switching — for audio where the
 *    speaker changes language mid-sentence — while auto-detection is
 *    `detect_language`. A user who chose what they were told was auto-detection was
 *    silently transcribing in the wrong mode. The value survives as a real choice, but
 *    it no longer claims to be detection.
 * 2. **An unknown code must never be sent.** The provider would error, or fall back to
 *    a weaker model that does not support `keyterm` — silently dropping the dictionary
 *    feature.
 *
 * Accepts `unknown` because the value comes from a JSON file a user can edit.
 */
export function normaliseMemoryLanguage(value: unknown): MemoryLanguage {
  return typeof value === 'string' ? normaliseLanguageCode(value) : 'auto';
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

/**
 * Where a dictation started. Captured once, at recording start, and kept for that
 * dictation: stopping it, an auto-stop or Esc never change it.
 *
 * `hotkey` pastes into the window that was frontmost at the start. `window` (the main
 * window's mic button, the tray, the app menu) never pastes: it copies and saves.
 */
export type DictationSource = 'hotkey' | 'window';

/** Why a dictation failed, so the UI can attach the right fix instead of parsing text. */
export type DictationErrorKind =
  | 'micUnavailable'
  | 'stopFailed'
  | 'noSpeech'
  | 'tooShort'
  | 'noProvider'
  | 'keyRejected'
  | 'outOfCredits'
  | 'offline'
  | 'timedOut'
  | 'providerFailed'
  | 'deliveryFailed';

/** What the user can do about an error. Absent means there is nothing to offer. */
export type DictationFix = 'openMicrophoneSettings' | 'openEngineSettings' | 'retry';

export interface DictationError {
  kind: DictationErrorKind;
  message: string;
  fix?: DictationFix;
}

/**
 * How a finished dictation reached the user.
 *
 * `pasted`: into the app that was frontmost. `copiedNotPasted`: a hotkey dictation
 * whose paste could not be confirmed, so the text stays on the clipboard. `copied`:
 * a window or retry dictation, saved and copied on purpose ("Saved and copied").
 */
export type DictationDelivery = 'pasted' | 'copiedNotPasted' | 'copied';

/** Sent once per dictation, before the idle status. */
export type DictationOutcomeEvent =
  | { kind: 'delivered'; words: number; result: DictationDelivery; appName?: string }
  | { kind: 'cancelled' };

/**
 * Live numbers for the window and the HUD, sent only while recording.
 *
 * `silenceRemaining` and `maxRemaining` are whole seconds and are present only when
 * 5 s or fewer remain before the matching auto-stop.
 */
export interface DictationTelemetry {
  /** Input level, 0 to 1. */
  level: number;
  elapsedSeconds: number;
  silenceRemaining?: number;
  maxRemaining?: number;
}

export interface DictationRecord {
  id: string;
  text: string;
  /** Transcript before formatting/memory, kept for the "reprocess" feature. */
  rawText: string;
  /** Text after memory but before the optional formatter. */
  intermediateText: string;
  /**
   * The raw detected code Deepgram returned, or the requested pin when detection
   * is absent. Not guaranteed sendable — a regional tag like `de-DE` is stored
   * verbatim for fidelity but must be validated before reuse as `language=`.
   */
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
  /** Which theme the window uses. `system` follows Windows. */
  appearance: Appearance;
  /** Words per day the Insights page measures progress against. No UI sets it yet. */
  dailyWordGoal: number;
}

export type Appearance = 'system' | 'light' | 'dark';

export const APPEARANCES: readonly Appearance[] = ['system', 'light', 'dark'];

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
  appearance: 'system',
  dailyWordGoal: 2500,
};
