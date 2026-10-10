import { contextBridge, ipcRenderer } from 'electron';
import type {
  DictationOutcomeEvent,
  DictationStateEvent,
  DictationTelemetry,
  HistoryEntryDTO,
  HudAction,
  HudFrame,
  MemorySnapshotDTO,
  NoteDTO,
  ResolvedTheme,
  SettingsDTO,
} from './types.js';

/**
 * Subscribe to a main-process broadcast.
 *
 * Returns an unsubscribe function, and wraps the handler so the Electron event
 * object never reaches renderer code.
 */
function subscribe(channel: string, handler: () => void): () => void {
  const listener = (): void => handler();
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

/**
 * The renderer's entire view of the system.
 *
 * `contextIsolation` is on and `nodeIntegration` is off, so this is the only
 * surface the UI can reach: no filesystem, no API key, no hotkey registry. The
 * API key in particular never crosses this boundary — the renderer can ask
 * whether one is configured, never read it.
 */
const api = {
  // ---- dictation ----
  toggleDictation: (): Promise<void> => ipcRenderer.invoke('dictation:toggle'),
  cancelDictation: (): Promise<void> => ipcRenderer.invoke('dictation:cancel'),
  retryLast: (): Promise<void> => ipcRenderer.invoke('dictation:retry'),
  copyLastTranscript: (): Promise<void> => ipcRenderer.invoke('dictation:copyLast'),

  /**
   * Recording actually happens in the renderer, because that is where the Web
   * Audio API lives. The main process asks for it over these channels and the
   * renderer replies with encoded audio.
   */
  onStartRecording: (handler: () => void): (() => void) => {
    const listener = (): void => handler();
    ipcRenderer.on('audio:start', listener);
    return () => ipcRenderer.removeListener('audio:start', listener);
  },
  onStopRecording: (handler: () => void): (() => void) => {
    const listener = (): void => handler();
    ipcRenderer.on('audio:stop', listener);
    return () => ipcRenderer.removeListener('audio:stop', listener);
  },
  /**
   * Send captured audio to the main process.
   *
   * The payload is a plain ArrayBuffer so it survives structured cloning without
   * an extra copy through a Node Buffer.
   */
  sendAudio: (wav: ArrayBuffer, meta: { durationSeconds: number; peak: number; hadSpeech: boolean }): Promise<void> =>
    ipcRenderer.invoke('audio:captured', wav, meta),
  sendAudioError: (message: string): Promise<void> => ipcRenderer.invoke('audio:error', message),
  sendLevel: (level: number): void => ipcRenderer.send('audio:level', level),

  // ---- state ----
  onState: (handler: (event: DictationStateEvent) => void): (() => void) => {
    const listener = (_event: unknown, payload: DictationStateEvent): void => handler(payload);
    ipcRenderer.on('dictation:state', listener);
    return () => ipcRenderer.removeListener('dictation:state', listener);
  },
  /**
   * How a dictation ended: delivered (with its word count and how it reached the
   * user) or cancelled. Sent once per dictation, just before the idle state.
   */
  onOutcome: (handler: (outcome: DictationOutcomeEvent) => void): (() => void) => {
    const listener = (_event: unknown, payload: DictationOutcomeEvent): void => handler(payload);
    ipcRenderer.on('dictation:outcome', listener);
    return () => ipcRenderer.removeListener('dictation:outcome', listener);
  },
  /**
   * Level, elapsed time and the last-5-seconds countdowns. Sent to the main window
   * and the HUD at most ~30 times a second, and only while recording.
   */
  onTelemetry: (handler: (telemetry: DictationTelemetry) => void): (() => void) => {
    const listener = (_event: unknown, payload: DictationTelemetry): void => handler(payload);
    ipcRenderer.on('dictation:telemetry', listener);
    return () => ipcRenderer.removeListener('dictation:telemetry', listener);
  },
  onLevel: (handler: (level: number) => void): (() => void) => {
    const listener = (_event: unknown, level: number): void => handler(level);
    ipcRenderer.on('hud:level', listener);
    return () => ipcRenderer.removeListener('hud:level', listener);
  },
  /**
   * What the HUD window should draw: the latest view, or null once it should sink away.
   * The window draws only this, so a stale view can never be left on screen.
   */
  onHudView: (handler: (frame: HudFrame | null) => void): (() => void) => {
    const listener = (_event: unknown, payload: HudFrame | null): void => handler(payload);
    ipcRenderer.on('hud:view', listener);
    return () => ipcRenderer.removeListener('hud:view', listener);
  },
  /**
   * The HUD window ignores the mouse except over its buttons. The renderer says when the
   * pointer enters or leaves one, and main toggles click-through to match.
   */
  hudPointer: (overButton: boolean): void => ipcRenderer.send('hud:pointer', overButton),
  hudAction: (action: HudAction): Promise<void> => ipcRenderer.invoke('hud:action', action),
  /** A line for a screen reader. Sent to whichever window the user is in. */
  onAnnounce: (handler: (text: string, urgency: 'polite' | 'assertive') => void): (() => void) => {
    const listener = (_event: unknown, payload: { text: string; urgency: 'polite' | 'assertive' }): void =>
      handler(payload.text, payload.urgency);
    ipcRenderer.on('app:announce', listener);
    return () => ipcRenderer.removeListener('app:announce', listener);
  },
  onNavigate: (handler: (page: string, anchor?: string) => void): (() => void) => {
    const listener = (_event: unknown, page: string, anchor?: string): void => handler(page, anchor);
    // `app:` like every other app-lifecycle channel: the tray and the second-instance
    // handler use this to send the renderer to a page from outside its own UI.
    ipcRenderer.on('app:navigate', listener);
    return () => ipcRenderer.removeListener('app:navigate', listener);
  },

  /**
   * Fires in the floating language picker window each time the hotkey (or the tray)
   * opens it, so it can reset its search and take focus.
   *
   * The hotkey is global, so it can arrive while the user is in another application.
   * The picker is its own focusable window and the main window stays where it is.
   */
  onOpenLanguagePicker: (handler: () => void): (() => void) => {
    const listener = (): void => handler();
    ipcRenderer.on('app:openLanguagePicker', listener);
    return () => ipcRenderer.removeListener('app:openLanguagePicker', listener);
  },

  /**
   * Data changed somewhere the renderer did not initiate.
   *
   * These three exist because the main process broadcasts them — `history:changed`
   * on every completed dictation, `memory:changed` from learning and the tray, and
   * `notes:changed` from the tray — but nothing was listening. The visible result
   * was a stale list: dictate by hotkey with History open and the new entry never
   * appeared, because the renderer only refreshed for mutations it had started
   * itself.
   *
   * Kept as three separate events rather than one generic "something changed" so a
   * page only refetches what it actually displays.
   */
  onHistoryChanged: (handler: () => void): (() => void) =>
    subscribe('history:changed', handler),
  onMemoryChanged: (handler: () => void): (() => void) =>
    subscribe('memory:changed', handler),
  onNotesChanged: (handler: () => void): (() => void) =>
    subscribe('notes:changed', handler),

  // ---- language picker window ----
  /** The floating picker chose a language (or closed without one). */
  pickerChoose: (value: string): Promise<void> => ipcRenderer.invoke('app:picker-choose', value),
  pickerClose: (): Promise<void> => ipcRenderer.invoke('app:picker-close'),

  // ---- settings ----
  /**
   * Settings changed somewhere the renderer did not initiate: the language picker or the
   * tray menu. A page showing those values refetches.
   */
  onSettingsChanged: (handler: () => void): (() => void) => subscribe('settings:changed', handler),
  getSettings: (): Promise<SettingsDTO> => ipcRenderer.invoke('settings:get'),
  saveSettings: (patch: Partial<SettingsDTO>): Promise<SettingsDTO> => ipcRenderer.invoke('settings:save', patch),
  setApiKey: (key: string): Promise<{ ok: boolean; error?: string }> => ipcRenderer.invoke('settings:set-api-key', key),
  clearApiKey: (): Promise<void> => ipcRenderer.invoke('settings:clear-api-key'),
  testApiKey: (): Promise<{ ok: boolean; message: string }> => ipcRenderer.invoke('settings:test-api-key'),
  resetApiKey: (): Promise<{ ok: boolean; message: string }> => ipcRenderer.invoke('settings:reset-api-key'),

  // ---- memory ----
  getMemory: (): Promise<MemorySnapshotDTO> => ipcRenderer.invoke('memory:get'),
  addTerm: (input: { phrase: string; soundAlike?: string; alias?: string; language: string }): Promise<void> =>
    ipcRenderer.invoke('memory:add-term', input),
  updateTerm: (id: string, patch: Record<string, unknown>): Promise<void> =>
    ipcRenderer.invoke('memory:update-term', { id, patch }),
  removeTerm: (id: string): Promise<void> => ipcRenderer.invoke('memory:remove-term', id),
  addReplacement: (input: { match: string; replacement: string; language: string }): Promise<void> =>
    ipcRenderer.invoke('memory:add-replacement', input),
  setReplacementEnabled: (id: string, isEnabled: boolean): Promise<void> =>
    ipcRenderer.invoke('memory:set-replacement-enabled', { id, isEnabled }),
  removeReplacement: (id: string): Promise<void> => ipcRenderer.invoke('memory:remove-replacement', id),
  addSnippet: (input: { trigger: string; expansion: string; language: string }): Promise<void> =>
    ipcRenderer.invoke('memory:add-snippet', input),
  removeSnippet: (id: string): Promise<void> => ipcRenderer.invoke('memory:remove-snippet', id),
  acceptSuggestion: (id: string): Promise<void> => ipcRenderer.invoke('memory:accept-suggestion', id),
  dismissSuggestion: (id: string): Promise<void> => ipcRenderer.invoke('memory:dismiss-suggestion', id),

  // ---- history ----
  getHistory: (): Promise<HistoryEntryDTO[]> => ipcRenderer.invoke('history:get'),
  removeHistory: (id: string): Promise<void> => ipcRenderer.invoke('history:remove', id),
  clearHistory: (): Promise<void> => ipcRenderer.invoke('history:clear'),
  exportHistoryCsv: (): Promise<{ ok: boolean; message: string }> => ipcRenderer.invoke('history:export-csv'),

  // ---- notes ----
  getNotes: (): Promise<NoteDTO[]> => ipcRenderer.invoke('notes:get'),
  saveNote: (note: { id?: string; title: string; body: string }): Promise<NoteDTO> =>
    ipcRenderer.invoke('notes:save', note),
  deleteNote: (id: string): Promise<{ id: string; title: string; body: string; index: number } | null> =>
    ipcRenderer.invoke('notes:delete', id),
  restoreNote: (payload: { id: string; title: string; body: string; createdAt?: string; updatedAt?: string }, index: number): Promise<void> =>
    ipcRenderer.invoke('notes:restore', payload, index),

  // ---- backup ----
  exportBackup: (): Promise<{ ok: boolean; message: string }> => ipcRenderer.invoke('backup:export'),
  importBackup: (): Promise<{ ok: boolean; message: string }> => ipcRenderer.invoke('backup:import'),
  exportCsv: (kind: 'terms' | 'fixes'): Promise<{ ok: boolean; message: string }> =>
    ipcRenderer.invoke('backup:export-csv', kind),
  importCsv: (kind: 'terms' | 'fixes', text: string): Promise<{ ok: boolean; message: string }> =>
    ipcRenderer.invoke('backup:import-csv', { kind, text }),
  copyToClipboard: (text: string): Promise<void> => ipcRenderer.invoke('clipboard:write', text),

  // ---- theme ----
  getTheme: (): Promise<ResolvedTheme> => ipcRenderer.invoke('app:get-theme'),
  onThemeChanged: (handler: (theme: ResolvedTheme) => void): (() => void) => {
    const listener = (_event: unknown, theme: ResolvedTheme): void => handler(theme);
    ipcRenderer.on('app:theme', listener);
    return () => ipcRenderer.removeListener('app:theme', listener);
  },

  // ---- app ----
  openExternal: (url: string): Promise<void> => ipcRenderer.invoke('app:open-external', url),
  getDiagnostics: (): Promise<{ version: string; platform: string; logPath: string; recentErrors: string[] }> =>
    ipcRenderer.invoke('app:diagnostics'),
  getFlags: (): Promise<{ previewFeatures: boolean }> => ipcRenderer.invoke('app:flags'),
  showDiagnosticsLog: (): Promise<void> => ipcRenderer.invoke('app:show-log'),
  getSaveStatus: (): Promise<{ ok: boolean; message?: string }> => ipcRenderer.invoke('app:save-status'),
  onSaveStatus: (handler: (status: { ok: boolean; message?: string }) => void): (() => void) => {
    const listener = (_event: unknown, status: { ok: boolean; message?: string }): void => handler(status);
    ipcRenderer.on('app:save-status', listener);
    return () => ipcRenderer.removeListener('app:save-status', listener);
  },
  quit: (): Promise<void> => ipcRenderer.invoke('app:quit'),
};

contextBridge.exposeInMainWorld('usefulVoice', api);

export type UsefulVoiceApi = typeof api;
