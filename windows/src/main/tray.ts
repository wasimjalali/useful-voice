import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { app, Menu, nativeImage, nativeTheme, Tray, type NativeImage } from 'electron';

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
}

export interface TrayState {
  recording: boolean;
  transcribing: boolean;
  canRetry: boolean;
  hotkeyLabel: string;
  targetApp?: string;
}

export class TrayController {
  private tray: Tray | null = null;
  private state: TrayState = {
    recording: false,
    transcribing: false,
    canRetry: false,
    hotkeyLabel: '',
  };

  constructor(private readonly handlers: TrayHandlers) {}

  create(): void {
    this.tray = new Tray(this.icon(this.state.recording));
    // The taskbar follows the system theme, so swap the icon when it changes.
    nativeTheme.on('updated', this.onThemeUpdated);
    this.tray.setToolTip('Useful Voice: press your hotkey to dictate');
    // Left click opens the window: the most common reason to click the tray icon
    // is to see what the app is doing.
    this.tray.on('click', () => this.handlers.onOpenWindow('home'));
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
    const busy = this.state.recording || this.state.transcribing;

    const items: Array<Electron.MenuItemConstructorOptions | null> = [
      {
        label: this.state.recording
          ? 'Stop and transcribe'
          : this.state.transcribing
            ? 'Transcribing…'
            : `Start dictating (${this.state.hotkeyLabel || 'no hotkey'})`,
        click: () => this.handlers.onToggleDictation(),
        enabled: !this.state.transcribing,
      },
      busy
        ? { label: 'Cancel', click: () => this.handlers.onCancel() }
        : null,
      this.state.canRetry
        ? { label: 'Retry last dictation', click: () => this.handlers.onRetry() }
        : null,
      this.state.canRetry
        ? { label: 'Copy last transcript', click: () => this.handlers.onCopyLast() }
        : null,
      { type: 'separator' },
      {
        label: this.state.targetApp
          ? `Dictating into ${this.state.targetApp}`
          : 'No target app focused',
        enabled: false,
      },
      { type: 'separator' },
      { label: 'Dictionary…', click: () => this.handlers.onOpenWindow('dictionary') },
      { label: 'History…', click: () => this.handlers.onOpenWindow('history') },
      { label: 'Notes…', click: () => this.handlers.onOpenWindow('notes') },
      { label: 'Settings…', click: () => this.handlers.onOpenWindow('settings') },
      { type: 'separator' },
      { label: `Useful Voice ${app.getVersion()}`, enabled: false },
      { label: 'Quit', click: () => this.handlers.onQuit() },
    ];

    const template = items.filter(
      (item): item is Electron.MenuItemConstructorOptions => item !== null,
    );
    this.tray.setContextMenu(Menu.buildFromTemplate(template));
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
