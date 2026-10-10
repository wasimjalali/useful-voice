import { app, Menu, nativeImage, Tray, type NativeImage } from 'electron';

/**
 * The tray icon and its menu.
 *
 * Windows has no menu-bar-extra equivalent, so the tray is the app's front door —
 * equivalent to the macOS `LSUIElement` status item. The icon is generated in code
 * rather than shipped as a binary asset so the packaged app has nothing to lose.
 */

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
  /** A failed dictation's audio is still held, so "Retry last recording" works. */
  canRetry: boolean;
  /** Any dictation has finished, so "Copy last transcript" has something to copy. */
  canCopyLast: boolean;
  /** The accelerator as Electron spells it ("Control+Alt+Space"); shown as plain text. */
  hotkeyLabel: string;
}

export class TrayController {
  private tray: Tray | null = null;
  private state: TrayState = {
    recording: false,
    transcribing: false,
    canRetry: false,
    canCopyLast: false,
    hotkeyLabel: '',
  };

  constructor(private readonly handlers: TrayHandlers) {}

  create(): void {
    this.tray = new Tray(this.icon(false));
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
    this.tray?.destroy();
    this.tray = null;
  }

  private render(): void {
    if (!this.tray) return;
    const busy = this.state.recording || this.state.transcribing;

    // Win32 menus are static while open, so the first line says what the app is doing
    // without a live timer.
    const status = this.state.recording ? 'Recording' : this.state.transcribing ? 'Transcribing' : 'Ready';

    const items: Array<Electron.MenuItemConstructorOptions | null> = [
      { label: status, enabled: false },
      { type: 'separator' },
      {
        label: this.state.recording
          ? 'Stop and transcribe'
          : this.state.transcribing
            ? 'Transcribing…'
            : `Start dictation (${formatAccelerator(this.state.hotkeyLabel)})`,
        click: () => this.handlers.onToggleDictation(),
        enabled: !this.state.transcribing,
      },
      busy
        ? {
            // Esc is a shortcut only while recording.
            label: this.state.recording ? 'Cancel dictation (Esc)' : 'Cancel dictation',
            click: () => this.handlers.onCancel(),
          }
        : null,
      this.state.canRetry
        ? { label: 'Retry last recording', click: () => this.handlers.onRetry() }
        : null,
      this.state.canCopyLast
        ? { label: 'Copy last transcript', click: () => this.handlers.onCopyLast() }
        : null,
      { type: 'separator' },
      { label: 'Dictionary…', click: () => this.handlers.onOpenWindow('dictionary') },
      { label: 'History…', click: () => this.handlers.onOpenWindow('history') },
      { label: 'Notes…', click: () => this.handlers.onOpenWindow('notes') },
      { label: 'Open settings', click: () => this.handlers.onOpenWindow('settings') },
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

  /**
   * Draw the icon as a data URL.
   *
   * A filled circle when recording and a hollow one when idle: the same
   * information the macOS status item conveys, and legible at 16 px.
   */
  private icon(recording: boolean): NativeImage {
    const size = 32;
    const pixels = Buffer.alloc(size * size * 4, 0);
    const centre = (size - 1) / 2;
    const outer = 13;
    const inner = recording ? 0 : 6.5;

    for (let y = 0; y < size; y += 1) {
      for (let x = 0; x < size; x += 1) {
        const distance = Math.hypot(x - centre, y - centre);
        // Ink #171717 for the ring, matching the design system.
        const inRing = distance <= outer && distance >= inner;
        if (!inRing) continue;
        // Anti-alias the two edges so the circle does not look stepped.
        const alpha = Math.min(
          clamp01(outer - distance + 0.5),
          inner > 0 ? clamp01(distance - inner + 0.5) : 1,
        );
        const offset = (y * size + x) * 4;
        pixels[offset] = 0x17;
        pixels[offset + 1] = 0x17;
        pixels[offset + 2] = 0x17;
        pixels[offset + 3] = Math.round(alpha * 255);
      }
    }

    return nativeImage.createFromBuffer(pixels, { width: size, height: size });
  }
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

function clamp01(value: number): number {
  return Math.max(0, Math.min(1, value));
}
