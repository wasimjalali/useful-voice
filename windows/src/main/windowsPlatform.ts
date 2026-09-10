import { clipboard, app } from 'electron';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
// The delivery policy's view of a window: the same identity (process + handle) with
// the title the UI needs on top, so window info can be handed straight to the policy.
import type { PasteTarget } from '../core/delivery/clipboardRestore.js';

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

export interface ForegroundWindowInfo extends PasteTarget {
  /** Window title, for the HUD's "dictating into X" label. */
  title: string;
}

/**
 * Send Ctrl+V.
 *
 * `SendKeys` via PowerShell is used rather than a native addon: it needs no
 * compilation step, so the packaged app has no native binary to keep in step with
 * the Electron version. It is slower than a keybd_event call, which is irrelevant
 * here — one keystroke per dictation.
 */
export async function pasteClipboard(): Promise<boolean> {
  try {
    await runPowerShell('$wshell = New-Object -ComObject WScript.Shell; $wshell.SendKeys("^v")');
    return true;
  } catch {
    return false;
  }
}

/**
 * Send the target's undo shortcut, used to take back a paste that provably landed
 * when the user cancels within the undo window.
 */
export async function sendUndo(): Promise<boolean> {
  try {
    await runPowerShell('$wshell = New-Object -ComObject WScript.Shell; $wshell.SendKeys("^z")');
    return true;
  } catch {
    return false;
  }
}

/**
 * Which window has focus right now.
 *
 * Used for two things: showing the user which app will receive their text, and
 * proving that a paste landed in the same window it was aimed at. Comparing these
 * before and after is what makes "it landed" mean something — a paste that arrived
 * in a different window, or that only appeared to land because the user typed
 * something, must not trigger the clipboard restore.
 *
 * Returns null when the query fails, which callers treat as "cannot verify".
 */
export async function foregroundWindow(): Promise<ForegroundWindowInfo | null> {
  const script = `
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class UvForeground {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@
$h = [UvForeground]::GetForegroundWindow()
$len = [UvForeground]::GetWindowTextLength($h)
$sb = New-Object System.Text.StringBuilder ($len + 1)
[void][UvForeground]::GetWindowText($h, $sb, $sb.Capacity)
$pid = 0
[void][UvForeground]::GetWindowThreadProcessId($h, [ref]$pid)
$name = ""
try { $name = (Get-Process -Id $pid -ErrorAction Stop).ProcessName } catch {}
# A unit-separator character is used rather than a tab: PowerShell would need a
# backtick escape for a tab, and the backtick collides with JS template syntax.
Write-Output ("{0}{1}{2}{1}{3}" -f $h.ToInt64(), [char]31, $name, $sb.ToString())
`;
  try {
    const { stdout } = await runPowerShell(script);
    const line = stdout.trim().split(/\r?\n/).pop() ?? '';
    // Split on the unit separator emitted above.
    const [handleText, processName, ...titleParts] = line.split('\u001f');
    const handle = Number(handleText);
    if (!Number.isFinite(handle)) return null;
    return {
      handle,
      processName: (processName ?? '').trim(),
      title: titleParts.join(' ').trim(),
    };
  } catch {
    return null;
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
      `(New-Object Media.SoundPlayer '${file.replace(/'/g, "''")}').PlaySync()`,
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

async function runPowerShell(script: string, timeoutMs = 8000): Promise<{ stdout: string; stderr: string }> {
  const result = await execFileAsync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
    { timeout: timeoutMs, windowsHide: true, maxBuffer: 1024 * 1024 },
  );
  return { stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}
