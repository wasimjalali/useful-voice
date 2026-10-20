import { clipboard, app } from 'electron';
import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  FOREGROUND_QUERY_TIMEOUT_MS,
  HOST_STARTUP_TIMEOUT_MS,
  PASTE_KEYSTROKE_TIMEOUT_MS,
  PASTE_ONE_SHOT_TIMEOUT_MS,
} from '../core/delivery/timing.js';
import type { ClipboardState, KeystrokeRequest, KeystrokeResult } from '../core/delivery/pasteFlow.js';
import {
  FOREGROUND_TYPE,
  readTimeouts,
  runHosted as runHostedWith,
  sendPasteKeystroke,
  type OneShotRunner,
} from './keystroke.js';
import { PowerShellHost, PowerShellHostError, hostArguments } from './powershellHost.js';
import {
  MEDIA_PRELUDE,
  listPlayingScript,
  parsePauseOutput,
  parsePlayingOutput,
  parseResumeOutput,
  parseTimelineOutput,
  pauseScript,
  resumeScript,
  timelineScript,
} from './mediaScripts.js';
import { createMediaRunner } from './mediaRunner.js';
import type { MediaEffects } from '../core/media/mediaPausePolicy.js';
// The delivery policy's view of a window: the same identity (process + handle) with
// the title the UI needs on top, so window info can be handed straight to the policy.
import {
  hasUnrestorableFormat,
  restoreSnapshotTo,
  sameClipboardText,
  type PasteTarget,
  type RestoreOutcome,
} from '../core/delivery/clipboardRestore.js';

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
 * Send Ctrl+V, if it is still right to, and say what is known about it. The logic, and
 * what each answer means, lives in `keystroke.ts`.
 *
 * `SendKeys` via PowerShell is used rather than a native addon: it needs no compilation
 * step, so the packaged app has no native binary to keep in step with the Electron
 * version. It runs in the long-lived PowerShell host (see `powershellHost.ts`), so the
 * keystroke goes out within a few milliseconds instead of after a process start.
 *
 * The script itself checks, immediately before `SendKeys`, that the foreground window's
 * process is not Useful Voice's own (unless the dictation started in our window) and that
 * the clipboard still holds the dictation. It is given only our process id and a hash, never
 * the text.
 */
export function pasteClipboard(request: KeystrokeRequest): Promise<KeystrokeResult> {
  return sendPasteKeystroke(
    { host, oneShot: runOneShot, oneShotPrelude: ONE_SHOT_PRELUDE(), timeouts: { hostMs: PASTE_KEYSTROKE_TIMEOUT_MS, oneShotMs: PASTE_ONE_SHOT_TIMEOUT_MS } },
    { ...request, ownPid: process.pid },
  );
}

/** What a one-shot process needs before the paste body: the types and the shell object. */
const ONE_SHOT_PRELUDE = (): string => FOREGROUND_TYPE + '\n$uvShell = New-Object -ComObject WScript.Shell\n';

const FOREGROUND_BODY = `
$h = [UvForeground]::GetForegroundWindow()
$len = [UvForeground]::GetWindowTextLength($h)
$sb = New-Object System.Text.StringBuilder ($len + 1)
[void][UvForeground]::GetWindowText($h, $sb, $sb.Capacity)
$procId = 0
[void][UvForeground]::GetWindowThreadProcessId($h, [ref]$procId)
$name = ""
try { $name = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch {}
# A unit-separator character is used rather than a tab: PowerShell would need a
# backtick escape for a tab, and the backtick collides with JS template syntax.
Write-Output ("{0}{1}{2}{1}{3}" -f $h.ToInt64(), [char]31, $name, $sb.ToString())
`;

/**
 * Which window has focus right now.
 *
 * Used for the HUD's "dictating into" label and for handing focus back to the window the
 * language picker was opened over. Delivery does not use it: the paste script checks the
 * foreground process itself, right before it sends the key.
 *
 * Returns null when the query fails, which callers treat as "cannot verify".
 */
export async function foregroundWindow(): Promise<ForegroundWindowInfo | null> {
  try {
    const stdout = await runHosted(FOREGROUND_BODY, FOREGROUND_TYPE + FOREGROUND_BODY, FOREGROUND_QUERY_TIMEOUT_MS);
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
  const script = `
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class UvRestore {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@
$h = [IntPtr]${handle}
${guard === undefined ? '' : `# The user clicked somewhere else while this started: leave their choice alone.
if ([UvRestore]::GetForegroundWindow() -ne [IntPtr]${guard}) { Write-Output "moved"; exit 0 }`}
if (-not [UvRestore]::IsWindow($h)) { Write-Output "gone"; exit 0 }
if ([UvRestore]::IsIconic($h)) { [void][UvRestore]::ShowWindow($h, 9) }
Write-Output ([UvRestore]::SetForegroundWindow($h))
`;
  try {
    const { stdout } = await runPowerShell(script, options.timeoutMs);
    return stdout.trim().split(/\r?\n/).pop() === 'True';
  } catch {
    return false;
  }
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
  const quoted = file.replace(/'/g, "''");
  try {
    // In the host the cue plays on its own thread (`Play`, not `PlaySync`), so it never
    // holds up a paste queued behind it. The player is kept in a variable so it is not
    // collected while it sounds.
    await runHosted(
      `$uvCue_${kind} = New-Object Media.SoundPlayer '${quoted}'; $uvCue_${kind}.Play()`,
      // The one-shot process dies with the script, so it has to wait for the sound.
      `(New-Object Media.SoundPlayer '${quoted}').PlaySync()`,
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
    await fs.writeFile(file, kind === 'error' ? buildErrorCue() : await fs.readFile(cueAsset(kind)));
    return file;
  } catch {
    return null;
  }
}

/**
 * Start and stop are the tap-and-echo cues shared with macOS (`core/audio/chimeSynth.ts`),
 * rendered at build time by `scripts/build-cues.mjs` so no synthesis runs in this process.
 * The path works inside app.asar too: Electron's fs reads it, and the copy in the temp
 * directory is what SoundPlayer opens.
 */
function cueAsset(kind: 'start' | 'stop'): string {
  return fileURLToPath(new URL(`../cues/${kind}.wav`, import.meta.url));
}

/** The error cue, which macOS has no sound for: a single low tone. */
function buildErrorCue(): Buffer {
  const sampleRate = 22_050;
  const tones = [{ hz: 320, ms: 180 }];

  const samples: number[] = [];
  for (const tone of tones) {
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
  text: string;
  html: string;
  rtf: string;
  /** True when something on the clipboard could not be captured. */
  incomplete: boolean;
}

/**
 * Copy the clipboard's contents.
 *
 * Only plain text, HTML and RTF are captured, because those are the only formats the
 * restore writes back. Any other format on the clipboard (an image, a file list, a
 * proprietary type) marks the snapshot `incomplete`, and an incomplete snapshot is
 * never restored: replacing the user's clipboard with something less than it held
 * would destroy data.
 */
export function snapshotClipboard(): ClipboardSnapshot {
  const formats = clipboard.availableFormats();
  let incomplete = hasUnrestorableFormat(formats);
  let text = '';
  let html = '';
  let rtf = '';
  try {
    text = clipboard.readText();
    html = clipboard.readHTML();
    rtf = clipboard.readRTF();
  } catch {
    incomplete = true;
  }
  return { formats, text, html, rtf, incomplete };
}

/**
 * Put a snapshot back. Returns what ended up on the clipboard.
 *
 * Verifying is not paranoia: `clipboard.clear()` invalidates the previous owner
 * immediately and is not atomic with the write that follows, so an unchecked write
 * could leave the clipboard EMPTY, losing both the user's data and the dictation.
 * When the restore fails the dictation text is put back instead.
 */
export function restoreClipboard(snapshot: ClipboardSnapshot, dictationText: string): RestoreOutcome {
  return restoreSnapshotTo(clipboard, snapshot, dictationText);
}

/**
 * Whether the clipboard still holds exactly what we put there: `holds`, `changed`, or
 * `unreadable` when another app has the clipboard open and the read throws. Line endings
 * are compared as LF on both sides, because Windows may hand back CRLF for what was written
 * as LF.
 */
export function clipboardState(expected: string): ClipboardState {
  try {
    return sameClipboardText(clipboard.readText(), expected) ? 'holds' : 'changed';
  } catch {
    return 'unreadable';
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
    } catch (error) {
      // Diagnostics must never be the reason something else fails, so this only reaches the console.
      console.error(`could not write ${this.filePath}: ${(error as Error).message}`);
    }
  }
}

export function appVersion(): string {
  return app.getVersion();
}

/** Run a script in the PowerShell host, or in a one-shot process when there is none. */
function runHosted(
  hostScript: string,
  oneShotScript: string,
  hostMs: number,
): Promise<string> {
  // Reads and cues keep a short one-shot limit too: the long budget is for the paste only.
  return runHostedWith(host, runOneShot, hostScript, oneShotScript, readTimeouts(hostMs));
}

/**
 * A fresh PowerShell process. Throws a `PowerShellHostError` with `sent: false` when
 * `powershell.exe` cannot be started at all; any other failure happened after it started.
 */
const runOneShot: OneShotRunner = async (script, timeoutMs, signal) => {
  try {
    return (await runPowerShell(script, timeoutMs, signal)).stdout;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      throw new PowerShellHostError('unavailable', 'powershell.exe could not be started', false);
    }
    throw error;
  }
};

let host: PowerShellHost | null = null;

/** Compiled once per host start: everything the hotkey and delivery scripts rely on. */
const HOST_SETUP = FOREGROUND_TYPE + '\n$uvShell = New-Object -ComObject WScript.Shell';

/**
 * Start the long-lived PowerShell host. Call at app ready: the first hotkey press then
 * finds the C# already compiled. Resolves false (and the app keeps using one-shot
 * processes) off Windows or when the host cannot start.
 */
export async function startPowerShellHost(log?: (message: string) => void): Promise<boolean> {
  if (process.platform !== 'win32') return false;
  if (!host) {
    host = new PowerShellHost({
      spawn: () =>
        spawn('powershell.exe', hostArguments(), { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] }),
      setupScript: HOST_SETUP,
      startupTimeoutMs: HOST_STARTUP_TIMEOUT_MS,
      log,
    });
  }
  return host.start();
}

/** Stop the host. Safe to call when it never started. */
export function stopPowerShellHost(): void {
  host?.dispose();
  host = null;
}

async function runPowerShell(
  script: string,
  timeoutMs = 8000,
  signal?: AbortSignal,
): Promise<{ stdout: string; stderr: string }> {
  const result = await execFileAsync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
    // `signal` kills the child when it aborts, so a script that has not run yet never does.
    { timeout: timeoutMs, windowsHide: true, maxBuffer: 1024 * 1024, signal },
  );
  return { stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}

// ---- media ----------------------------------------------------------------

/** Longest a media request may run in the warm host. Above the script's own 3 s wait per call. */
const MEDIA_HOST_TIMEOUT_MS = 6000;
/** The same through a cold one-shot process, the fallback. */
const MEDIA_ONE_SHOT_TIMEOUT_MS = 12_000;

let mediaHost: PowerShellHost | null = null;

/**
 * The media scripts get a PowerShell host of their own, not a place in the delivery host's
 * queue. That host runs one request at a time and cannot be interrupted, so a media request
 * (a few hundred ms warm, longer when an app is slow to answer) queued ahead of a paste
 * would delay it by that much. A second host costs one idle process and removes the wait.
 */
function mediaScriptHost(log?: (message: string) => void): PowerShellHost {
  mediaHost ??= new PowerShellHost({
    spawn: () => spawn('powershell.exe', hostArguments(), { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] }),
    setupScript: MEDIA_PRELUDE,
    startupTimeoutMs: HOST_STARTUP_TIMEOUT_MS,
    log,
  });
  return mediaHost;
}

/** Apps publish their timeline a moment after a pause lands; the reading is taken after this. */
const PAUSE_SETTLE_MS = 200;

/**
 * The Windows side of "Pause media while dictating". Off Windows it does nothing. `warm`
 * starts the media host ahead of the first dictation.
 *
 * Quitting: `beginQuit` ends the settle wait at once and gives later pause scripts the
 * tighter WinRT cap. `dispose` stops the host and drops every media request still waiting:
 * a request the host rejects as unavailable is NOT rerouted to a one-shot process once
 * disposed (see `mediaRunner.ts`), because a queued pause must never run after the app has resumed and left.
 */
export function createMediaEffects(
  appUserModelId: string,
  log: (message: string) => void,
): MediaEffects & { warm(): void; dispose(): void } {
  const available = process.platform === 'win32';
  const timeouts = { hostMs: MEDIA_HOST_TIMEOUT_MS, oneShotMs: MEDIA_ONE_SHOT_TIMEOUT_MS };
  const runner = createMediaRunner({ host: () => mediaScriptHost(log), oneShot: runOneShot, timeouts });
  let quitting = false;
  let endSettle: (() => void) | null = null;
  const run = (body: string): Promise<string> => runner.run(body, MEDIA_PRELUDE + body);
  /** Waits for the settle, or less when the app starts quitting. */
  const settle = (): Promise<void> =>
    new Promise((resolve) => {
      if (quitting) return resolve();
      const timer = setTimeout(resolve, PAUSE_SETTLE_MS);
      timer.unref?.();
      endSettle = () => {
        clearTimeout(timer);
        resolve();
      };
    });
  return {
    async listPlaying() {
      if (!available) return [];
      return parsePlayingOutput(await run(listPlayingScript(appUserModelId)));
    },
    async pause(ids) {
      if (!available || ids.length === 0) return { confirmed: [], refused: [], skipped: [] };
      const result = parsePauseOutput(await run(pauseScript(ids, { quitting })));
      if (result.confirmed.length === 0 || quitting) return result;
      // The reading taken at once may be from before the app published the pause. Read again
      // after a settle; if that fails or the app is quitting, the first reading stands (the
      // touch tolerance covers the difference).
      await settle();
      if (quitting) return result;
      try {
        const later = new Map(
          parseTimelineOutput(await run(timelineScript(result.confirmed.map((session) => session.id)))).map((session) => [session.id, session]),
        );
        return { ...result, confirmed: result.confirmed.map((session) => later.get(session.id) ?? session) };
      } catch {
        return result;
      }
    },
    async resume(sessions) {
      if (!available || sessions.length === 0) return { refused: [], touched: [], unconfirmed: [], skipped: [] };
      return parseResumeOutput(await run(resumeScript(sessions)));
    },
    beginQuit() {
      quitting = true;
      endSettle?.();
    },
    warm() {
      if (available && !runner.disposed) void mediaScriptHost(log).start();
    },
    dispose() {
      runner.dispose();
      mediaHost?.dispose();
      mediaHost = null;
    },
  };
}
