
/**
 * The only bridge between the renderer and the main process.
 *
 * `contextIsolation` is on and `nodeIntegration` is off, so the renderer never
 * gets Node or Electron APIs directly — it sees exactly this surface. Every method
 * is an explicit, named channel, which means the renderer cannot reach the
 * filesystem, the API key, or the global hotkey registry on its own.
 */

export interface DictationStateEvent {
  state: 'idle' | 'recording' | 'transcribing' | 'delivering' | 'error';
  message?: string;
  /** Which app will receive the text, for the HUD. */
  targetApp?: string;
  elapsedSeconds?: number;
}

export interface MemorySnapshotDTO {
  terms: Array<{
    id: string;
    phrase: string;
    aliases: string[];
    pronunciations: string[];
    language: string;
    priority: string;
    notes: string;
    usageCount: number;
  }>;
  replacements: Array<{
    id: string;
    match: string;
    replacement: string;
    language: string;
    isEnabled: boolean;
    usageCount: number;
  }>;
  snippets: Array<{
    id: string;
    trigger: string;
    expansion: string;
    language: string;
    isEnabled: boolean;
    usageCount: number;
  }>;
  suggestions: Array<{ id: string; observed: string; corrected: string; evidenceCount: number }>;
  /** What had to be left out of the keyterm list, if anything. */
  keytermReport: { used: number; limit: number; dropped: number; rejected: number };
}

export interface SettingsDTO {
  languagePin: string;
  formattingEnabled: boolean;
  silenceTimeoutSeconds: number;
  maxRecordingSeconds: number;
  recordingsToKeep: number;
  soundEffectsEnabled: boolean;
  launchAtLogin: boolean;
  hotkey: { accelerator: string; pushToTalk: boolean };
  dictionaryBiasBudget: number;
  hasApiKey: boolean;
}

export interface HistoryEntryDTO {
  id: string;
  text: string;
  rawText: string;
  language: string;
  appName: string;
  durationSeconds: number;
  mode: string;
  createdAt: string;
  memoryHitCount: number;
}

export interface NoteDTO {
  id: string;
  title: string;
  body: string;
  createdAt: string;
  updatedAt: string;
}
