import { app, BrowserWindow, clipboard, globalShortcut, ipcMain, shell, Menu } from 'electron';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promises as fs, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import os from 'node:os';

import { DataStore } from '../core/settings/dataStore.js';
import { planLoginItem, wasAutoStarted } from '../core/settings/autostart.js';
import { decideClipboardRestore, isProbablyVerifiable } from '../core/delivery/clipboardRestore.js';
import { normaliseMemoryLanguage, type AppSettings, type Note } from '../core/models.js';
import { selectKeyterms } from '../core/memory/biasBuilder.js';
import {
  transcribe as transcribeRequest,
  type DeepgramConfig,
  type TranscriptionHint,
} from '../core/transcription/deepgramProvider.js';
import { SettingsStore } from './settingsStore.js';
import { TrayController } from './tray.js';
import {
  DictationService,
  type CapturedAudio,
  type DictationStatus,
} from './dictationService.js';
import {
  Diagnostics,
  clipboardHoldsText,
  foregroundWindow,
  ownProcessName,
  pasteClipboard,
  playCue,
  restoreClipboard,
  snapshotClipboard,
  sendUndo,
} from './windowsPlatform.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/**
 * The Windows app.
 *
 * Architecture note: recording happens in a hidden renderer process, because
 * `getUserMedia`/`MediaRecorder` live in the browser and Electron deliberately
 * does not expose them to the main process. The main process owns everything that
 * must not be reachable from web content: the API key, the filesystem, the global
 * hotkey, and the keyboard automation that pastes the result.
 */

/** How long the clipboard restore is deferred after a paste, in milliseconds. */
const CLIPBOARD_RESTORE_DELAY_MS = 700;

/** How long a cancelled paste can still be taken back with Ctrl+Z. */
const UNDO_WINDOW_MS = 6000;

class UsefulVoiceApp {
  private settings!: SettingsStore;
  private data!: DataStore;
  private tray: TrayController | null = null;
  private recorderWindow: BrowserWindow | null = null;
  private mainWindow: BrowserWindow | null = null;
  private hudWindow: BrowserWindow | null = null;
  private service!: DictationService;
  private diagnostics!: Diagnostics;

  /** Set while `service` is waiting for audio from the renderer. */
  private pendingCapture: {
    resolve: (audio: CapturedAudio) => void;
    reject: (error: Error) => void;
    startedAt: number;
  } | null = null;

  private audioTargetApp: string | undefined;
  private lastPaste: { text: string; at: number } | null = null;

  async start(): Promise<void> {
    // A second launch must hand off to the running instance rather than start a
    // second hotkey registration, which Windows would silently refuse.
    if (!app.requestSingleInstanceLock()) {
      app.quit();
      return;
    }
    app.on('second-instance', (_event, commandLine) => {
      // The command line belongs to the instance that just started, not to this one,
      // which is why the flag is read from it rather than from `process.argv`: a second
      // launch carrying `--autostart` is a launch nobody clicked, so it must not pull a
      // window in front of whatever the user is doing. That happens when the login
      // entry fires more than once — two Run values after an install to a new path, for
      // instance — or when the app is opened by hand while the login launch is still
      // coming up.
      if (wasAutoStarted(commandLine)) return;
      void this.openWindow('home');
    });

    app.setAppUserModelId(APP_USER_MODEL_ID);

    await app.whenReady();

    this.diagnostics = new Diagnostics(app.getPath('userData'));
    this.diagnostics.log('app', `starting ${app.getVersion()} on ${os.release()}`);
    if (wasAutoStarted(process.argv)) {
      // Recorded so "why was this running?" is answerable from Settings. A launch
      // from the login entry and a user double-click look identical from here, and
      // conflating them is what makes "it opened by itself" reports hard to settle.
      this.diagnostics.log('app', 'launched from the login entry');
    }

    this.settings = new SettingsStore(app.getPath('userData'));
    await this.settings.load();
    if (this.settings.saveError) {
      this.diagnostics.log('settings', this.settings.saveError.message);
    }

    this.data = new DataStore(path.join(app.getPath('userData'), 'data.json'));
    await this.data.load();
    this.diagnostics.log('data', `load outcome: ${this.data.outcome.status}`);
    this.data.onSaveFailure((error) => {
      this.diagnostics.log('data', `save failed: ${error.message}`);
      this.broadcast('app:save-status', {
        ok: false,
        message: 'Your changes could not be saved. Check free disk space.',
      });
    });

    this.createRecorderWindow();
    this.service = this.buildService();
    this.tray = new TrayController({
      onToggleDictation: () => void this.toggleDictation(),
      onOpenWindow: (page) => this.openWindow(page),
      onQuit: () => void this.quit(),
      onRetry: () => void this.service.retryLast(),
      onCopyLast: () => this.copyLastTranscript(),
      onCancel: () => void this.service.cancel(),
    });
    this.tray.create();

    this.registerHotkey();
    this.registerIpc();
    this.buildApplicationMenu();

    const settings = this.settings.all;
    // Re-asserted on every start, not only when the setting changes: an update can
    // rewrite the entry, and Windows' own Startup Apps page can disable it behind
    // the app's back, so the stored preference is the thing to trust.
    this.applyLoginItem(settings.launchAtLogin, 'startup');
  }

  /**
   * Register or remove the Windows login entry.
   *
   * The arguments are decided by `planLoginItem`, which is pure and therefore
   * tested: they have to include the auto-start flag, or the app cannot tell a login
   * launch from the user opening it. Only Windows is touched — on macOS the same
   * call manages a Login Item through the system, which a development run must not
   * do to the developer's machine.
   */
  private applyLoginItem(enabled: boolean, context: string): void {
    const plan = planLoginItem({
      enabled,
      platform: process.platform,
      isPackaged: app.isPackaged,
      execPath: process.execPath,
      appPath: app.getAppPath(),
    });

    if (!plan.apply) {
      if (enabled) {
        // Worth a line in the log: the switch reads as on in Settings while nothing
        // has been registered, which is confusing unless the reason is recorded.
        this.diagnostics.log('login', `${context}: login entry not managed on ${process.platform}`);
      }
      return;
    }

    try {
      app.setLoginItemSettings(plan.settings);
    } catch (error) {
      this.diagnostics.log('login', `${context}: could not update the login entry — ${(error as Error).message}`);
      return;
    }

    // Read back with the same path and args, because that is how Electron compares
    // the stored command line. A mismatch means the write did not take (a locked-down
    // policy, or another tool rewriting the Run key), and without this check "Start
    // with Windows" would be a switch that silently does nothing.
    const registered = app.getLoginItemSettings(plan.settings).openAtLogin;
    if (registered !== plan.settings.openAtLogin) {
      this.diagnostics.log(
        'login',
        `${context}: login entry is ${registered ? 'present' : 'absent'} after asking for ${plan.settings.openAtLogin} (${plan.reason})`,
      );
    }
  }

  // ---- lifecycle ---------------------------------------------------------

  private createRecorderWindow(): void {
    // Hidden, never shown: it exists only to host Web Audio capture. It is kept
    // alive so the microphone permission grant persists and recording starts
    // instantly rather than waiting for a renderer to boot.
    this.recorderWindow = new BrowserWindow({
      show: false,
      width: 400,
      height: 300,
      webPreferences: {
        preload: path.join(__dirname, '../preload/index.js'),
        contextIsolation: true,
        nodeIntegration: false,
        // Audio capture needs media access; the permission handler below grants
        // it only to our own origin.
        backgroundThrottling: false,
      },
    });
    void this.recorderWindow.loadFile(path.join(__dirname, '../renderer/index.html'), {
      query: { view: 'recorder' },
    });
  }

  private async openWindow(page: string): Promise<void> {
    if (page === 'hud') return;

    if (!this.mainWindow || this.mainWindow.isDestroyed()) {
      this.mainWindow = new BrowserWindow({
        width: 1040,
        height: 720,
        minWidth: 820,
        minHeight: 560,
        backgroundColor: '#f8f8f8',
        title: 'Useful Voice',
        autoHideMenuBar: false,
        webPreferences: {
          preload: path.join(__dirname, '../preload/index.js'),
          contextIsolation: true,
          nodeIntegration: false,
        },
      });
      this.mainWindow.on('closed', () => {
        this.mainWindow = null;
      });
      await this.mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'), {
        query: { view: 'main' },
      });
      this.mainWindow.webContents.on('did-finish-load', () => this.pushAll());
    } else {
      this.mainWindow.show();
      this.mainWindow.focus();
    }
    this.broadcast('app:navigate', page);
  }

  /**
   * A small always-on-top window shown while recording.
   *
   * Deliberately not focusable: it must never steal focus from the app the user is
   * dictating into, which would make the paste land in the wrong place — the bug
   * that made the macOS HUD a panel with `becomesKeyOnlyIfNeeded`.
   */
  private showHud(): void {
    if (this.hudWindow && !this.hudWindow.isDestroyed()) {
      this.hudWindow.showInactive();
      return;
    }
    const { width } = require('electron').screen.getPrimaryDisplay().workAreaSize;
    this.hudWindow = new BrowserWindow({
      width: 280,
      height: 64,
      x: Math.round(width / 2 - 140),
      y: 24,
      frame: false,
      resizable: false,
      movable: false,
      focusable: false,
      skipTaskbar: true,
      alwaysOnTop: true,
      transparent: true,
      show: false,
      webPreferences: {
        preload: path.join(__dirname, '../preload/index.js'),
        contextIsolation: true,
        nodeIntegration: false,
      },
    });
    this.hudWindow.setIgnoreMouseEvents(true);
    void this.hudWindow.loadFile(path.join(__dirname, '../renderer/index.html'), {
      query: { view: 'hud' },
    });
    this.hudWindow.once('ready-to-show', () => this.hudWindow?.showInactive());
    this.hudWindow.on('closed', () => {
      this.hudWindow = null;
    });
  }

  private hideHud(): void {
    if (this.hudWindow && !this.hudWindow.isDestroyed()) this.hudWindow.hide();
  }

  async quit(): Promise<void> {
    try {
      await this.service.cancel();
      // Always give the data a chance to reach disk before exiting: a debounced
      // save that never fires would lose the user's last dictionary edit.
      await this.data.flush();
      await this.settings.save();
      await this.diagnostics.flush();
    } finally {
      globalShortcut.unregisterAll();
      this.tray?.destroy();
      app.exit(0);
    }
  }

  // ---- hotkey ------------------------------------------------------------

  private registerHotkey(): void {
    globalShortcut.unregisterAll();
    const accelerator = this.settings.all.hotkey.accelerator;
    if (accelerator.trim().length === 0) {
      this.diagnostics.log('hotkey', 'no hotkey configured');
      return;
    }
    // A failed registration is a real, user-visible problem: another app already
    // owns the combination, so dictation would silently never start.
    const ok = globalShortcut.register(accelerator, () => void this.toggleDictation());
    if (!ok) {
      this.diagnostics.log('hotkey', `could not register ${accelerator}`);
      this.broadcast('app:save-status', {
        ok: false,
        message: `The hotkey ${accelerator} is already used by another app. Choose a different one in Settings.`,
      });
    } else {
      this.diagnostics.log('hotkey', `registered ${accelerator}`);
    }

    this.registerLanguageHotkey();
  }

  /**
   * Registers the language-picker hotkey, if one is set.
   *
   * Registered separately from the dictation hotkey and reported separately,
   * because the two failures are independent: if this combination is taken the user
   * can still dictate, and telling them dictation is broken would be wrong.
   */
  private registerLanguageHotkey(): void {
    const binding = this.settings.all.languageSwitchHotkey;
    const accelerator = binding?.accelerator?.trim() ?? '';
    if (accelerator.length === 0) {
      this.diagnostics.log('hotkey', 'no language-switch hotkey configured');
      return;
    }
    if (accelerator === this.settings.all.hotkey.accelerator) {
      // Two global shortcuts on one combination would have the second registration
      // silently refused by Windows, with no way for the user to tell why.
      this.diagnostics.log('hotkey', `language hotkey ${accelerator} duplicates the dictation hotkey`);
      return;
    }
    const ok = globalShortcut.register(accelerator, () => this.openLanguagePicker());
    this.diagnostics.log(
      'hotkey',
      ok ? `registered language switch ${accelerator}` : `could not register language switch ${accelerator}`,
    );
    if (!ok) {
      this.broadcast('app:save-status', {
        ok: false,
        message: `The language hotkey ${accelerator} is already used by another app. Choose a different one in Settings.`,
      });
    }
  }

  /**
   * Opens the language picker in the main window, bringing it forward.
   *
   * Unlike macOS — which floats a panel over the app being dictated into — the
   * picker here needs a window that can hold focus for the search field, so the main
   * window is shown. It is not possible to give a Chromium window a searchable
   * popup without one, and a non-searchable overlay would defeat the point.
   */
  private openLanguagePicker(): void {
    const window = this.mainWindow;
    if (!window || window.isDestroyed()) {
      this.diagnostics.log('hotkey', 'language picker requested with no main window');
      return;
    }
    if (window.isMinimized()) window.restore();
    window.show();
    window.focus();
    window.webContents.send('app:openLanguagePicker');
  }

  // ---- dictation ---------------------------------------------------------

  private buildService(): DictationService {
    return new DictationService({
      recorder: {
        start: async () => {
          this.recorderWindow?.webContents.send('audio:start');
        },
        stop: async () => this.awaitCapture(),
        cancel: async () => {
          this.recorderWindow?.webContents.send('audio:stop');
          this.pendingCapture = null;
        },
      },
      transcriber: {
        // Adapt the pure request builder to the port the state machine expects.
        transcribe: (request, signal) => {
          const config: DeepgramConfig = {
            apiKey: this.settings.revealApiKey() ?? '',
            smartFormat: request.smartFormat,
            spokenPunctuation: request.spokenPunctuation,
          };
          const hint: TranscriptionHint = {
            language: request.language,
            keyterms: request.keyterms,
          };
          return transcribeRequest({
            audio: request.audio,
            hint,
            config,
            signal,
            maxAttempts: 3,
          });
        },
      },
      sink: { deliver: (request) => this.deliver(request.text, request.targetApp) },
      settings: () => this.settings.all,
      memory: () => this.data.memorySnapshot(),
      apiKey: async () => this.settings.revealApiKey(),
      onStatus: (status) => this.handleStatus(status),
      onCompleted: (outcome) => {
        this.data.appendHistory({
          id: outcome.id,
          text: outcome.text,
          rawText: outcome.rawText,
          intermediateText: outcome.intermediateText,
          language: outcome.language,
          appName: outcome.appName,
          durationSeconds: outcome.durationSeconds,
          mode: outcome.mode,
          createdAt: outcome.createdAt,
          replacementRuleIds: outcome.replacementRuleIds,
          memoryHitIds: outcome.memoryHitIds,
          snippetIds: outcome.snippetIds,
        });
        this.data.recordUsage({
          termIds: outcome.memoryHitIds,
          replacementRuleIds: outcome.replacementRuleIds,
          snippetIds: outcome.snippetIds,
        });
        void this.data.flush();
        void playCue('stop').catch(() => undefined);
        this.broadcast('history:changed');
      },
    });
  }

  /** Resolve with the audio the renderer captured, or fail after a bounded wait. */
  private async awaitCapture(): Promise<CapturedAudio> {
    const timeoutMs = 4000;
    return new Promise<CapturedAudio>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingCapture = null;
        reject(new Error('The microphone did not return any audio.'));
      }, timeoutMs);
      timer.unref?.();
      this.pendingCapture = {
        startedAt: Date.now(),
        resolve: (audio) => {
          clearTimeout(timer);
          this.pendingCapture = null;
          resolve(audio);
        },
        reject: (error) => {
          clearTimeout(timer);
          this.pendingCapture = null;
          reject(error);
        },
      };
    });
  }

  private handleStatus(status: DictationStatus): void {
    this.broadcast('dictation:state', status);
    this.tray?.setState({
      recording: status.state === 'recording',
      transcribing: status.state === 'transcribing' || status.state === 'delivering',
      canRetry: this.service?.canRetry ?? false,
      hotkeyLabel: this.settings.all.hotkey.accelerator,
      targetApp: status.targetApp,
    });

    if (status.state === 'recording') {
      this.showHud();
      void playCue('start').catch(() => undefined);
    } else if (status.state === 'idle') {
      this.hideHud();
    } else if (status.state === 'error') {
      this.hideHud();
      this.diagnostics.log('dictation', status.message ?? 'error');
      void playCue('error').catch(() => undefined);
    }
  }

  private async toggleDictation(): Promise<void> {
    if (this.service.currentState === 'idle' || this.service.currentState === 'error') {
      // Capture which app is focused NOW, before recording. By the time the
      // transcript is ready the user may have clicked elsewhere, and pasting into
      // the wrong window is worse than not pasting at all.
      const target = await foregroundWindow();
      if (target) {
        const own = ownProcessName();
        if (target.processName.replace(/\.exe$/i, '').toLowerCase() === own) {
          // Never dictate into our own settings window.
          this.audioTargetApp = undefined;
        } else {
          this.audioTargetApp = target.title || target.processName;
        }
      } else {
        this.audioTargetApp = undefined;
      }
    }
    await this.service.toggle({ targetApp: this.audioTargetApp });
    void this.data.flush();
  }

  /**
   * Put the text where the user is working.
   *
   * The contract: the text is ALWAYS available afterwards, either pasted or on the
   * clipboard. The macOS version restored the previous clipboard contents on a
   * timer that could fire before the paste landed, destroying the dictation — so
   * the restore here is gated on proof that the paste actually arrived, and an
   * unverifiable target keeps the text on the clipboard instead.
   *
   * This method only observes; every rule about what may then happen to the
   * clipboard lives in `decideClipboardRestore`, so the contract is testable without
   * Electron and cannot drift from what the tests assert.
   */
  private async deliver(text: string, targetApp?: string): Promise<{ delivered: boolean; clipboardFallback: boolean }> {
    const target = await foregroundWindow();
    const snapshot = snapshotClipboard();

    clipboard.writeText(text);
    this.lastPaste = null;

    const pasteSent = await pasteClipboard();

    // Confirmation is limited to observing that focus did not move and that the
    // clipboard was consumed: reading the target's text is not possible without a
    // UI-automation dependency. Both reads are skipped when they could not mean
    // anything — an unverifiable target, or a paste that never ran.
    let focusAfter = null as Awaited<ReturnType<typeof foregroundWindow>>;
    let stillOurs = false;
    if (pasteSent && isProbablyVerifiable(target)) {
      // The target needs a moment to handle the keystroke; reading the clipboard
      // sooner would see our own text and call a landed paste a failure.
      await delay(CLIPBOARD_RESTORE_DELAY_MS);
      focusAfter = await foregroundWindow();
      stillOurs = clipboardHoldsText(text);
    }

    const decision = decideClipboardRestore({
      clipboard: snapshot,
      target,
      pasteSent,
      focusAfter,
      clipboardStillHoldsText: stillOurs,
    });

    if (decision.restore) {
      this.restoreSnapshot(snapshot);
    } else if (decision.reason === 'snapshot-incomplete') {
      this.diagnostics.log('clipboard', 'not restoring: original could not be captured fully');
    } else if (decision.reason === 'unverifiable-target') {
      const name = target?.processName ?? targetApp ?? 'the target app';
      this.diagnostics.log('delivery', `unverifiable target (${name}); left on clipboard`);
    }

    if (pasteSent) {
      // Armed for any paste that was *sent*, proven or not, which is the behaviour
      // this extraction deliberately preserves: someone who cancels right after a
      // dictation expects Ctrl+Z to take it back even when delivery could not be
      // confirmed. A paste that never ran arms nothing, so undo cannot reach back
      // past the previous dictation.
      this.lastPaste = { text, at: Date.now() };
    }

    return { delivered: decision.delivered, clipboardFallback: !decision.delivered };
  }

  /**
   * Put a snapshot back and report whether the clipboard really holds it again.
   *
   * Whether it may be put back at all has already been decided: this only writes.
   */
  private restoreSnapshot(snapshot: ReturnType<typeof snapshotClipboard>): void {
    const restored = restoreClipboard(snapshot);
    if (!restored) {
      this.diagnostics.log('clipboard', 'restore did not verify; dictation left in place');
    }
  }

  /** Take back a paste the user cancelled, if the target still allows an undo. */
  private async undoLastPaste(): Promise<void> {
    if (!this.lastPaste) return;
    if (Date.now() - this.lastPaste.at > UNDO_WINDOW_MS) return;
    await sendUndo().catch(() => undefined);
    this.lastPaste = null;
  }

  private copyLastTranscript(): void {
    const outcome = this.service.mostRecent;
    if (!outcome) return;
    clipboard.writeText(outcome.text);
  }

  // ---- windows and IPC ---------------------------------------------------

  private broadcast(channel: string, payload?: unknown): void {
    for (const window of [this.mainWindow, this.recorderWindow, this.hudWindow]) {
      if (window && !window.isDestroyed()) {
        window.webContents.send(channel, payload);
      }
    }
  }

  private pushAll(): void {
    this.broadcast('app:save-status', { ok: this.settings.saveError === null });
  }

  private memoryDto() {
    const snapshot = this.data.memorySnapshot();
    const selection = selectKeyterms({
      terms: snapshot.terms,
      replacements: snapshot.replacements,
      snippets: snapshot.snippets,
      language: this.settings.all.languagePin,
      budget: this.settings.all.dictionaryBiasBudget,
    });
    return {
      ...snapshot,
      keytermReport: {
        used: selection.terms.length,
        limit: selection.limit,
        dropped: selection.droppedCount,
        rejected: selection.rejectedCount,
      },
    };
  }

  private registerIpc(): void {
    ipcMain.handle('audio:captured', (_event, wav: ArrayBuffer, meta: { durationSeconds: number; peak: number; hadSpeech: boolean }) => {
      const pending = this.pendingCapture;
      if (!pending) return;
      pending.resolve({
        wav: new Uint8Array(wav),
        durationSeconds: meta.durationSeconds,
        peak: meta.peak,
        hadSpeech: meta.hadSpeech,
      });
    });

    ipcMain.handle('audio:error', (_event, message: string) => {
      this.pendingCapture?.reject(new Error(message));
    });

    ipcMain.on('audio:level', (_event, level: number) => {
      if (this.hudWindow && !this.hudWindow.isDestroyed()) {
        this.hudWindow.webContents.send('hud:level', level);
      }
    });

    ipcMain.handle('dictation:toggle', () => this.toggleDictation());
    ipcMain.handle('dictation:cancel', async () => {
      await this.undoLastPaste();
      await this.service.cancel();
    });
    ipcMain.handle('dictation:retry', () => this.service.retryLast());
    ipcMain.handle('dictation:copyLast', () => this.copyLastTranscript());

    ipcMain.handle('settings:get', () => ({
      ...this.settings.all,
      hasApiKey: this.settings.hasApiKey,
    }));
    ipcMain.handle('settings:save', (_event, patch: Partial<AppSettings>) => {
      const next = this.settings.update(patch);
      this.registerHotkey();
      // Goes through the same plan as startup, so the entry written here is the one
      // the launcher will start and the one `--autostart` will therefore arrive on.
      this.applyLoginItem(next.launchAtLogin, 'settings');
      return { ...next, hasApiKey: this.settings.hasApiKey };
    });
    ipcMain.handle('settings:set-api-key', (_event, key: string) => this.settings.setApiKey(key));
    ipcMain.handle('settings:clear-api-key', () => this.settings.clearApiKey());
    ipcMain.handle('settings:test-api-key', async () => this.testApiKey());
    ipcMain.handle('settings:reset-api-key', async () => {
      // Clears the stored key AND the cached failure state, so a user who hit the
      // "could not be decrypted" path is not stuck.
      this.settings.clearApiKey();
      await this.settings.save();
      return { ok: true, message: 'The stored key was removed. Add a new one.' };
    });

    ipcMain.handle('memory:get', () => this.memoryDto());
    ipcMain.handle('memory:add-term', (_event, input: { phrase: string; soundAlike?: string; alias?: string; language: string }) => {
      this.data.upsertTerm({
        id: randomUUID(),
        phrase: input.phrase,
        aliases: [input.alias].filter((value): value is string => Boolean(value)),
        pronunciations: [input.soundAlike].filter((value): value is string => Boolean(value)),
        language: normaliseMemoryLanguage(input.language),
        priority: 'high',
        notes: '',
        usageCount: 0,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });
      this.broadcast('memory:changed');
    });
    ipcMain.handle('memory:update-term', (_event, payload: { id: string; patch: Record<string, unknown> }) => {
      const existing = this.data.snapshot().terms.find((term) => term.id === payload.id);
      if (!existing) return;
      this.data.upsertTerm({ ...existing, ...(payload.patch as Partial<typeof existing>), id: existing.id, updatedAt: new Date().toISOString() });
      this.broadcast('memory:changed');
    });
    ipcMain.handle('memory:remove-term', (_event, id: string) => {
      this.data.removeTerm(id);
      this.broadcast('memory:changed');
    });
    ipcMain.handle('memory:add-replacement', (_event, input: { match: string; replacement: string; language: string }) => {
      this.data.upsertReplacement({
        id: randomUUID(),
        match: input.match,
        replacement: input.replacement,
        matchMode: 'wordBoundaryPhrase',
        language: normaliseMemoryLanguage(input.language),
        isEnabled: true,
        usageCount: 0,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });
      this.broadcast('memory:changed');
    });
    ipcMain.handle('memory:set-replacement-enabled', (_event, payload: { id: string; isEnabled: boolean }) => {
      this.data.setReplacementEnabled(payload.id, payload.isEnabled);
      this.broadcast('memory:changed');
    });
    ipcMain.handle('memory:remove-replacement', (_event, id: string) => {
      this.data.removeReplacement(id);
      this.broadcast('memory:changed');
    });
    ipcMain.handle('memory:add-snippet', (_event, input: { trigger: string; expansion: string; language: string }) => {
      this.data.upsertSnippet({
        id: randomUUID(),
        trigger: input.trigger,
        expansion: input.expansion,
        language: normaliseMemoryLanguage(input.language),
        isEnabled: true,
        usageCount: 0,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });
      this.broadcast('memory:changed');
    });
    ipcMain.handle('memory:remove-snippet', (_event, id: string) => {
      this.data.removeSnippet(id);
      this.broadcast('memory:changed');
    });
    ipcMain.handle('memory:accept-suggestion', (_event, id: string) => {
      const suggestion = this.data.snapshot().suggestions.find((entry) => entry.id === id);
      if (!suggestion) return;
      this.data.addSuggestion(suggestion);
      this.data.upsertReplacement({
        id: randomUUID(),
        match: suggestion.observed,
        replacement: suggestion.corrected,
        matchMode: 'wordBoundaryPhrase',
        language: 'auto',
        isEnabled: true,
        usageCount: 0,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      });
      this.data.removeSuggestion(id);
      this.broadcast('memory:changed');
    });
    ipcMain.handle('memory:dismiss-suggestion', (_event, id: string) => {
      this.data.removeSuggestion(id);
      this.broadcast('memory:changed');
    });

    ipcMain.handle('history:get', () => this.data.history);
    ipcMain.handle('history:remove', (_event, id: string) => {
      this.data.removeHistory(id);
      this.broadcast('history:changed');
    });
    ipcMain.handle('history:clear', () => {
      this.data.clearHistory();
      this.broadcast('history:changed');
    });
    ipcMain.handle('history:export-csv', async () => {
      const file = path.join(app.getPath('documents'), 'useful-voice-history.csv');
      const rows = [
        ['created', 'app', 'language', 'durationSeconds', 'text'],
        ...this.data.history.map((record) => [
          record.createdAt,
          record.appName,
          record.language,
          String(record.durationSeconds),
          record.text,
        ]),
      ];
      try {
        await fs.writeFile(file, rows.map((row) => row.map(csvCell).join(',')).join('\r\n'), 'utf8');
        return { ok: true, message: `Exported to ${file}` };
      } catch (error) {
        return { ok: false, message: `Could not export: ${(error as Error).message}` };
      }
    });

    ipcMain.handle('notes:get', () => this.data.notes);
    ipcMain.handle('notes:save', (_event, input: { id?: string; title: string; body: string }) => {
      const now = new Date().toISOString();
      const existing = input.id
        ? this.data.notes.find((note) => note.id === input.id)
        : undefined;
      const note: Note = {
        id: existing?.id ?? input.id ?? randomUUID(),
        title: input.title,
        body: input.body,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      };
      this.data.upsertNote(note);
      this.broadcast('notes:changed');
      return note;
    });
    ipcMain.handle('notes:delete', (_event, id: string) => {
      const removed = this.data.deleteNote(id);
      this.broadcast('notes:changed');
      return removed;
    });
    ipcMain.handle('notes:restore', (_event, payload: { id: string; title: string; body: string; createdAt?: string; updatedAt?: string }, index: number) => {
      const now = new Date().toISOString();
      this.data.restoreNote(
        {
          id: payload.id,
          title: payload.title,
          body: payload.body,
          createdAt: payload.createdAt ?? now,
          updatedAt: payload.updatedAt ?? now,
        },
        index,
      );
      this.broadcast('notes:changed');
    });

    ipcMain.handle('backup:export', async () => {
      const file = path.join(app.getPath('documents'), 'useful-voice-backup.json');
      try {
        await fs.writeFile(file, JSON.stringify(this.data.exportPayload(), null, 2), 'utf8');
        return { ok: true, message: `Backup written to ${file}` };
      } catch (error) {
        return { ok: false, message: `Could not write the backup: ${(error as Error).message}` };
      }
    });

    ipcMain.handle('backup:import', async () => {
      const file = path.join(app.getPath('documents'), 'useful-voice-backup.json');
      try {
        const raw = await fs.readFile(file, 'utf8');
        const parsed = JSON.parse(raw) as { payload?: unknown };
        const summary = this.data.importPayload((parsed.payload ?? parsed) as never);
        await this.data.flush();
        this.broadcast('memory:changed');
        const kept = summary.notesKeptLocal > 0 ? `, kept ${summary.notesKeptLocal} newer local notes` : '';
        return {
          ok: true,
          message: `Imported ${summary.termsInserted + summary.termsUpdated} words, `
            + `${summary.replacementsInserted + summary.replacementsUpdated} fixes, `
            + `${summary.snippetsInserted + summary.snippetsUpdated} snippets${kept}.`,
        };
      } catch (error) {
        return { ok: false, message: `Could not read the backup: ${(error as Error).message}` };
      }
    });

    ipcMain.handle('backup:export-csv', async (_event, kind: 'terms' | 'fixes') => {
      const file = path.join(
        app.getPath('documents'),
        kind === 'terms' ? 'useful-voice-words.csv' : 'useful-voice-fixes.csv',
      );
      const snapshot = this.data.memorySnapshot();
      const rows = kind === 'terms'
        ? [
            ['word', 'soundsLike', 'language'],
            ...snapshot.terms.map((term) => [term.phrase, term.pronunciations.join('; '), term.language]),
          ]
        : [
            ['heard', 'write'],
            ...snapshot.replacements.map((rule) => [rule.match, rule.replacement]),
          ];
      try {
        await fs.writeFile(file, rows.map((row) => row.map(csvCell).join(',')).join('\r\n'), 'utf8');
        return { ok: true, message: `Wrote ${rows.length - 1} rows to ${file}` };
      } catch (error) {
        return { ok: false, message: `Could not write the file: ${(error as Error).message}` };
      }
    });

    ipcMain.handle('backup:import-csv', async (_event, payload: { kind: 'terms' | 'fixes'; text: string }) => {
      const lines = payload.text.split(/\r?\n/).filter((line) => line.trim().length > 0);
      // Drop a header row when present, rather than importing "word,soundsLike"
      // as a dictionary entry.
      const start = /^(word|heard)\b/i.test(lines[0] ?? '') ? 1 : 0;
      let imported = 0;
      const invalid: string[] = [];
      const now = new Date().toISOString();

      for (const line of lines.slice(start)) {
        const cells = parseCsvLine(line);
        if (payload.kind === 'terms') {
          const phrase = (cells[0] ?? '').trim();
          if (phrase.length === 0) {
            invalid.push(line);
            continue;
          }
          const soundAlike = (cells[1] ?? '').trim();
          this.data.upsertTerm({
            id: randomUUID(),
            phrase,
            aliases: [],
            pronunciations: soundAlike.length > 0 ? [soundAlike] : [],
            language: 'auto',
            priority: 'high',
            notes: '',
            usageCount: 0,
            createdAt: now,
            updatedAt: now,
          });
          imported += 1;
        } else {
          const match = (cells[0] ?? '').trim();
          const replacement = (cells[1] ?? '').trim();
          if (match.length === 0 || replacement.length === 0) {
            invalid.push(line);
            continue;
          }
          this.data.upsertReplacement({
            id: randomUUID(),
            match,
            replacement,
            matchMode: 'wordBoundaryPhrase',
            language: 'auto',
            isEnabled: true,
            usageCount: 0,
            createdAt: now,
            updatedAt: now,
          });
          imported += 1;
        }
      }
      await this.data.flush();
      this.broadcast('memory:changed');
      const skipped = invalid.length > 0 ? ` ${invalid.length} row(s) were skipped as incomplete.` : '';
      return { ok: true, message: `Imported ${imported} row(s).${skipped}` };
    });

    ipcMain.handle('clipboard:write', (_event, text: string) => {
      clipboard.writeText(text);
    });

    ipcMain.handle('app:open-external', async (_event, url: string) => {
      // Only https, so a compromised renderer cannot launch arbitrary schemes.
      if (/^https:\/\//i.test(url)) await shell.openExternal(url);
    });

    ipcMain.handle('app:diagnostics', () => ({
      version: app.getVersion(),
      platform: `${process.platform} ${os.release()}`,
      logPath: this.diagnostics.path,
      recentErrors: this.diagnostics.recent(30),
    }));

    ipcMain.handle('app:save-status', () => ({
      ok: this.data.saveError === null && this.settings.saveError === null,
      message: this.data.saveError?.message ?? this.settings.saveError?.message,
    }));

    ipcMain.handle('app:quit', () => this.quit());
  }

  /**
   * Verify a key with the cheapest possible real request.
   *
   * A silent second-long clip is sent rather than a metadata-only call, because
   * the thing that actually breaks dictation is a key that authenticates but cannot
   * use the model — a scope problem that a `/projects` call would not reveal.
   */
  private async testApiKey(): Promise<{ ok: boolean; message: string }> {
    const key = this.settings.revealApiKey();
    if (!key) return { ok: false, message: 'No API key is set.' };

    try {
      const { encodeWav } = await import('../core/audio/wav.js');
      const silence = encodeWav(new Float32Array(16_000));
      await transcribeRequest({
        audio: silence,
        hint: { language: 'en', keyterms: [] },
        config: { apiKey: key, smartFormat: false },
        // One attempt: a credential check should report the rejection, not mask it
        // behind retry delays.
        maxAttempts: 1,
      });
      return { ok: true, message: 'The key works. You can dictate now.' };
    } catch (error) {
      return { ok: false, message: (error as Error).message };
    }
  }

  private buildApplicationMenu(): void {
    // A conventional menu bar, which Windows users expect. Without one, standard
    // shortcuts like Ctrl+C in a text field would not work.
    const template: Electron.MenuItemConstructorOptions[] = [
      {
        label: 'File',
        submenu: [
          { label: 'New note', accelerator: 'CmdOrCtrl+N', click: () => void this.openWindow('notes') },
          { type: 'separator' },
          { label: 'Quit', accelerator: 'Alt+F4', click: () => void this.quit() },
        ],
      },
      {
        label: 'Edit',
        submenu: [
          { role: 'undo' },
          { role: 'redo' },
          { type: 'separator' },
          { role: 'cut' },
          { role: 'copy' },
          { role: 'paste' },
          { role: 'selectAll' },
        ],
      },
      {
        label: 'Dictation',
        submenu: [
          { label: 'Start / stop', click: () => void this.toggleDictation() },
          { label: 'Cancel', click: () => void this.service.cancel() },
          { label: 'Retry last', click: () => void this.service.retryLast() },
          { label: 'Copy last transcript', click: () => this.copyLastTranscript() },
        ],
      },
      {
        label: 'View',
        submenu: [
          { role: 'reload' },
          { role: 'toggleDevTools' },
          { type: 'separator' },
          { role: 'resetZoom' },
          { role: 'zoomIn' },
          { role: 'zoomOut' },
        ],
      },
      {
        label: 'Help',
        submenu: [
          {
            label: 'Deepgram API keys',
            click: () => void shell.openExternal('https://console.deepgram.com/'),
          },
          {
            label: 'Open diagnostics log',
            click: () => void shell.showItemInFolder(this.diagnostics.path),
          },
          {
            label: 'Open data folder',
            click: () => void shell.openPath(app.getPath('userData')),
          },
        ],
      },
    ];
    Menu.setApplicationMenu(Menu.buildFromTemplate(template));
  }
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function csvCell(value: string): string {
  const text = value ?? '';
  return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function parseCsvLine(line: string): string[] {
  const cells: string[] = [];
  let current = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (inQuotes) {
      if (char === '"') {
        if (line[i + 1] === '"') {
          current += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        current += char as string;
      }
    } else if (char === '"') {
      inQuotes = true;
    } else if (char === ',') {
      cells.push(current);
      current = '';
    } else {
      current += char as string;
    }
  }
  cells.push(current);
  return cells;
}


/**
 * The Windows app identity.
 *
 * MUST equal `build.appId` in package.json. Windows derives taskbar grouping,
 * notification identity and the registry Run value used for launch-at-login from
 * this string, so a mismatch attributes the installer's login entry to a different
 * app than the one actually running. `tests/appIdentity.test.ts` reads both and
 * fails if they drift.
 */
export const APP_USER_MODEL_ID = 'ai.karko.usefulvoice';

/**
 * A headless startup check.
 *
 * Covers what neither the type system nor the unit tests can: that the preload
 * actually exposes its API to the renderer, that the renderer bundle loads and
 * paints under the app's CSP, and that the recorder view can host Web Audio.
 *
 * This exists because the two most dangerous Windows-side mistakes — a preload
 * emitted as ESM (Electron requires CommonJS for preloads) and a renderer bundle
 * containing an unresolvable import — both produce a perfectly normal-looking
 * window with a dead UI and no error visible anywhere.
 */
export interface SelfTestResult {
  ok: boolean;
  checks: Array<{ name: string; ok: boolean; detail: string }>;
}

export async function runSelfTest(): Promise<SelfTestResult> {
  const checks: SelfTestResult['checks'] = [];
  const record = (name: string, ok: boolean, detail: string): void => {
    checks.push({ name, ok, detail });
  };

  // The window loads the real renderer, which asks the main process for its data
  // on boot. Registering read-only stubs lets that boot complete, so the paint
  // check tests the real code path rather than a half-initialised page.
  const stubs: Record<string, unknown> = {
    'settings:get': {
      languagePin: 'en', formattingEnabled: true, silenceTimeoutSeconds: 30,
      maxRecordingSeconds: 600, recordingsToKeep: 5, soundEffectsEnabled: true,
      launchAtLogin: false, hotkey: { accelerator: 'Control+Alt+Space', pushToTalk: false },
      dictionaryBiasBudget: 100, hasApiKey: true,
    },
    'memory:get': {
      terms: [], replacements: [], snippets: [], suggestions: [],
      keytermReport: { used: 0, limit: 100, dropped: 0, rejected: 0 },
    },
    'history:get': [],
    'notes:get': [],
    'app:save-status': { ok: true },
  };
  for (const [channel, value] of Object.entries(stubs)) {
    ipcMain.handle(channel, () => value);
  }

  // 1. Core modules load, and the store round-trips through disk.
  try {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'uv-selftest-'));
    const file = path.join(directory, 'data.json');
    const store = new DataStore(file);
    const outcome = await store.load();
    store.upsertTerm({
      id: 'self-test',
      phrase: 'Kubernetes',
      aliases: [],
      pronunciations: ['kubernets'],
      language: 'auto',
      priority: 'high',
      notes: '',
      usageCount: 0,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    });
    const wrote = await store.flush();
    const reloaded = new DataStore(file);
    await reloaded.load();
    const roundTripped = reloaded.snapshot().terms.length === 1;
    record(
      'core data store',
      outcome.status === 'fresh' && wrote && roundTripped,
      `load=${outcome.status} wrote=${wrote} roundTripped=${roundTripped}`,
    );
    await fs.rm(directory, { recursive: true, force: true });
  } catch (error) {
    record('core data store', false, (error as Error).message);
  }

  // 2. The Deepgram keyterm ceiling holds for a dictionary much larger than a
  //    real one, which is the failure that would break every dictation at once.
  try {
    const { selectKeyterms } = await import('../core/memory/biasBuilder.js');
    const { TOKEN_BUDGET, estimateListTokens } = await import('../core/transcription/keytermBudget.js');
    const terms = Array.from({ length: 400 }, (_, index) => ({
      id: `t${index}`,
      phrase: `Term${index} With Several Words`,
      aliases: [],
      pronunciations: [],
      language: 'auto' as const,
      priority: 'normal' as const,
      notes: '',
      usageCount: index,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    }));
    const selection = selectKeyterms({ terms, replacements: [], snippets: [], language: 'auto', budget: 100 });
    const tokens = estimateListTokens(selection.terms);
    record(
      'keyterm budget enforced',
      tokens <= TOKEN_BUDGET,
      `${selection.terms.length} terms, ${tokens} tokens (budget ${TOKEN_BUDGET}), dropped ${selection.droppedCount}`,
    );
  } catch (error) {
    record('keyterm budget enforced', false, (error as Error).message);
  }

  // 3. The preload and the renderer must load together and expose the API.
  const probe = new BrowserWindow({
    show: false,
    width: 900,
    height: 640,
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'index.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  try {
    // Collect renderer errors so a silent failure is visible.
    probe.webContents.on('console-message', (_event, level, message) => {
      if (level >= 2) record('renderer console', false, message);
    });

    await probe.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'), {
      query: { view: 'main' },
    });

    const preloadProbe = (await probe.webContents.executeJavaScript(
      `({
        hasApi: typeof window.usefulVoice === 'object' && window.usefulVoice !== null,
        methodCount: window.usefulVoice ? Object.keys(window.usefulVoice).length : 0,
        hasToggle: typeof (window.usefulVoice && window.usefulVoice.toggleDictation) === 'function',
        // The data-change subscriptions. Their absence was a real bug (an open page
        // kept a stale list after a hotkey dictation), so their presence is asserted
        // rather than assumed.
        hasChangeEvents: ['onHistoryChanged', 'onMemoryChanged', 'onNotesChanged']
          .every((name) => typeof window.usefulVoice?.[name] === 'function'),
        nodeLeaked: typeof window.require !== 'undefined' || typeof window.process !== 'undefined',
      })`,
    )) as {
      hasApi: boolean;
      methodCount: number;
      hasToggle: boolean;
      hasChangeEvents: boolean;
      nodeLeaked: boolean;
    };

    // The count is checked against the documented boundary rather than a vague lower
    // bound: `tests/ipcContract.test.ts` pins this same number to the README, so a
    // channel added or lost anywhere fails one of the two.
    // 51 since the language picker hotkey added `onOpenLanguagePicker`. Kept in step
    // with the README by the comment below.
    const EXPECTED_API_METHODS = 51;
    record(
      'preload exposes API',
      preloadProbe.hasApi
        && preloadProbe.hasToggle
        && preloadProbe.hasChangeEvents
        && preloadProbe.methodCount === EXPECTED_API_METHODS,
      `${preloadProbe.methodCount} methods (expected ${EXPECTED_API_METHODS}), `
        + `toggle=${preloadProbe.hasToggle}, changeEvents=${preloadProbe.hasChangeEvents}`,
    );
    record(
      'no node integration leak',
      !preloadProbe.nodeLeaked,
      preloadProbe.nodeLeaked ? 'window.require/process reachable' : 'window is clean',
    );

    // The UI must actually paint, which also proves the bundle ran to completion.
    await new Promise((resolve) => setTimeout(resolve, 1500));
    const uiProbe = (await probe.webContents.executeJavaScript(
      `({
        navItems: document.querySelectorAll('.nav-item').length,
        shell: !!document.querySelector('.shell'),
        title: (document.querySelector('.stage-title') || {}).textContent || '',
        stats: document.querySelectorAll('.stat-value').length,
      })`,
    )) as { navItems: number; shell: boolean; title: string; stats: number };

    record(
      'renderer paints the shell',
      uiProbe.shell && uiProbe.navItems === 5 && uiProbe.title.length > 0,
      `shell=${uiProbe.shell} nav=${uiProbe.navItems} title="${uiProbe.title}" stats=${uiProbe.stats}`,
    );
  } catch (error) {
    record('renderer window', false, (error as Error).message);
  } finally {
    probe.destroy();
  }

  // 4. The recorder view loads, since capture depends on it.
  const recorder = new BrowserWindow({
    show: false,
    width: 400,
    height: 300,
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'index.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  try {
    await recorder.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'), {
      query: { view: 'recorder' },
    });
    const recorderProbe = (await recorder.webContents.executeJavaScript(
      `({
        hasApi: typeof window.usefulVoice === 'object',
        hasMediaDevices: !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia),
        hasAudioContext: typeof (window.AudioContext || window.webkitAudioContext) === 'function',
      })`,
    )) as { hasApi: boolean; hasMediaDevices: boolean; hasAudioContext: boolean };
    record(
      'recorder can host audio capture',
      recorderProbe.hasApi && recorderProbe.hasMediaDevices && recorderProbe.hasAudioContext,
      `api=${recorderProbe.hasApi} getUserMedia=${recorderProbe.hasMediaDevices} AudioContext=${recorderProbe.hasAudioContext}`,
    );
  } catch (error) {
    record('recorder window', false, (error as Error).message);
  } finally {
    recorder.destroy();
  }

  for (const channel of Object.keys(stubs)) {
    ipcMain.removeHandler(channel);
  }

  return { ok: checks.every((check) => check.ok), checks };
}

// `--self-test` runs the headless verification and exits, so a build can be checked
// without a human watching the screen.
if (process.argv.includes('--self-test')) {
  // The report path is taken from an explicit flag so it can be found again
  // afterwards, and written to a file as well as stdout because Electron detaches
  // a GUI process from the console on Windows -- a check nobody can read is worse
  // than no check.
  const reportFlag = process.argv.find((arg) => arg.startsWith('--report='));
  const reportPath = reportFlag
    ? reportFlag.slice('--report='.length)
    : path.join(app.getPath('temp'), 'useful-voice-self-test.txt');

  let finished = false;
  /**
   * Written synchronously on purpose.
   *
   * `app.exit()` terminates the process immediately without draining pending
   * asynchronous I/O, so an awaited `fs.writeFile` can be abandoned mid-flight --
   * which is exactly what happened here: the check ran, the report file was
   * created, and it stayed empty. A self-test whose result cannot be read is
   * useless, so the write is synchronous and its completion is verified.
   */
  const writeReport = (lines: string[]): void => {
    if (finished) return;
    finished = true;
    const report = lines.join('\n') + '\n';
    try {
      writeFileSync(reportPath, report, 'utf8');
    } catch (error) {
      process.stderr.write(`self-test could not write ${reportPath}: ${(error as Error).message}\n`);
    }
    process.stdout.write(report);
  };

  // A watchdog so a wedged check reports what it managed to verify instead of
  // hanging with no output at all.
  const watchdog = setTimeout(() => {
    writeReport(['FAIL  self-test did not finish within 45s']);
    app.exit(1);
  }, 45_000);
  watchdog.unref?.();

  app.whenReady().then(async () => {
    let result: { ok: boolean; checks: Array<{ name: string; ok: boolean; detail: string }> };
    try {
      result = await runSelfTest();
    } catch (error) {
      writeReport([`FAIL  self-test threw — ${(error as Error).message}`]);
      app.exit(1);
      return;
    }
    clearTimeout(watchdog);
    const lines = result.checks.map(
      (check) => `${check.ok ? 'PASS' : 'FAIL'}  ${check.name} — ${check.detail}`,
    );
    lines.push(result.ok ? 'SELF-TEST OK' : 'SELF-TEST FAILED');
    writeReport(lines);
    app.exit(result.ok ? 0 : 1);
  });
} else {
  const application = new UsefulVoiceApp();
  void application.start();
}

/**
 * Closing the last window must NOT quit: this is a tray-resident app.
 *
 * Registered for every mode, including `--self-test`. Electron quits automatically
 * when the last window closes and no handler is attached, which made the self-test
 * destroy its first probe window and then find itself unable to create the next
 * one (`ERR_FAILED`). Keeping the handler unconditional removes that ordering trap.
 */
app.on('window-all-closed', () => {
  // Intentionally empty.
});
