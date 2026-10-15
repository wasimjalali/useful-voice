import { clipboard, app } from 'electron';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
// The delivery policy's view of a window: the same identity (process + handle) with
// the title the UI needs on top, so window info can be handed straight to the policy.
import { parseForegroundLine, type ForegroundWindowInfo } from '../core/delivery/foregroundLine.js';

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

/** Whether `value` is a handle that may be interpolated into a script. */
function isHandle(value: number | undefined): value is number {
  return value !== undefined && Number.isSafeInteger(value) && value > 0;
}

/** The C# a guarded insert needs: the foreground window. */
const FOREGROUND_GUARD = `
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class UvGuard {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@`;

/**
 * Send Ctrl+V.
 *
 * `SendKeys` via PowerShell is used rather than a native addon: it needs no
 * compilation step, so the packaged app has no native binary to keep in step with
 * the Electron version. It is slower than a keybd_event call, which is irrelevant
 * here — one keystroke per dictation.
 */
export async function pasteClipboard(expectedForeground?: number): Promise<'sent' | 'moved' | 'failed'> {
  // The target lock's last look happens in the same script as the keystroke, so no
  // other window can take the foreground between the check and the paste.
  const guard = isHandle(expectedForeground)
    ? `${FOREGROUND_GUARD}
if ([UvGuard]::GetForegroundWindow() -ne [IntPtr]${expectedForeground}) { Write-Output "moved"; exit 0 }
`
    : '';
  try {
    const { stdout } = await runPowerShell(
      `${guard}$wshell = New-Object -ComObject WScript.Shell; $wshell.SendKeys("^v"); Write-Output "sent"`,
    );
    return stdout.trim().split(/\r?\n/).pop() === 'moved' ? 'moved' : 'sent';
  } catch {
    return 'failed';
  }
}

/**
 * Type `text` as Unicode keystrokes (type-out mode), never Ctrl+V.
 *
 * `SendInput` with `KEYEVENTF_UNICODE` carries each UTF-16 unit itself, so the result
 * does not depend on the keyboard layout. The text arrives on stdin as base64 of UTF-8,
 * never inside the script, so nothing in it can be read as PowerShell. Before the first
 * keystroke the script refuses a password field (UI Automation's IsPassword), and before
 * every batch it checks the target window is still in front: `moved` means it stopped
 * there. Batches never split a surrogate pair (see `typeOutChunks`).
 */
export async function typeText(
  text: string,
  expectedForeground: number,
  chunkUnits: number,
): Promise<'sent' | 'moved' | 'secure' | 'failed'> {
  if (!isHandle(expectedForeground)) return 'failed';
  const units = Math.max(2, Math.floor(chunkUnits));
  const script = `
Add-Type -AssemblyName UIAutomationClient
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class UvType {
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
  [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public static string Type(string text, IntPtr expected, int chunk) {
    int i = 0;
    while (i < text.Length) {
      if (GetForegroundWindow() != expected) return "moved";
      int end = Math.Min(i + chunk, text.Length);
      if (end < text.Length && (Char.IsHighSurrogate(text[end - 1]) || (text[end - 1] == '\\r' && text[end] == '\\n'))) end -= 1;
      INPUT[] batch = new INPUT[(end - i) * 2];
      for (int k = i; k < end; k++) {
        int j = (k - i) * 2;
        batch[j].type = 1; batch[j].u.ki.wScan = text[k]; batch[j].u.ki.dwFlags = 0x0004;
        batch[j + 1].type = 1; batch[j + 1].u.ki.wScan = text[k]; batch[j + 1].u.ki.dwFlags = 0x0004 | 0x0002;
      }
      if (SendInput((uint)batch.Length, batch, Marshal.SizeOf(typeof(INPUT))) != (uint)batch.Length) return "failed";
      i = end;
      System.Threading.Thread.Sleep(5);
    }
    return "sent";
  }
}
"@
$expected = [IntPtr]${expectedForeground}
if ([UvType]::GetForegroundWindow() -ne $expected) { Write-Output "moved"; exit 0 }
try {
  $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
  if ($focused -ne $null -and $focused.Current.IsPassword) { Write-Output "secure"; exit 0 }
} catch {}
$text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd().Trim()))
Write-Output ([UvType]::Type($text, $expected, ${units}))
`;
  try {
    const { stdout } = await runPowerShell(script, 30_000, Buffer.from(text, 'utf8').toString('base64'));
    const result = stdout.trim().split(/\r?\n/).pop();
    return result === 'sent' || result === 'moved' || result === 'secure' ? result : 'failed';
  } catch {
    return 'failed';
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
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO { public int cbSize; public int flags; public IntPtr hwndActive; public IntPtr hwndFocus; public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret; public RECT rcCaret; }
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO info);
  public static long Focus(uint thread) {
    GUITHREADINFO info = new GUITHREADINFO();
    info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    if (!GetGUIThreadInfo(thread, ref info)) return 0;
    return info.hwndFocus.ToInt64();
  }
}
"@
$h = [UvForeground]::GetForegroundWindow()
$len = [UvForeground]::GetWindowTextLength($h)
$sb = New-Object System.Text.StringBuilder ($len + 1)
[void][UvForeground]::GetWindowText($h, $sb, $sb.Capacity)
$procId = 0
$thread = [UvForeground]::GetWindowThreadProcessId($h, [ref]$procId)
$focus = [UvForeground]::Focus($thread)
$name = ""
try { $name = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch {}
# A unit-separator character is used rather than a tab: PowerShell would need a
# backtick escape for a tab, and the backtick collides with JS template syntax.
# The title goes last: it is the only field that could ever contain odd characters.
Write-Output ("{0}{1}{2}{1}{3}{1}{4}{1}{5}" -f $h.ToInt64(), [char]31, $name, $procId, $focus, $sb.ToString())
`;
  try {
    const { stdout } = await runPowerShell(script);
    const line = stdout.trim().split(/\r?\n/).pop() ?? '';
    return parseForegroundLine(line);
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
): Promise<'ok' | 'gone' | 'refused'> {
  if (!isHandle(handle)) return 'gone';
  const focus = isHandle(focusHandle) ? focusHandle : 0;
  const script = `
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class UvReactivate {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint to, bool on);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  public static string Bring(IntPtr target, IntPtr focus) {
    if (!IsWindow(target)) return "gone";
    if (IsIconic(target)) ShowWindow(target, 9);
    uint me = GetCurrentThreadId();
    uint front = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
    uint owner = GetWindowThreadProcessId(target, IntPtr.Zero);
    bool attachedFront = front != 0 && front != me && AttachThreadInput(me, front, true);
    bool attachedOwner = owner != 0 && owner != me && owner != front && AttachThreadInput(me, owner, true);
    BringWindowToTop(target);
    SetForegroundWindow(target);
    if (focus != IntPtr.Zero && IsWindow(focus)) SetFocus(focus);
    if (attachedOwner) AttachThreadInput(me, owner, false);
    if (attachedFront) AttachThreadInput(me, front, false);
    return GetForegroundWindow() == target ? "ok" : "refused";
  }
}
"@
Write-Output ([UvReactivate]::Bring([IntPtr]${handle}, [IntPtr]${focus}))
`;
  try {
    const { stdout } = await runPowerShell(script, 4000);
    const result = stdout.trim().split(/\r?\n/).pop();
    return result === 'ok' || result === 'gone' ? result : 'refused';
  } catch {
    return 'refused';
  }
}

/**
 * The address bar's text of a browser window (Chrome, Edge, Brave, Firefox), read with
 * UI Automation: the first edit control in the window, which in these browsers is the
 * address bar. Null when it cannot be read. Slow on a large page, so callers never wait
 * on it before recording starts. The value is kept in memory only.
 */
export async function browserAddress(handle: number): Promise<string | null> {
  if (!isHandle(handle)) return null;
  const script = `
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]${handle})
$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
$edit = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
if ($edit -eq $null) { exit 0 }
$value = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Write-Output ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value)))
`;
  try {
    const { stdout } = await runPowerShell(script, 3000);
    const encoded = stdout.trim().split(/\r?\n/).pop() ?? '';
    if (!/^[A-Za-z0-9+/=]+$/.test(encoded)) return null;
    const value = Buffer.from(encoded, 'base64').toString('utf8').trim();
    return value.length > 0 ? value : null;
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

async function runPowerShell(
  script: string,
  timeoutMs = 8000,
  input?: string,
): Promise<{ stdout: string; stderr: string }> {
  const pending = execFileAsync(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
    { timeout: timeoutMs, windowsHide: true, maxBuffer: 1024 * 1024 },
  );
  // stdin is closed either way, so a script that reads it never waits forever.
  pending.child.stdin?.end(input ?? '');
  const result = await pending;
  return { stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}
