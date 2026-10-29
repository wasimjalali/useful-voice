import { spawn } from 'node:child_process';
import { screen } from 'electron';
import { HOST_STARTUP_TIMEOUT_MS } from '../core/delivery/timing.js';
import { parseCaretLine, type Rect } from '../core/hudPlacement.js';
import { PowerShellHost, PowerShellHostError, hostArguments } from './powershellHost.js';

/**
 * Where the text cursor of the app in front is, so the HUD can sit beside it.
 *
 * Two readings, in order. First the classic one: `GetGUIThreadInfo` on the foreground window's
 * thread gives `rcCaret` for apps that draw a system caret (Notepad, Win32 edit boxes, many
 * classic apps). If that is empty, UI Automation: the focused element's TextPattern, the first
 * selection range's bounding rectangle, and for a collapsed range the left edge of the character
 * after it as a zero-width caret. Chromium, Electron and UWP apps usually answer only the second.
 *
 * It runs in a PowerShell host of its own, like the media scripts: the types compile once, and a
 * slow UI Automation call (some apps take hundreds of ms) never sits in front of a paste.
 * Each lookup runs with its thread set to per-monitor DPI awareness (v2), otherwise Windows hands
 * the host scaled coordinates on a display above 100 %. Every failure is `null`, and the HUD then
 * sits at the bottom; the first failure of each kind is logged (then at most once a minute).
 */

/** How long a caller waits for an answer. A slower answer is dropped, not waited for. */
export const CARET_LOOKUP_TIMEOUT_MS = 250;
/** The host's own limit per request. Longer than the caller's wait so a slow app never kills (and recompiles) the host. */
const CARET_HOST_TIMEOUT_MS = 3000;
/** Smaller or taller than this is not a text caret (a selection of a whole page, a stray 1 px rect). */
const MIN_CARET_HEIGHT = 6;
const MAX_CARET_HEIGHT = 120;

const CARET_PRELUDE = `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class UvCaret {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags;
    public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
    public RECT rcCaret;
  }
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

  // Per-monitor aware v2 for this thread. Returns the previous context, or 0 when it could not be set.
  public static long Enter() {
    try { return SetThreadDpiAwarenessContext(new IntPtr(-4)).ToInt64(); } catch (Exception) { return 0; }
  }
  public static void Leave(long previous) {
    if (previous == 0) return;
    try { SetThreadDpiAwarenessContext(new IntPtr(previous)); } catch (Exception) { }
  }

  // "left,top,right,bottom" in physical screen pixels, "own" for our own window, or "".
  public static string Read(uint ownPid) {
    IntPtr foreground = GetForegroundWindow();
    if (foreground == IntPtr.Zero) return "";
    uint pid;
    uint thread = GetWindowThreadProcessId(foreground, out pid);
    if (pid == ownPid) return "own";
    GUITHREADINFO info = new GUITHREADINFO();
    info.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    if (!GetGUIThreadInfo(thread, ref info)) return "";
    if (info.hwndCaret == IntPtr.Zero) return "";
    RECT rc = info.rcCaret;
    if (rc.Bottom - rc.Top <= 0) return "";
    POINT a = new POINT(); a.X = rc.Left; a.Y = rc.Top;
    POINT b = new POINT(); b.X = rc.Right; b.Y = rc.Bottom;
    if (!ClientToScreen(info.hwndCaret, ref a) || !ClientToScreen(info.hwndCaret, ref b)) return "";
    return a.X + "," + a.Y + "," + b.X + "," + b.Y;
  }
}
"@
function Get-UvCaretUia([int]$ownPid) {
  try {
    $element = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $element) { return '' }
    if ($element.Current.ProcessId -eq $ownPid) { return 'own' }
    $pattern = $null
    if (-not $element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) { return '' }
    $selection = $pattern.GetSelection()
    if ($selection.Length -lt 1) { return '' }
    $range = $selection[0]
    $rects = $range.GetBoundingRectangles()
    if ($rects.Length -ge 1) {
      $r = $rects[0]
      return ('{0},{1},{2},{3}' -f [int]$r.Left, [int]$r.Top, [int]$r.Right, [int]$r.Bottom)
    }
    # A collapsed range has no rectangle: the next character's left edge is where the caret is.
    $clone = $range.Clone()
    [void]$clone.ExpandToEnclosingUnit([System.Windows.Automation.Text.TextUnit]::Character)
    $rects = $clone.GetBoundingRectangles()
    if ($rects.Length -ge 1) {
      $r = $rects[0]
      return ('{0},{1},{2},{3}' -f [int]$r.Left, [int]$r.Top, [int]$r.Left, [int]$r.Bottom)
    }
  } catch {}
  return ''
}
`;

const caretBody = (): string => `
$uvPrevious = [UvCaret]::Enter()
if ($uvPrevious -eq 0) { Write-Output 'UVWARN:dpi' }
try {
  $uvResult = [UvCaret]::Read(${process.pid})
  if ($uvResult -eq '') { $uvResult = Get-UvCaretUia ${process.pid} }
  Write-Output $uvResult
} finally { [UvCaret]::Leave($uvPrevious) }
`;

let report: ((message: string) => void) | undefined;
const lastReported = new Map<string, number>();
/** The first failure of each kind is logged, then at most one a minute, so a broken lookup is traceable without flooding the log. */
function noteFailure(kind: string, detail: string): void {
  const now = Date.now();
  const last = lastReported.get(kind);
  if (last !== undefined && now - last < 60_000) return;
  lastReported.set(kind, now);
  report?.(`caret lookup ${kind}: ${detail}`);
}

let host: PowerShellHost | null = null;

/** The caret host: its own process, so a lookup never queues in front of (or behind) a paste. */
function caretHost(log?: (message: string) => void): PowerShellHost {
  host ??= new PowerShellHost({
    spawn: () => spawn('powershell.exe', hostArguments(), { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] }),
    setupScript: CARET_PRELUDE,
    startupTimeoutMs: HOST_STARTUP_TIMEOUT_MS,
    requestTimeoutMs: CARET_HOST_TIMEOUT_MS,
    log,
  });
  return host;
}

/** Start the host ahead of the first dictation, so its C# is already compiled. Safe off Windows. */
export function startCaretHost(log?: (message: string) => void): void {
  report = log;
  if (process.platform !== 'win32') return;
  void caretHost(log).start();
}

/** Stop the host. Safe to call when it never started. */
export function stopCaretHost(): void {
  host?.dispose();
  host = null;
}

export interface CaretFix {
  /** The caret in DIP screen coordinates (zero width is normal). */
  rect: Rect;
  /** The work area of the display the caret is on, in DIP. */
  workArea: Rect;
}

/**
 * The caret of the app in front, or null: nothing found, our own window in front, a rectangle that
 * is not a text caret, one outside every display, or no answer within `CARET_LOOKUP_TIMEOUT_MS`.
 */
export async function lookUpCaret(): Promise<CaretFix | null> {
  if (process.platform !== 'win32') return null;
  try {
    const answer = caretHost().run(caretBody(), { timeoutMs: CARET_HOST_TIMEOUT_MS });
    const output = await new Promise<string | null>((resolve) => {
      const timer = setTimeout(() => {
        noteFailure('timeout', `no answer within ${CARET_LOOKUP_TIMEOUT_MS} ms`);
        resolve(null);
      }, CARET_LOOKUP_TIMEOUT_MS);
      answer.then(
        (text) => {
          clearTimeout(timer);
          resolve(text);
        },
        (error: unknown) => {
          clearTimeout(timer);
          // A late failure is still worth a line: after our own wait ran out this is the only report of why.
          const kind = error instanceof PowerShellHostError ? (error.kind === 'unavailable' ? 'host disabled' : error.kind) : 'script';
          noteFailure(kind, error instanceof Error ? error.message : String(error));
          resolve(null);
        },
      );
    });
    if (output === null) return null;
    const lines = output.trim().split(/\r?\n/);
    if (lines.some((line) => line.startsWith('UVWARN:dpi'))) {
      noteFailure('dpi', 'could not set per-monitor DPI awareness; coordinates may be scaled');
    }
    const answerLine = [...lines].reverse().find((line) => !line.startsWith('UVWARN:')) ?? '';
    const physical = parseCaretLine(answerLine, MIN_CARET_HEIGHT, MAX_CARET_HEIGHT);
    if (!physical) return null;
    const rect = screen.screenToDipRect(null, physical);
    const centre = { x: Math.round(rect.x + rect.width / 2), y: Math.round(rect.y + rect.height / 2) };
    const display = screen.getAllDisplays().find((d) => contains(d.bounds, centre));
    if (!display) return null;
    return { rect, workArea: display.workArea };
  } catch (error) {
    noteFailure('script', error instanceof Error ? error.message : String(error));
    return null;
  }
}

function contains(area: Rect, point: { x: number; y: number }): boolean {
  return point.x >= area.x && point.x < area.x + area.width && point.y >= area.y && point.y < area.y + area.height;
}
