import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { app, Menu, nativeImage, nativeTheme, Tray, type NativeImage } from 'electron';
import { DEEPGRAM_LANGUAGES, MULTILINGUAL_CODE_SWITCHING } from '../core/transcription/languages.js';

/**
 * The tray icon and its menu.
 *
 * Windows has no menu-bar-extra equivalent, so the tray is the app's front door,
 * equivalent to the macOS `LSUIElement` status item. The icons are the PNGs that
 * `npm run build:icon` writes to `build/tray`, shipped as extra resources.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Windows picks the representation that matches the display scale: 100, 125, 150 and 200 %. */
const TRAY_SCALES: Array<{ scaleFactor: number; px: number }> = [
  { scaleFactor: 1, px: 16 },
  { scaleFactor: 1.25, px: 20 },
  { scaleFactor: 1.5, px: 24 },
  { scaleFactor: 2, px: 32 },
];

export interface TrayHandlers {
  onToggleDictation: () => void;
  onOpenWindow: (page: string) => void;
  onQuit: () => void;
  onRetry: () => void;
  onCopyLast: () => void;
  onCancel: () => void;
  /** A language was picked in the Language submenu. */
  onSetLanguage: (code: string) => void;
  onSetFormatting: (enabled: boolean) => void;
}

export interface TrayState {
  recording: boolean;
  transcribing: boolean;
  /** A failed dictation's audio is still held, so "Retry last recording" works. */
  canRetry: boolean;
  /** Any dictation has finished, so "Copy last transcript" has something to copy. */
  canCopyLast: boolean;
  /** The accelerator as Electron spells it ("Control+Alt+Space"); shown as plain text. */
  hotkeyLabel: string;
  /** The pinned language: `auto`, `multi` or a code. Checked in the Language submenu. */
  languagePin: string;
  /** "Auto-format transcript". */
  formattingEnabled: boolean;
  /** The app a hotkey dictation will paste into, shown while recording. */
  insertingInto?: string | undefined;
}

export class TrayController {
  private tray: Tray | null = null;
  private state: TrayState = {
    recording: false,
    transcribing: false,
    canRetry: false,
    canCopyLast: false,
    hotkeyLabel: '',
    languagePin: 'auto',
    formattingEnabled: true,
  };

  constructor(private readonly handlers: TrayHandlers) {}

  create(): void {
    this.tray = new Tray(this.icon(this.state.recording));
    // The taskbar follows the system theme, so swap the icon when it changes.
    nativeTheme.on('updated', this.onThemeUpdated);
    this.tray.setToolTip('Useful Voice: press your hotkey to dictate');
    // Left click opens the window: the most common reason to click the tray icon
    // is to see what the app is doing.
    this.tray.on('click', () => this.handlers.onOpenWindow('stream'));
    this.render();
  }

  setState(next: Partial<TrayState>): void {
    this.state = { ...this.state, ...next };
    this.tray?.setImage(this.icon(this.state.recording));
    this.render();
  }

  destroy(): void {
    nativeTheme.off('updated', this.onThemeUpdated);
    this.tray?.destroy();
    this.tray = null;
  }

  private render(): void {
    if (!this.tray) return;
    this.tray.setContextMenu(Menu.buildFromTemplate(buildTrayTemplate(this.state, this.handlers)));
    this.tray.setToolTip(
      this.state.recording
        ? 'Useful Voice: recording'
        : this.state.transcribing
          ? 'Useful Voice: transcribing'
          : 'Useful Voice: ready',
    );
  }

  private readonly onThemeUpdated = (): void => {
    this.tray?.setImage(this.icon(this.state.recording));
  };

  /**
   * The Landing mark for the current taskbar theme: ink on a light taskbar, light on
   * a dark one, in the danger colour while recording.
   */
  private icon(recording: boolean): NativeImage {
    const taskbar = nativeTheme.shouldUseDarkColorsForSystemIntegratedUI ? 'dark' : 'light';
    const state = recording ? 'recording' : 'idle';
    const dir = app.isPackaged
      ? path.join(process.resourcesPath, 'tray')
      : path.join(__dirname, '..', '..', 'build', 'tray');
    const image = nativeImage.createEmpty();
    for (const { scaleFactor, px } of TRAY_SCALES) {
      image.addRepresentation({
        scaleFactor,
        buffer: fs.readFileSync(path.join(dir, `tray-${taskbar}-${state}-${px}.png`)),
      });
    }
    return image;
  }
}

/**
 * The tray menu, as the board draws it (a-58 idle, a-59 recording). A native menu, so
 * the status is a disabled first line and cannot carry a live timer: Win32 menus are
 * static while open, which is why it says "Recording" and not "Recording 0:12".
 */
export function buildTrayTemplate(
  state: TrayState,
  handlers: TrayHandlers,
): Electron.MenuItemConstructorOptions[] {
  const status = state.recording ? 'Recording' : state.transcribing ? 'Transcribing' : 'Ready';
  const hotkey = formatAccelerator(state.hotkeyLabel);

  const language: Electron.MenuItemConstructorOptions[] = [
    languageItem('Auto-detect', 'auto', state, handlers),
    languageItem('Multiple languages', MULTILINGUAL_CODE_SWITCHING.code, state, handlers),
    { type: 'separator' },
    ...DEEPGRAM_LANGUAGES.map((entry) =>
      languageItem(
        entry.nativeName === entry.name ? entry.name : `${entry.nativeName} (${entry.name})`,
        entry.code,
        state,
        handlers,
      ),
    ),
  ];

  const items: Array<Electron.MenuItemConstructorOptions | null> = [
    { label: status, enabled: false },
    { type: 'separator' },
    state.transcribing
      ? { label: 'Transcribing…', enabled: false }
      : {
          label: `${state.recording ? 'Stop' : 'Start'} dictation (${hotkey})`,
          click: () => handlers.onToggleDictation(),
        },
    state.recording
      ? {
          // Esc is a shortcut only while recording. Shown as a hint: the app registers it itself.
          label: 'Cancel dictation',
          accelerator: 'Esc',
          registerAccelerator: false,
          click: () => handlers.onCancel(),
        }
      : state.transcribing
        ? { label: 'Cancel dictation', click: () => handlers.onCancel() }
        : null,
    state.recording && state.insertingInto
      ? { label: `Inserting into: ${state.insertingInto}`, enabled: false }
      : null,
    { label: 'Retry last recording', enabled: state.canRetry, click: () => handlers.onRetry() },
    { label: 'Copy last transcript', enabled: state.canCopyLast, click: () => handlers.onCopyLast() },
    { type: 'separator' },
    { label: 'Language', submenu: language },
    {
      label: 'Auto-format transcript',
      type: 'checkbox',
      checked: state.formattingEnabled,
      click: (item) => handlers.onSetFormatting(item.checked),
    },
    { type: 'separator' },
    { label: 'Open Useful Voice', click: () => handlers.onOpenWindow('stream') },
    { label: 'Open settings', click: () => handlers.onOpenWindow('settings') },
    { type: 'separator' },
    { label: 'Quit Useful Voice', click: () => handlers.onQuit() },
  ];
  return items.filter((item): item is Electron.MenuItemConstructorOptions => item !== null);
}

function languageItem(
  label: string,
  code: string,
  state: TrayState,
  handlers: TrayHandlers,
): Electron.MenuItemConstructorOptions {
  return {
    label,
    type: 'checkbox',
    checked: state.languagePin === code,
    // A checkbox flips itself when clicked; the pin is what the menu shows, so it is rebuilt
    // from the settings after the change.
    click: () => handlers.onSetLanguage(code),
  };
}

/**
 * The hotkey as people say it. Electron spells the modifier "Control" or
 * "CommandOrControl"; the board and every other string in the app say "Ctrl".
 */
export function formatAccelerator(accelerator: string): string {
  if (accelerator.trim().length === 0) return 'no hotkey';
  return accelerator
    .split('+')
    .map((part) => (/^(control|commandorcontrol|cmdorctrl)$/i.test(part) ? 'Ctrl' : part))
    .join('+');
}
