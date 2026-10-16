import { clipboard, app } from 'electron';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
// The delivery policy's view of a window: the same identity (process + handle) with
// the title the UI needs on top, so window info can be handed straight to the policy.
import { parseForegroundLine, type ForegroundWindowInfo } from '../core/delivery/foregroundLine.js';
import type { InsertAttempt } from '../core/delivery/deliveryFlow.js';
import type { AddressRead } from './deliveryGlue.js';
import { appIdFor, isKnownBrowser } from '../core/delivery/deliveryTarget.js';
import {
  browserAddressScript,
  cueScript,
  foregroundScript,
  isHandle,
  pasteScript,
  reactivateScript,
  restoreForegroundScript,
  sendKeyScript,
  textBeforeCursorScript,
  typeScript,
} from './powershellScripts.js';
import { sendKeysFor } from '../core/apps/appAwareness.js';
import type { AutoSendKey } from '../core/apps/appCategory.js';

const execFileAsync = promisify(execFile);

/**
 * Windows input automation: paste, focus tracking, and clipboard access.
 *
 * This is the one place where Windows-specific behaviour lives, kept behind a
 * small interface so the rest of the app (and every test) stays platform-neutral.
 * Everything here is best-effort by design: if a call fails, the caller keeps the
 * dictation on the clipboard so nothing is ever lost.
 *
 * What it deliberately does not do is decide anything. Which processes can never be
 * verified, and whether the previous clipboard may be put back, are policy rather
 * than platform: they live in `src/core/delivery/clipboardRestore.ts`, because
 * everything in this file imports Electron — which the test runner cannot load — so
 * the delivery contract used to be reachable from no test at all.
 */

export type { ForegroundWindowInfo };

/** The last line a script printed. */
function lastLine(stdout: string): string {
  return stdout.trim().split(/\r?\n/).pop() ?? '';
}

/**
 * Send Ctrl+V, only while `expectedForeground` is in front and before the deadline.
 *
 * `SendKeys` via PowerShell is used rather than a native addon: it needs no
 * compilation step, so the packaged app has no native binary to keep in step with
 * the Electron version. It is slower than a keybd_event call, which is irrelevant
 * here: one keystroke per dictation. `kill` stops the script outright (a delivery that
 * ran out of time), so no keystroke can follow it.
 */
export async function pasteClipboard(
  expectedForeground: number,
  deadlineEpochMs: number,
  kill?: AbortSignal,
): Promise<InsertAttempt> {
  if (!isHandle(expectedForeground)) return { result: 'failed' };
  try {
    const { stdout } = await runPowerShell(
      pasteScript(expectedForeground, deadlineEpochMs),
      scriptTimeout(deadlineEpochMs),
      undefined,
      kill,
    );
    const word = lastLine(stdout);
    return { result: word === 'sent' || word === 'moved' || word === 'timeout' ? word : 'failed' };
  } catch {
    return { result: kill?.aborted || Date.now() >= deadlineEpochMs ? 'timeout' : 'failed' };
  }
}

/**
 * Press the auto-send key (Return, Shift+Return or Ctrl+Return), only while
 * `expectedForeground` is in front (with `expectedFocus`, the child control captured at the
 * press, still focused) and before the deadline, in the same script as the keystroke. `kill` stops the script outright when the delivery ran out of time.
 */
export async function sendKey(
  expectedForeground: number,
  key: AutoSendKey,
  deadlineEpochMs: number,
  kill?: AbortSignal,
  expectedFocus?: number,
): Promise<InsertAttempt> {
  const keys = sendKeysFor(key);
  if (!isHandle(expectedForeground) || keys === null) return { result: 'failed' };
  try {
    const { stdout } = await runPowerShell(
      sendKeyScript(expectedForeground, deadlineEpochMs, keys, expectedFocus),
      scriptTimeout(deadlineEpochMs),
      undefined,
      kill,
    );
    const word = lastLine(stdout);
    return { result: word === 'sent' || word === 'moved' || word === 'timeout' ? word : 'failed' };
  } catch {
    return { result: kill?.aborted || Date.now() >= deadlineEpochMs ? 'timeout' : 'failed' };
  }
}

/**
 * Type batches of UTF-16 units as Unicode keystrokes (type-out mode), never Ctrl+V.
 *
 * The batches come from `typeOutChunks` (so none splits an emoji) and go to the script
 * on stdin as decimal numbers, never inside the script. Before every batch the script
 * checks the deadline, that the target is still in front and that no password field
 * has focus, and it reports how many units went in before it stopped.
 */
export async function typeText(
  batches: number[][],
  expectedForeground: number,
  deadlineEpochMs: number,
  kill?: AbortSignal,
): Promise<InsertAttempt> {
  if (!isHandle(expectedForeground)) return { result: 'failed', typedUnits: 0 };
  const input = batches.map((batch) => batch.join(',')).join('\n');
  try {
    const { stdout } = await runPowerShell(
      typeScript(expectedForeground, deadlineEpochMs),
      scriptTimeout(deadlineEpochMs),
      input,
      kill,
    );
    const match = /^(sent|moved|secure|timeout|failed):(\d+)$/.exec(lastLine(stdout));
    if (!match) return { result: 'failed' };
    return { result: match[1] as InsertAttempt['result'], typedUnits: Number(match[2]) };
  } catch {
    // Killed or crashed: any number of batches may have gone in.
    return { result: kill?.aborted || Date.now() >= deadlineEpochMs ? 'timeout' : 'failed' };
  }
}

/**
 * How long a keystroke script may run: until its deadline plus a moment, so the
 * script's own deadline check (which reports what it typed) wins over the kill.
 */
function scriptTimeout(deadlineEpochMs: number): number {
  return Math.max(1, deadlineEpochMs - Date.now()) + 1000;
}

/**
 * Which window has focus right now.
 *
 * Used for two things: showing the user which app will receive their text, and
 * proving that a paste landed in the same window it was aimed at. Comparing these
 * before and after is what makes "it landed" mean something: a paste that arrived
 * in a different window, or that only appeared to land because the user typed
 * something, must not trigger the clipboard restore.
 *
 * Returns null when the query fails, which callers treat as "cannot verify".
 */
export async function foregroundWindow(timeoutMs = 8000): Promise<ForegroundWindowInfo | null> {
  if (timeoutMs <= 0) return null;
  try {
    const { stdout } = await runPowerShell(foregroundScript(), timeoutMs);
    return parseForegroundLine(lastLine(stdout));
  } catch {
    return null;
  }
}

/**
 * Bring a dictation's target back to the front (the target lock), with its focused
 * child when one was captured.
 *
 * Windows only hands the foreground over in a few cases; the script attaches to the
 * thread that owns the current foreground window, which is the documented way for an
 * input-attached thread to call `SetForegroundWindow`, and then restores the focused
 * child inside the target. Returns `gone` when the window no longer exists and
 * `refused` when Windows kept another window in front. The caller reads the foreground
 * again before inserting anything, so `ok` is never trusted on its own.
 */
export async function reactivateWindow(
  handle: number,
  focusHandle?: number,
  timeoutMs = 4000,
): Promise<'ok' | 'gone' | 'refused'> {
  if (!isHandle(handle)) return 'gone';
  if (timeoutMs <= 0) return 'refused';
  try {
    const { stdout } = await runPowerShell(reactivateScript(handle, focusHandle), Math.min(4000, timeoutMs));
    const result = lastLine(stdout);
    return result === 'ok' || result === 'gone' ? result : 'refused';
  } catch {
    return 'refused';
  }
}

/**
 * The page address of a browser window (Chrome, Edge, Brave, Firefox), read from its
 * real address bar with UI Automation (`browserAddressScript` says how it's told
 * apart from any other edit control). An address without a scheme (Chromium hides
 * `https://`) gets `https://`, the same way at the press and at delivery. The address
 * is null when it can't be read, or the app isn't a known browser; `timedOut` says the
 * read was cut off. Kept in memory only.
 */
export async function browserAddress(handle: number, appId: string | undefined, timeoutMs = 3000): Promise<AddressRead> {
  const none = (timedOut: boolean): AddressRead => ({ address: null, timedOut });
  if (!isHandle(handle) || !isKnownBrowser(appId)) return none(false);
  if (timeoutMs <= 0) return none(true);
  const kind = appIdFor(appId) === 'firefox' ? 'firefox' : 'chromium';
  try {
    const { stdout } = await runPowerShell(browserAddressScript(handle, kind), Math.min(3000, timeoutMs));
    const encoded = lastLine(stdout);
    if (!/^[A-Za-z0-9+/=]+$/.test(encoded)) return none(false);
    const value = Buffer.from(encoded, 'base64').toString('utf8').trim();
    if (value.length === 0 || /\s/.test(value)) return none(false);
    return { address: /^[a-z][a-z0-9+.-]*:\/\//i.test(value) ? value : `https://${value}`, timedOut: false };
  } catch (error) {
    // execFile kills a script that outlives its timeout and says so with `killed`.
    return none((error as { killed?: boolean }).killed === true);
  }
}

/**
 * Bring a window back to the foreground, by the handle `foregroundWindow` returned.
 *
 * Used when the language picker (a focusable window that took focus from the app being
 * dictated into) closes. The PowerShell child is started by the foreground app, which is
 * one of the cases Windows allows `SetForegroundWindow` for, but only while that app is
 * still in front: call this BEFORE hiding the picker. `onlyIfForeground` is the picker's
 * own window handle; when something else is in front by the time the script runs, the
 * user has clicked elsewhere and nothing is restored. A minimised window is
 * restored first. Returns false when the handle is gone or Windows refused.
 */
export async function restoreForegroundWindow(
  handle: number,
  options: { onlyIfForeground?: number; timeoutMs?: number } = {},
): Promise<boolean> {
  // Handles are interpolated into a script, so they must be plain positive integers.
  if (!Number.isSafeInteger(handle) || handle <= 0) return false;
  const guard = options.onlyIfForeground;
  if (guard !== undefined && (!Number.isSafeInteger(guard) || guard <= 0)) return false;
  const script = restoreForegroundScript(handle, guard);
  try {
    const { stdout } = await runPowerShell(script, options.timeoutMs);
    return stdout.trim().split(/\r?\n/).pop() === 'True';
  } catch {
    return false;
  }
}

/**
 * Our own process name, so delivery can refuse to paste into ourselves.
 */
export function ownProcessName(): string {
  return path.basename(process.execPath).replace(/\.exe$/i, '').toLowerCase();
}

/**
 * Sound feedback.
 *
 * Windows has no built-in API for a short cue that does not need a file, so a
 * short synthesized WAV is written once to the temp directory and played with the
 * system's own player. Failures are ignored: a missing beep must never affect a
 * dictation.
 */
export async function playCue(kind: 'start' | 'stop' | 'error'): Promise<void> {
  const file = await ensureCueFile(kind);
  if (!file) return;
  try {
    // PowerShell's SoundPlayer is the dependency-free option.
    await runPowerShell(
      cueScript(file),
      // A cue that takes longer than this is not feedback any more.
      2000,
    );
  } catch {
    // Best-effort.
  }
}

let cueDirectoryPromise: Promise<string> | null = null;

async function ensureCueFile(kind: 'start' | 'stop' | 'error'): Promise<string | null> {
  try {
    if (!cueDirectoryPromise) {
      cueDirectoryPromise = fs.mkdtemp(path.join(os.tmpdir(), 'useful-voice-cues-'));
    }
    const directory = await cueDirectoryPromise;
    const file = path.join(directory, `${kind}.wav`);
    try {
      await fs.access(file);
      return file;
    } catch {
      // Not written yet.
    }
    await fs.writeFile(file, buildCue(kind));
    return file;
  } catch {
    return null;
  }
}

/**
 * Short two-tone cues, generated rather than shipped as assets.
 *
 * Start rises, stop falls, error is a single low tone — the same information the
 * macOS build conveys with its synthesized chimes.
 */
function buildCue(kind: 'start' | 'stop' | 'error'): Buffer {
  const sampleRate = 22_050;
  const tones: Record<typeof kind, Array<{ hz: number; ms: number }>> = {
    start: [{ hz: 660, ms: 70 }, { hz: 990, ms: 90 }],
    stop: [{ hz: 990, ms: 70 }, { hz: 660, ms: 90 }],
    error: [{ hz: 320, ms: 180 }],
  };

  const samples: number[] = [];
  for (const tone of tones[kind]) {
    const count = Math.round((tone.ms / 1000) * sampleRate);
    for (let i = 0; i < count; i += 1) {
      // Short fade at each end so the cue does not click.
      const progress = i / count;
      const envelope = Math.min(1, progress * 12, (1 - progress) * 12);
      samples.push(Math.sin((2 * Math.PI * tone.hz * i) / sampleRate) * 0.25 * envelope);
    }
  }

  const dataBytes = samples.length * 2;
  const buffer = Buffer.alloc(44 + dataBytes);
  buffer.write('RIFF', 0, 'ascii');
  buffer.writeUInt32LE(36 + dataBytes, 4);
  buffer.write('WAVE', 8, 'ascii');
  buffer.write('fmt ', 12, 'ascii');
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(sampleRate, 24);
  buffer.writeUInt32LE(sampleRate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write('data', 36, 'ascii');
  buffer.writeUInt32LE(dataBytes, 40);
  samples.forEach((sample, index) => {
    const clamped = Math.max(-1, Math.min(1, sample));
    buffer.writeInt16LE(Math.round(clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff), 44 + index * 2);
  });
  return buffer;
}

/** Snapshot the clipboard so it can be put back after delivery. */
export interface ClipboardSnapshot {
  formats: string[];
  /** Only the formats that can be read eagerly and restored faithfully. */
  data: Record<string, Buffer>;
  text: string;
  html: string;
  rtf: string;
  /** True when something on the clipboard could not be captured. */
  incomplete: boolean;
}

/**
 * Copy the clipboard's contents.
 *
 * Only formats that can be read synchronously and written back faithfully are
 * captured. Anything else marks the snapshot `incomplete`, and an incomplete
 * snapshot is never restored: replacing the user's clipboard with something less
 * than it held would destroy data.
 */
export function snapshotClipboard(): ClipboardSnapshot {
  const formats = clipboard.availableFormats();
  const data: Record<string, Buffer> = {};
  let incomplete = false;

  const readable = ['text/plain', 'text/html', 'text/rtf', 'image/png', 'image/bmp'];
  for (const format of formats) {
    const normalised = format.toLowerCase();
    const known = readable.find((candidate) => normalised === candidate || normalised.startsWith(candidate));
    if (!known) {
      // A format we cannot faithfully restore (a file list, a proprietary type).
      incomplete = true;
      continue;
    }
    try {
      const value = clipboard.readBuffer(format);
      if (value.length > 0) data[format] = value;
    } catch {
      incomplete = true;
    }
  }

  return {
    formats,
    data,
    text: clipboard.readText(),
    html: clipboard.readHTML(),
    rtf: clipboard.readRTF(),
    incomplete,
  };
}

/**
 * Put a snapshot back. Returns whether the clipboard now holds what we restored.
 *
 * Verifying is not paranoia: `clipboard.clear()` invalidates the previous owner
 * immediately and is not atomic with the write that follows, so an unchecked write
 * could leave the clipboard EMPTY, losing both the user's data and the dictation.
 */
export function restoreClipboard(snapshot: ClipboardSnapshot): boolean {
  const parts: Array<{ text?: string; html?: string; rtf?: string }> = [];
  const entry: { text?: string; html?: string; rtf?: string } = {};
  if (snapshot.text.length > 0) entry.text = snapshot.text;
  if (snapshot.html.length > 0) entry.html = snapshot.html;
  if (snapshot.rtf.length > 0) entry.rtf = snapshot.rtf;

  if (Object.keys(entry).length === 0) {
    // Nothing restorable (an image-only or unreadable clipboard). Do not clear.
    return false;
  }
  parts.push(entry);

  clipboard.clear();
  clipboard.write(parts[0] as { text?: string; html?: string; rtf?: string });

  // Read back to confirm.
  if (snapshot.text.length > 0) return clipboard.readText() === snapshot.text;
  if (snapshot.html.length > 0) return clipboard.readHTML().length > 0;
  if (snapshot.rtf.length > 0) return clipboard.readRTF().length > 0;
  return false;
}

/** Whether the clipboard still holds exactly what we put there. */
export function clipboardHoldsText(expected: string): boolean {
  try {
    return clipboard.readText() === expected;
  } catch {
    return false;
  }
}

/**
 * Persistent, bounded diagnostic log.
 *
 * The macOS build had no logging at all: every failure existed for six seconds in
 * a floating pill and was then gone, with no way for a user to send anything
 * useful. Errors are recorded here and surfaced in Settings.
 */
export class Diagnostics {
  private readonly entries: string[] = [];
  private readonly maxEntries = 200;
  private readonly filePath: string;
  private writeTimer: NodeJS.Timeout | null = null;

  constructor(userDataDirectory: string) {
    this.filePath = path.join(userDataDirectory, 'diagnostics.log');
  }

  get path(): string {
    return this.filePath;
  }

  /** Record an event. Never include transcript text or the API key here. */
  log(category: string, message: string): void {
    const line = `${new Date().toISOString()} [${category}] ${message}`;
    this.entries.push(line);
    if (this.entries.length > this.maxEntries) this.entries.shift();
    this.scheduleFlush();
  }

  recent(count = 50): string[] {
    return this.entries.slice(-count);
  }

  private scheduleFlush(): void {
    if (this.writeTimer) return;
    this.writeTimer = setTimeout(() => {
      this.writeTimer = null;
      void this.flush();
    }, 1000);
    this.writeTimer.unref?.();
  }

  async flush(): Promise<void> {
    try {
      await fs.writeFile(this.filePath, this.entries.join('\n') + '\n', 'utf8');
    } catch {
      // Diagnostics must never be the reason something else fails.
    }
  }
}

export function appVersion(): string {
  return app.getVersion();
}

/**
 * Run a script. `kill` (when given) stops the child at once: a delivery that ran out of
 * time must not send a keystroke afterwards.
 */
async function runPowerShell(
  script: string,
  timeoutMs = 8000,
  input?: string,
  kill?: AbortSignal,
): Promise<{ stdout: string; stderr: string }> {
  const pending = execFileAsync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
    { timeout: timeoutMs, windowsHide: true, maxBuffer: 1024 * 1024, encoding: 'utf8', ...(kill ? { signal: kill } : {}) },
  );
  // A child that exits (or is killed) before reading its input closes the pipe; the
  // write then fails with EPIPE, which must not become an uncaught exception. The
  // script's own result (or the rejection below) already says what happened.
  pending.child.stdin?.on('error', () => undefined);
  // stdin is closed either way, so a script that reads it never waits forever.
  pending.child.stdin?.end(input ?? '');
  const result = await pending;
  return { stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}

/**
 * The longest a text-before-cursor read may live, start of PowerShell and UI Automation
 * included. The read itself has `TEXT_READ_BUDGET_MS`; this only stops a stuck process.
 * It runs beside the recording, so it never delays the hotkey press.
 */
const TEXT_READ_KILL_MS = 3000;

/**
 * Up to 200 characters before the caret in the focused field of the window captured at
 * the press, or null when that can't be known: a password field, no caret, the window no
 * longer in front, a timeout or any failure. Memory only: the caller must never log or
 * store it.
 */
export async function textBeforeCursor(handle: number): Promise<string | null> {
  if (!isHandle(handle)) return null;
  try {
    const { stdout } = await runPowerShell(textBeforeCursorScript(handle), TEXT_READ_KILL_MS);
    const line = lastLine(stdout);
    if (!line.startsWith('ok:')) return null;
    const encoded = line.slice(3);
    if (!/^[A-Za-z0-9+/=]*$/.test(encoded)) return null;
    return Buffer.from(encoded, 'base64').toString('utf8');
  } catch {
    return null;
  }
}
