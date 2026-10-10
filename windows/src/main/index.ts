import { app, BrowserWindow, clipboard, globalShortcut, ipcMain, nativeTheme, shell, screen, Menu } from 'electron';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promises as fs, appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import os from 'node:os';

import { DataStore } from '../core/settings/dataStore.js';
import { planLoginItem, wasAutoStarted } from '../core/settings/autostart.js';
import { decideClipboardRestore, isProbablyVerifiable } from '../core/delivery/clipboardRestore.js';
import { pasteTargetMoved } from '../core/delivery/pasteTarget.js';
import {
  normaliseMemoryLanguage,
  type AppSettings,
  type DictationSource,
  type Note,
} from '../core/models.js';
import { selectKeyterms } from '../core/memory/biasBuilder.js';
import { HUD_EXIT_MS, HudModel, languageLabel, type HudFrame } from '../core/hudModel.js';
import { normaliseLanguageCode } from '../core/transcription/languages.js';
import {
  transcribe as transcribeRequest,
  type DeepgramConfig,
  type TranscriptionHint,
} from '../core/transcription/deepgramProvider.js';
import { SettingsStore } from './settingsStore.js';
import {
  applyAppearance,
  canvasColor,
  resolvedTheme,
  titleBarOverlayFor,
} from './theme.js';
import { RecorderBridge, validateCapture } from './recorderBridge.js';
import { TrayController } from './tray.js';
import { Announcer } from './announce.js';
import {
  DictationService,
  type DeliveryRequest,
  type DeliveryResult,
  type DictationStatus,
} from './dictationService.js';
import {
  Diagnostics,
  clipboardHoldsText,
  foregroundWindow,
  restoreForegroundWindow,
  pasteClipboard,
  playCue,
  restoreClipboard,
  snapshotClipboard,
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
/**
 * `--e2e` (Playwright suite only): windows are created hidden and no tray icon or
 * global hotkey is registered, so a test run never takes the screen, the menu bar
 * or a key combination from the person at the machine.
 */
const E2E = process.argv.includes('--e2e');
if (E2E) {
  // CI runners have no GPU; software rendering keeps hidden windows painting.
  app.disableHardwareAcceleration();
  // Window lifecycle in <userData>/e2e.log (a Windows GUI app's stdout is not
  // reliably piped), so a failed run says where it stopped.
  const e2eLog = (line: string): void => {
    try {
      appendFileSync(path.join(app.getPath('userData'), 'e2e.log'), `${new Date().toISOString()} ${line}\n`);
    } catch {
      // The log is a diagnostic aid only.
    }
  };
  e2eLog(`main start ${process.platform} ${process.versions.electron}`);
  app.on('ready', () => e2eLog('ready'));
  app.on('web-contents-created', (_event, contents) => {
    const tag = (): string => `${contents.id} ${contents.getURL() || '(blank)'}`;
    e2eLog(`created ${contents.id}`);
    contents.on('did-start-loading', () => e2eLog(`${tag()} start loading`));
    contents.on('did-finish-load', () => e2eLog(`${tag()} loaded`));
    contents.on('did-fail-load', (_e, code, description, url) => e2eLog(`${tag()} failed ${code} ${description} ${url}`));
    contents.on('render-process-gone', (_e, details) => e2eLog(`${tag()} renderer gone ${details.reason}`));
  });
  process.on('uncaughtException', (error) => e2eLog(`uncaught ${error.stack ?? error.message}`));
  process.on('unhandledRejection', (reason) => e2eLog(`unhandled ${String(reason)}`));
}

const CLIPBOARD_RESTORE_DELAY_MS = 700;

/**
 * The HUD window is a fixed transparent area, big enough for the widest state, so the
 * capsule morphs in CSS and the window never resizes. The capsule is 40 px tall and
 * sits 32 px above the taskbar; the rest of the height is room for its shadow and its
 * 8 px rise.
 */
const HUD_WIDTH = 520;
const HUD_HEIGHT = 96;
const HUD_CAPSULE_HEIGHT = 40;
const HUD_SHADOW_ROOM = 28;
const HUD_BOTTOM_GAP = 32;

/** The language picker panel is 300 by 400; its window adds 24 px all round for the pop shadow. */
const PICKER_WIDTH = 348;
const PICKER_HEIGHT = 448;
const PICKER_MARGIN = 24;
/** The picker floats 10 px above where the capsule sits. */
const PICKER_GAP = 10;
/** Cap on handing focus back: a cold PowerShell with Add-Type is slow, and the picker is invisible meanwhile. */
const PICKER_RESTORE_TIMEOUT_MS = 3000;

/** Keep the HUD window's capsule inside a display's work area. */
function clampHud(area: Electron.Rectangle, x: number, y: number): { x: number; y: number } {
  return {
    x: Math.min(Math.max(area.x, x), area.x + area.width - HUD_WIDTH),
    y: Math.min(Math.max(area.y, y), area.y + area.height - HUD_SHADOW_ROOM - HUD_CAPSULE_HEIGHT),
  };
}

class UsefulVoiceApp {
  private settings!: SettingsStore;
  private data!: DataStore;
  private tray: TrayController | null = null;
  private recorderWindow: BrowserWindow | null = null;
  private mainWindow: BrowserWindow | null = null;
  private hudWindow: BrowserWindow | null = null;
  private pickerWindow: BrowserWindow | null = null;
  private hudModel!: HudModel;
  private announcer!: Announcer;
  /** The latest view, sent to the HUD window as soon as its page has loaded. */
  private hudFrame: HudFrame | null = null;
  private hudHideTimer: NodeJS.Timeout | null = null;
  /** Where the user left the HUD, per display, as an offset from its default spot. */
  private hudOffsets: Record<string, { dx: number; dy: number }> = {};
  private hudDrag: {
    bounds: Electron.Rectangle;
    x: number;
    y: number;
    last: { display: Electron.Display; origin: { x: number; y: number } } | null;
  } | null = null;
  /** The window the current hotkey recording will paste into, so the picker need not ask Windows. */
  private recordingHandle: number | undefined;
  private pickerClosing = false;
  /** The window that was in front when the picker opened, to hand focus back to on close. */
  private pickerReturnTo: number | null = null;
  private pickerOpening = false;
  /** The app the current recording will paste into (a hotkey dictation only). */
  private recordingTarget: string | undefined;
  private service!: DictationService;
  private diagnostics!: Diagnostics;

  /** Talks to the hidden recorder window: start acks, tokens, discard on cancel. */
  private recorder!: RecorderBridge;

  /** Whether Esc is registered as a global shortcut. It is, only while recording. */
  private escapeRegistered = false;

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

    // Before any window exists, so the first paint is already in the right theme.
    applyAppearance(this.settings.all.appearance);
    nativeTheme.on('updated', () => this.syncTheme());

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

    this.loadHudPositions();
    this.createRecorderWindow();
    this.announcer = new Announcer((text, urgency) => this.sendAnnouncement(text, urgency));
    this.hudModel = new HudModel((frame) => this.onHudFrame(frame));
    this.service = this.buildService();
    this.tray = new TrayController({
      // The tray is part of the app, not the app the user is dictating into, so a
      // dictation started here is saved and copied like one started in the window.
      onToggleDictation: () => void this.toggleDictation('window'),
      onOpenWindow: (page) => this.openWindow(page),
      onQuit: () => void this.quit(),
      onRetry: () => void this.service.retryLast(),
      onCopyLast: () => this.copyLastTranscript(),
      onCancel: () => void this.cancelDictation(),
      onSetLanguage: (code) => this.setLanguage(code),
      onSetFormatting: (enabled) => this.setFormatting(enabled),
    });
    if (!E2E) this.tray.create();
    this.syncTray();

    this.registerHotkey();
    this.registerIpc();
    this.buildApplicationMenu();

    const settings = this.settings.all;
    // Re-asserted on every start, not only when the setting changes: an update can
    // rewrite the entry, and Windows' own Startup Apps page can disable it behind
    // the app's back, so the stored preference is the thing to trust.
    this.applyLoginItem(settings.launchAtLogin, 'startup');
    // The suite drives the main window, which a normal launch leaves to the tray.
    if (E2E) void this.openWindow('stream');
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
      this.diagnostics.log('login', `${context}: could not update the login entry: ${(error as Error).message}`);
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
      query: { view: 'recorder', theme: resolvedTheme() },
    });
  }

  /**
   * Show the main window on `page`. Never rejects: callers fire and forget, and the
   * window can be closed at any point while it loads or is sent the page.
   */
  private async openWindow(page: string, anchor?: string): Promise<void> {
    try {
      await this.openWindowUnguarded(page, anchor);
    } catch (error) {
      this.diagnostics.log('window', `could not open ${page}: ${(error as Error).message}`);
    }
  }

  private async openWindowUnguarded(page: string, anchor?: string): Promise<void> {
    if (page === 'hud') return;

    if (!this.mainWindow || this.mainWindow.isDestroyed()) {
      const theme = resolvedTheme();
      this.mainWindow = new BrowserWindow({
        width: 1040,
        height: 720,
        minWidth: 820,
        minHeight: 560,
        backgroundColor: canvasColor(theme),
        title: 'Useful Voice',
        show: !E2E,
        // No native title bar: the page draws a 32px canvas strip, and Windows draws the
        // caption buttons over it. Without a native frame there is no menu bar, so the
        // menu's actions live in the tray and in Settings (see buildApplicationMenu).
        titleBarStyle: 'hidden',
        titleBarOverlay: titleBarOverlayFor(theme),
        webPreferences: {
          preload: path.join(__dirname, '../preload/index.js'),
          contextIsolation: true,
          nodeIntegration: false,
        },
      });
      this.mainWindow.setMenuBarVisibility(false);
      this.mainWindow.on('closed', () => {
        this.mainWindow = null;
      });
      // The hidden menu still owns the accelerators on Windows, but Ctrl+N is the one
      // app-specific shortcut, so it is also handled here and cannot be lost with the
      // frame.
      this.mainWindow.webContents.on('before-input-event', (event, input) => {
        if (input.type === 'keyDown' && input.control && !input.alt && !input.shift && input.key.toLowerCase() === 'n') {
          event.preventDefault();
          void this.openWindow('notes');
        }
      });
      const created = this.mainWindow;
      await created.loadFile(path.join(__dirname, '../renderer/index.html'), {
        query: { view: 'main', theme },
      });
      if (!created.isDestroyed()) created.webContents.on('did-finish-load', () => this.pushAll());
    } else if (!E2E) {
      this.mainWindow.show();
      this.mainWindow.focus();
    }
    // It may have been closed while it was loading.
    const target = this.mainWindow;
    if (target && !target.isDestroyed()) target.webContents.send('app:navigate', page, anchor);
  }

  /**
   * The HUD window: a fixed transparent area at the bottom centre of the display under
   * the pointer, 32 px above the taskbar. Every state is drawn inside it by the renderer.
   *
   * Deliberately not focusable: it must never steal focus from the app the user is
   * dictating into, which would make the paste land in the wrong place - the bug
   * that made the macOS HUD a panel with `becomesKeyOnlyIfNeeded`. Clicks pass through
   * the transparent margin; the renderer says when the pointer is over the capsule.
   */
  private ensureHudWindow(): BrowserWindow {
    if (this.hudWindow && !this.hudWindow.isDestroyed()) return this.hudWindow;
    const window = new BrowserWindow({
      width: HUD_WIDTH,
      height: HUD_HEIGHT,
      frame: false,
      resizable: false,
      movable: false,
      focusable: false,
      skipTaskbar: true,
      alwaysOnTop: true,
      transparent: true,
      hasShadow: false,
      show: false,
      webPreferences: {
        preload: path.join(__dirname, '../preload/index.js'),
        contextIsolation: true,
        nodeIntegration: false,
      },
    });
    window.setIgnoreMouseEvents(true, { forward: true });
    void window.loadFile(path.join(__dirname, '../renderer/index.html'), {
      query: { view: 'hud', theme: resolvedTheme() },
    });
    window.webContents.on('did-finish-load', () => this.pushHudFrame());
    window.on('closed', () => {
      this.hudWindow = null;
    });
    this.hudWindow = window;
    return window;
  }

  /**
   * Where the HUD window sits on a display: bottom centre, 32 px above the taskbar,
   * plus wherever the user last dragged it on that display.
   */
  private hudOrigin(display: Electron.Display): { x: number; y: number } {
    const area = display.workArea;
    const offset = this.hudOffsets[String(display.id)] ?? { dx: 0, dy: 0 };
    return clampHud(
      area,
      Math.round(area.x + (area.width - HUD_WIDTH) / 2) + offset.dx,
      area.y + area.height - HUD_BOTTOM_GAP - HUD_CAPSULE_HEIGHT - HUD_SHADOW_ROOM + offset.dy,
    );
  }

  private placeHud(window: BrowserWindow): void {
    const origin = this.hudOrigin(screen.getDisplayNearestPoint(screen.getCursorScreenPoint()));
    window.setBounds({ ...origin, width: HUD_WIDTH, height: HUD_HEIGHT });
  }

  /** The user is dragging the capsule: the window follows the pointer. */
  private onHudDrag(phase: unknown, x: unknown, y: unknown): void {
    const window = this.hudWindow;
    if (!window || window.isDestroyed()) return;
    if (phase === 'end') {
      // The release (or a cancelled pointer, which reports 0,0) carries no position of its
      // own: the capsule stays where the last move put it, and a press that never moved
      // changes and saves nothing.
      const finished = this.hudDrag;
      this.hudDrag = null;
      if (finished?.last) this.rememberHudPosition(finished.last.display, finished.last.origin);
      return;
    }
    if (typeof x !== 'number' || typeof y !== 'number' || !Number.isFinite(x) || !Number.isFinite(y)) return;
    if (phase === 'start') {
      this.hudDrag = { bounds: window.getBounds(), x, y, last: null };
      return;
    }
    const drag = this.hudDrag;
    if (!drag) return;
    const nextX = drag.bounds.x + Math.round(x - drag.x);
    const nextY = drag.bounds.y + Math.round(y - drag.y);
    const display = screen.getDisplayNearestPoint({ x: nextX + HUD_WIDTH / 2, y: nextY + HUD_HEIGHT / 2 });
    const origin = clampHud(display.workArea, nextX, nextY);
    window.setBounds({ ...origin, width: HUD_WIDTH, height: HUD_HEIGHT });
    drag.last = { display, origin };
  }

  /** Stored as an offset from the default spot, so a resolution or taskbar change keeps it sensible. */
  private rememberHudPosition(display: Electron.Display, origin: { x: number; y: number }): void {
    const area = display.workArea;
    this.hudOffsets[String(display.id)] = {
      dx: origin.x - Math.round(area.x + (area.width - HUD_WIDTH) / 2),
      dy: origin.y - (area.y + area.height - HUD_BOTTOM_GAP - HUD_CAPSULE_HEIGHT - HUD_SHADOW_ROOM),
    };
    try {
      writeFileSync(this.hudPositionFile(), JSON.stringify(this.hudOffsets), 'utf8');
    } catch (error) {
      this.diagnostics.log('hud', `could not save the HUD position: ${(error as Error).message}`);
    }
  }

  private hudPositionFile(): string {
    return path.join(app.getPath('userData'), 'hud-position.json');
  }

  private loadHudPositions(): void {
    let raw: string;
    try {
      raw = readFileSync(this.hudPositionFile(), 'utf8');
    } catch (error) {
      // No file yet is the normal first run.
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
        this.diagnostics.log('hud', `could not read the HUD position: ${(error as Error).message}`);
      }
      return;
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, { dx?: unknown; dy?: unknown }>;
      for (const [id, offset] of Object.entries(parsed)) {
        if (typeof offset?.dx === 'number' && typeof offset?.dy === 'number') {
          this.hudOffsets[id] = { dx: offset.dx, dy: offset.dy };
        }
      }
    } catch (error) {
      this.diagnostics.log('hud', `ignored a damaged HUD position file: ${(error as Error).message}`);
    }
  }

  /**
   * A new HUD view (or none). The window draws only the latest one, so a stale view can
   * never be left on screen, and a persistent one is gone when the next dictation starts.
   */
  private onHudFrame(frame: HudFrame | null): void {
    this.hudFrame = frame;
    if (this.hudHideTimer) {
      clearTimeout(this.hudHideTimer);
      this.hudHideTimer = null;
    }
    if (frame) {
      const window = this.ensureHudWindow();
      if (!window.isVisible()) {
        this.placeHud(window);
        // Back to click-through: a button from the last view may have left it switched off.
        window.setIgnoreMouseEvents(true, { forward: true });
        window.showInactive();
      }
    } else if (this.hudWindow && !this.hudWindow.isDestroyed()) {
      // After the exit animation has played.
      this.hudHideTimer = setTimeout(() => {
        this.hudHideTimer = null;
        if (this.hudWindow && !this.hudWindow.isDestroyed()) this.hudWindow.hide();
      }, HUD_EXIT_MS + 60);
    }
    this.pushHudFrame();
    this.announcer.hud(frame);
  }

  private pushHudFrame(): void {
    const window = this.hudWindow;
    if (!window || window.isDestroyed() || window.webContents.isLoading()) return;
    window.webContents.send('hud:view', this.hudFrame);
  }

  /**
   * Speak a line to a screen reader. Electron has no UI Automation notification API, so
   * the line goes to a live region in the window the user is in: the main window when it
   * has focus, the HUD window otherwise (see `announce.ts`).
   */
  private sendAnnouncement(text: string, urgency: 'polite' | 'assertive'): void {
    const main = this.mainWindow;
    const target = main && !main.isDestroyed() && main.isFocused() ? main : this.hudWindow;
    if (!target || target.isDestroyed()) return;
    const send = (): void => target.webContents.send('app:announce', { text, urgency });
    if (target.webContents.isLoading()) target.webContents.once('did-finish-load', send);
    else send();
  }

  /** What a HUD button asked for. */
  private async onHudAction(action: unknown): Promise<void> {
    switch (action) {
      case 'dismiss':
        this.hudModel.dismiss();
        return;
      case 'retry':
        this.hudModel.dismiss();
        await this.service.retryLast();
        return;
      case 'openMicrophoneSettings':
        this.hudModel.dismiss();
        await shell.openExternal('ms-settings:privacy-microphone').catch((error: Error) =>
          this.diagnostics.log('hud', `could not open the microphone settings: ${error.message}`),
        );
        return;
      case 'openEngineSettings':
        this.hudModel.dismiss();
        await this.openWindow('settings', 'engine');
        return;
      default:
        this.diagnostics.log('hud', `ignored an unknown HUD action: ${String(action)}`);
    }
  }

  /**
   * The language picker: its own focusable frameless window, because the search field has
   * to take keys and a window of the main app would have to be pulled forward for that.
   * It opens 10 px above where the capsule sits (wherever the user left it). The window
   * that was in front is recorded before the picker takes focus and brought back when the
   * picker closes on a choice, Esc or the hotkey. A click on another window closes it too,
   * and then that window is already where the user wants focus, so nothing is restored.
   */
  private openLanguagePicker(): void {
    if (this.pickerWindow && !this.pickerWindow.isDestroyed() && this.pickerWindow.isVisible()) {
      this.closeLanguagePicker(true);
      return;
    }
    if (this.pickerOpening) return;
    this.pickerOpening = true;
    const stateAtPress = this.service.currentState;
    void (async () => {
      // Before the picker exists on screen: afterwards the foreground window would be the
      // picker. During a hotkey recording the window in front was captured when it started,
      // so there is nothing to ask Windows (a PowerShell spawn, up to 1,5 s).
      const known = stateAtPress === 'recording' ? this.recordingHandle : undefined;
      const front = known === undefined ? await foregroundWindow() : { handle: known };
      // The state moved on while that ran (recording stopped): the picker would open over
      // transcribing or delivering and take the foreground the paste needs.
      if (this.service.currentState !== stateAtPress) return;
      this.pickerReturnTo = front ? front.handle : null;
      const existing = this.pickerWindow && !this.pickerWindow.isDestroyed() ? this.pickerWindow : null;
      const window = existing ?? this.createPickerWindow();
      const display = screen.getDisplayNearestPoint(screen.getCursorScreenPoint());
      const origin = this.hudOrigin(display);
      const area = display.workArea;
      const capsuleTop = origin.y + HUD_HEIGHT - HUD_SHADOW_ROOM - HUD_CAPSULE_HEIGHT;
      window.setBounds({
        x: Math.min(
          Math.max(area.x, Math.round(origin.x + HUD_WIDTH / 2 - PICKER_WIDTH / 2)),
          area.x + area.width - PICKER_WIDTH,
        ),
        y: Math.max(area.y, capsuleTop - PICKER_GAP + PICKER_MARGIN - PICKER_HEIGHT),
        width: PICKER_WIDTH,
        height: PICKER_HEIGHT,
      });
      // The picker's own Esc must reach it, so the global Esc (cancel) steps aside while it is open.
      const reveal = (): void => {
        if (window.isDestroyed()) return;
        window.show();
        window.focus();
        window.webContents.focus();
        this.syncEscapeShortcut(this.service.currentState === 'recording');
        // A fresh page opens itself when it loads; a kept one is told to reset and refocus.
        if (existing) window.webContents.send('app:openLanguagePicker');
      };
      if (window.webContents.isLoading()) window.webContents.once('did-finish-load', reveal);
      else reveal();
    })()
      .catch((error: Error) => this.diagnostics.log('hud', `could not open the language picker: ${error.message}`))
      .finally(() => {
        this.pickerOpening = false;
      });
  }

  private createPickerWindow(): BrowserWindow {
    const window = new BrowserWindow({
      width: PICKER_WIDTH,
      height: PICKER_HEIGHT,
      frame: false,
      resizable: false,
      movable: false,
      minimizable: false,
      maximizable: false,
      fullscreenable: false,
      skipTaskbar: true,
      alwaysOnTop: true,
      transparent: true,
      hasShadow: false,
      show: false,
      webPreferences: {
        preload: path.join(__dirname, '../preload/index.js'),
        contextIsolation: true,
        nodeIntegration: false,
      },
    });
    void window.loadFile(path.join(__dirname, '../renderer/index.html'), {
      query: { view: 'hud', panel: 'language', theme: resolvedTheme() },
    });
    window.webContents.on('before-input-event', (event) => {
      if (this.pickerClosing) event.preventDefault();
    });
    // A click anywhere else dismisses it, like a menu.
    window.on('blur', () => this.closeLanguagePicker(false));
    window.on('closed', () => {
      this.pickerWindow = null;
      this.syncEscapeShortcut(this.service.currentState === 'recording');
    });
    this.pickerWindow = window;
    return window;
  }

  /** `restoreFocus`: hand focus back to the window that was in front when the picker opened. */
  private closeLanguagePicker(restoreFocus: boolean): void {
    const window = this.pickerWindow;
    if (!window || window.isDestroyed() || !window.isVisible() || this.pickerClosing) return;
    const target = this.pickerReturnTo;
    this.pickerReturnTo = null;
    const finish = (): void => {
      this.pickerClosing = false;
      if (!window.isDestroyed()) window.hide();
      this.syncEscapeShortcut(this.service.currentState === 'recording');
    };
    if (!restoreFocus || target === null) {
      finish();
      return;
    }
    // Windows only lets the foreground app hand the foreground to another window, so the
    // restore runs while the picker is still in front. It is made invisible and click-through
    // first, so it looks closed at once, and hidden when the restore has finished. The
    // script leaves things alone when the user clicked elsewhere in the meantime.
    this.pickerClosing = true;
    window.setOpacity(0);
    window.setIgnoreMouseEvents(true);
    // Still the foreground window until the restore lands, but invisible: it takes no keys,
    // and the global Esc (cancel) is registered again at once.
    this.syncEscapeShortcut(this.service.currentState === 'recording');
    void restoreForegroundWindow(target, {
      onlyIfForeground: window.getNativeWindowHandle().readUInt32LE(0),
      timeoutMs: PICKER_RESTORE_TIMEOUT_MS,
    })
      .then((ok) => {
        if (!ok) this.diagnostics.log('hud', 'focus was not returned to the window the picker was opened over');
      })
      .finally(() => {
        if (!window.isDestroyed()) {
          window.setOpacity(1);
          window.setIgnoreMouseEvents(false);
        }
        finish();
      });
  }

  /** Switch the spoken language. It applies to a recording in progress: it is read at stop. */
  private setLanguage(code: string): void {
    const language = normaliseLanguageCode(code);
    this.settings.update({ languagePin: language });
    this.broadcast('settings:changed');
    this.syncTray();
    this.hudModel.language(languageLabel(language));
  }

  private setFormatting(enabled: boolean): void {
    this.settings.update({ formattingEnabled: enabled });
    this.broadcast('settings:changed');
    this.syncTray();
  }

  /** Everything the tray menu shows, read from where it lives. */
  private syncTray(): void {
    const state = this.service?.currentState ?? 'idle';
    this.tray?.setState({
      recording: state === 'recording',
      transcribing: state === 'transcribing' || state === 'delivering',
      canRetry: this.service?.canRetry ?? false,
      // Any finished dictation can be copied again, not only one that failed.
      canCopyLast: (this.data?.history.length ?? 0) > 0,
      hotkeyLabel: this.settings.all.hotkey.accelerator,
      languagePin: this.settings.all.languagePin,
      formattingEnabled: this.settings.all.formattingEnabled,
      insertingInto: state === 'recording' ? this.recordingTarget : undefined,
    });
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
    if (E2E) return;
    globalShortcut.unregisterAll();
    // `unregisterAll` also drops Esc, so put it back if a recording is running.
    this.escapeRegistered = false;
    this.syncEscapeShortcut(this.service?.currentState === 'recording');
    const accelerator = this.settings.all.hotkey.accelerator;
    // The tray's "Start dictation (...)" line must show the hotkey from the first
    // menu open and after it is changed, not only after the next status change.
    this.syncTray();
    if (accelerator.trim().length === 0) {
      this.diagnostics.log('hotkey', 'no hotkey configured');
      return;
    }
    // A failed registration is a real, user-visible problem: another app already
    // owns the combination, so dictation would silently never start.
    const ok = globalShortcut.register(accelerator, () => void this.toggleDictation('hotkey'));
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

  // ---- dictation ---------------------------------------------------------

  private buildService(): DictationService {
    this.recorder = new RecorderBridge({
      send: (channel, payload) => {
        if (this.recorderWindow && !this.recorderWindow.isDestroyed()) {
          this.recorderWindow.webContents.send(channel, payload);
        }
      },
      // The microphone failed while recording (unplugged, access revoked).
      onUnclaimedError: (error) =>
        void this.service
          .recorderFailed(error)
          .catch((failure: unknown) =>
            this.diagnostics.log('dictation', `could not end the recording after a recorder error: ${(failure as Error).message}`),
          ),
    });
    return new DictationService({
      recorder: this.recorder,
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
      sink: { deliver: (request) => this.deliver(request) },
      settings: () => this.settings.all,
      memory: () => this.data.memorySnapshot(),
      apiKey: async () => this.settings.revealApiKey(),
      onStatus: (status) => this.handleStatus(status),
      // Before the idle status, so a window can show its done line before it resets.
      onOutcome: (outcome) => {
        this.hudModel.outcome(outcome);
        this.broadcast('dictation:outcome', outcome);
      },
      onTelemetry: (telemetry) => {
        this.hudModel.telemetry(telemetry);
        this.sendToMainAndHud('dictation:telemetry', telemetry);
      },
      onDiagnostic: (category, message) => this.diagnostics.log(category, message),
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

  private handleStatus(status: DictationStatus): void {
    this.broadcast('dictation:state', status);
    this.recordingTarget = status.state === 'recording' ? status.targetApp : undefined;
    this.syncTray();
    this.syncEscapeShortcut(status.state === 'recording');
    // The HUD follows every state, errors included: one model decides what it shows.
    this.hudModel.status(status);
    // Leaving the recording state hands the paste to whatever is in front, so a picker that
    // is still open would be the foreground window and take it.
    if (status.state === 'transcribing' || status.state === 'delivering') this.closeLanguagePicker(true);

    if (status.state === 'recording') {
      void playCue('start').catch(() => undefined);
    } else if (status.state === 'error') {
      this.diagnostics.log('dictation', status.message ?? 'error');
      void playCue('error').catch(() => undefined);
    }
  }

  /**
   * Start or stop a dictation from `source`.
   *
   * Only a hotkey start needs the foreground window: that is the app its text is
   * pasted into. A window start pastes nothing, so it records no target at all.
   */
  private async toggleDictation(source: DictationSource): Promise<void> {
    let targetApp: string | undefined;
    let targetHandle: number | undefined;
    if (this.service.currentState === 'idle' || this.service.currentState === 'error') this.recordingHandle = undefined;
    if (source === 'hotkey' && (this.service.currentState === 'idle' || this.service.currentState === 'error')) {
      // Capture which app is focused NOW, before recording. By the time the
      // transcript is ready the user may have clicked elsewhere, and pasting into
      // the wrong window is worse than not pasting at all.
      const target = await foregroundWindow();
      targetApp = target ? target.title || target.processName : undefined;
      targetHandle = target?.handle;
      this.recordingHandle = targetHandle;
    }
    await this.service.toggle({ source, targetApp, targetHandle });
    void this.data.flush();
  }

  /**
   * Esc cancels a recording, and is a global shortcut only while one is running.
   * Registered for the whole session it would swallow Esc in every other app.
   */
  private syncEscapeShortcut(recording: boolean): void {
    // The language picker needs Esc for itself while it is open.
    // A picker that is closing is already gone for the user, so Esc is theirs to cancel with again.
    const pickerOpen =
      this.pickerWindow !== null && !this.pickerWindow.isDestroyed() && this.pickerWindow.isVisible() && !this.pickerClosing;
    recording = recording && !pickerOpen;
    if (recording && !this.escapeRegistered) {
      this.escapeRegistered = globalShortcut.register('Escape', () => void this.cancelDictation());
      if (!this.escapeRegistered) this.diagnostics.log('hotkey', 'could not register Escape');
    } else if (!recording && this.escapeRegistered) {
      globalShortcut.unregister('Escape');
      this.escapeRegistered = false;
    }
  }

  /**
   * Cancel whatever is running. During delivery the sink stops before the paste if it
   * still can; a paste that already went out is not undone, and the dictation finishes
   * as delivered (the user can still press Ctrl+Z in the app).
   */
  private async cancelDictation(): Promise<void> {
    await this.service.cancel();
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
  private async deliver(request: DeliveryRequest): Promise<DeliveryResult> {
    const { text, mode, targetApp } = request;
    // A cancel that arrived before anything touched the clipboard stops here, on every
    // path: copy, moved window and paste alike.
    const cancelled: DeliveryResult = { delivered: false, clipboardFallback: false, cancelled: true };
    if (request.signal?.aborted) return cancelled;
    if (mode === 'copy') {
      // Nothing is pasted, so there is nothing to confirm and nothing to restore: the
      // dictation simply becomes the clipboard.
      clipboard.writeText(text);
      return { delivered: true, clipboardFallback: false };
    }
    const target = await foregroundWindow();
    if (request.signal?.aborted) return cancelled;
    if (pasteTargetMoved(request.targetHandle, target)) {
      // The user stopped from somewhere else (the dock, so Useful Voice is in front) or
      // clicked away: a paste would land in the wrong window. Leave it on the clipboard.
      this.diagnostics.log('delivery', 'start window is no longer in front; copied instead of pasting');
      clipboard.writeText(text);
      return { delivered: false, clipboardFallback: true };
    }
    const snapshot = snapshotClipboard();

    clipboard.writeText(text);

    // The last point at which a cancel can still stop the paste. After this line the
    // keystroke is sent and the dictation is delivered whatever the user does next.
    if (request.signal?.aborted) {
      this.restoreSnapshot(snapshot);
      return cancelled;
    }
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

  /** The newest dictation still in the history, so a deleted one is never copied back. */
  private copyLastTranscript(): void {
    const newest = this.data.history[0];
    if (!newest) return;
    clipboard.writeText(newest.text);
  }

  // ---- windows and IPC ---------------------------------------------------

  /**
   * Bring everything the OS draws in line with the resolved theme, and tell the pages.
   *
   * Runs on `nativeTheme` 'updated', which fires both when the user changes the
   * Appearance setting (`themeSource`) and when Windows flips between light and dark
   * while the setting is System.
   */
  private syncTheme(): void {
    const theme = resolvedTheme();
    const window = this.mainWindow;
    if (window && !window.isDestroyed()) {
      window.setBackgroundColor(canvasColor(theme));
      // Documented for win32 and linux only, where the overlay exists.
      if (process.platform !== 'darwin') window.setTitleBarOverlay(titleBarOverlayFor(theme));
    }
    this.broadcast('app:theme', theme);
  }

  private broadcast(channel: string, payload?: unknown): void {
    for (const window of [this.mainWindow, this.recorderWindow, this.hudWindow, this.pickerWindow]) {
      if (window && !window.isDestroyed()) {
        window.webContents.send(channel, payload);
      }
    }
  }

  /** For live data the hidden recorder window has no use for. */
  private sendToMainAndHud(channel: string, payload: unknown): void {
    for (const window of [this.mainWindow, this.hudWindow]) {
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
    // Only the hidden recorder window may talk to the recorder bridge: a message from any
    // other renderer could otherwise end or replace a live recording.
    const fromRecorder = (event: Electron.IpcMainEvent | Electron.IpcMainInvokeEvent): boolean =>
      this.recorderWindow !== null &&
      !this.recorderWindow.isDestroyed() &&
      event.sender === this.recorderWindow.webContents;

    ipcMain.handle('audio:started', (event, token: unknown) => {
      if (!fromRecorder(event) || typeof token !== 'string') return;
      this.recorder.handleStarted(token);
    });

    ipcMain.handle('audio:captured', (event, token: unknown, wav: unknown, meta: unknown) => {
      if (!fromRecorder(event) || typeof token !== 'string') return;
      const captured = validateCapture(wav, meta);
      if (captured instanceof Error) {
        this.diagnostics.log('recorder', captured.message);
        this.recorder.handleError(token, captured.message);
        return;
      }
      this.recorder.handleCaptured(token, captured);
    });

    ipcMain.handle('audio:error', (event, message: unknown, token: unknown) => {
      // An untagged error cannot be tied to a recording, so it is not acted on.
      if (!fromRecorder(event) || typeof token !== 'string' || typeof message !== 'string') return;
      this.recorder.handleError(token, message);
    });

    ipcMain.on('audio:level', (event, level: unknown) => {
      // Only the recorder window measures the microphone, and only a number is a level.
      if (!fromRecorder(event) || typeof level !== 'number' || !Number.isFinite(level)) return;
      if (this.hudWindow && !this.hudWindow.isDestroyed()) {
        this.hudWindow.webContents.send('hud:level', level);
      }
      // The same samples feed the silence watchdog and the window's live telemetry.
      this.service.reportLevel(level);
    });

    // Every renderer button is inside the app, so a toggle from here is a window
    // dictation. The renderer cannot ask for a paste: only the hotkey does that.
    ipcMain.handle('dictation:toggle', () => this.toggleDictation('window'));
    ipcMain.handle('dictation:cancel', () => this.cancelDictation());
    ipcMain.handle('dictation:retry', () => this.service.retryLast());
    ipcMain.handle('dictation:copyLast', () => this.copyLastTranscript());

    // The HUD window ignores the mouse except over the capsule.
    ipcMain.on('hud:pointer', (event, overCapsule: boolean) => {
      const window = this.hudWindow;
      if (!window || window.isDestroyed() || event.sender !== window.webContents) return;
      if (overCapsule === true) window.setIgnoreMouseEvents(false);
      else window.setIgnoreMouseEvents(true, { forward: true });
    });
    ipcMain.on('hud:drag', (event, phase: unknown, x: unknown, y: unknown) => {
      if (event.sender !== this.hudWindow?.webContents) return;
      this.onHudDrag(phase, x, y);
    });
    ipcMain.handle('hud:action', (_event, action: unknown) => this.onHudAction(action));
    ipcMain.handle('app:picker-choose', (_event, value: unknown) => {
      if (typeof value !== 'string') return;
      this.closeLanguagePicker(true);
      this.setLanguage(value);
    });
    ipcMain.handle('app:picker-close', () => this.closeLanguagePicker(true));

    ipcMain.handle('settings:get', () => ({
      ...this.settings.all,
      hasApiKey: this.settings.hasApiKey,
    }));
    ipcMain.handle('settings:save', (_event, patch: Partial<AppSettings>) => {
      const next = this.settings.update(patch);
      applyAppearance(next.appearance);
      // nativeTheme emits 'updated' on a themeSource change; sync anyway so the
      // window never depends on that event alone.
      this.syncTheme();
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
      this.syncTray();
    });
    ipcMain.handle('history:clear', () => {
      this.data.clearHistory();
      // "Clear all" also drops the audio kept for a retry: it is the same dictation data.
      this.service.discardRetained();
      this.broadcast('history:changed');
      this.syncTray();
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
      // The one non-https target is the Windows microphone privacy page, for the status fix.
      if (/^https:\/\//i.test(url) || url === 'ms-settings:privacy-microphone') await shell.openExternal(url);
    });

    ipcMain.handle('app:flags', () => ({ previewFeatures: process.argv.includes('--preview-features') }));
    ipcMain.handle('app:get-theme', () => resolvedTheme());
    ipcMain.handle('app:show-log', () => shell.showItemInFolder(this.diagnostics.path));

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
    // The main window has no native frame, so this menu bar is never shown (see
    // `openWindow`). It is kept because it still owns the standard edit shortcuts and
    // the accelerators. Its actions are reachable from the UI instead: Retry last
    // recording and Copy last transcript from the tray, Help > Deepgram API keys from
    // the key card in Settings, and Open diagnostics log from the Diagnostics card.
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
          { label: 'Start / stop', click: () => void this.toggleDictation('window') },
          { label: 'Cancel', click: () => void this.cancelDictation() },
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
    'app:get-theme': 'light',
    'app:flags': { previewFeatures: false },
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
    // 66: the theme (`getTheme`, `onThemeChanged`), `showDiagnosticsLog`, `onOutcome` +
    // `onTelemetry`, `getFlags`, and the floating windows (`onHudView`, `hudPointer`,
    // `hudAction`, `hudDrag`, `onAnnounce`, `pickerChoose`, `pickerClose`, `onSettingsChanged`), and `sendAudioStarted`.
    // Kept in step with the README by the comment below.
    const EXPECTED_API_METHODS = 66;
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
        navItems: document.querySelectorAll('.rail-item:not(.rail-status)').length,
        shell: !!document.querySelector('.shell'),
        title: (document.querySelector('.st-title') || document.querySelector('.stage-title') || {}).textContent || '',
        stats: document.querySelectorAll('.bubble').length,
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

// `--user-data-dir=<path>` points every store at a scratch folder, so the E2E suite
// runs on fixture data and never touches (or reads) the real install's history.
const userDataArg = process.argv.find((arg) => arg.startsWith('--user-data-dir='));
if (userDataArg) app.setPath('userData', path.resolve(userDataArg.slice('--user-data-dir='.length)));

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
      writeReport([`FAIL  self-test threw: ${(error as Error).message}`]);
      app.exit(1);
      return;
    }
    clearTimeout(watchdog);
    const lines = result.checks.map(
      (check) => `${check.ok ? 'PASS' : 'FAIL'}  ${check.name}: ${check.detail}`,
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
