/**
 * The PowerShell scripts behind Windows input automation, as plain strings.
 *
 * They live apart from `windowsPlatform.ts` (which imports Electron) so a test can
 * build every one of them and hand it to PowerShell's own parser on Windows
 * (`tests/powershellScripts.test.ts`): a syntax error then fails CI instead of failing
 * silently on a user's machine. Nothing here runs anything.
 *
 * Every script that can send a keystroke or move focus starts with
 * `$ErrorActionPreference = 'Stop'` and wraps its body in try/catch: a failed Add-Type,
 * a failed foreground check or a UI Automation error prints a failure word and never
 * falls through to the keystroke.
 *
 * Handles and numbers are interpolated, so every builder only accepts safe positive
 * integers (`isHandle`); text never goes into a script, it arrives on stdin.
 */

/** Whether `value` is a handle that may be interpolated into a script. */
export function isHandle(value: number | undefined): value is number {
  return value !== undefined && Number.isSafeInteger(value) && value > 0;
}

/** A deadline as an epoch millisecond count PowerShell can compare against. */
function deadlineLine(deadlineEpochMs: number): string {
  const ms = Number.isSafeInteger(deadlineEpochMs) && deadlineEpochMs > 0 ? deadlineEpochMs : 0;
  return `$deadline = [DateTimeOffset]::FromUnixTimeMilliseconds(${ms}).UtcDateTime`;
}

/** The C# a guarded paste needs: the foreground window. */
export const GUARD_CS = `
using System;
using System.Runtime.InteropServices;
public class UvGuard {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}`;

/**
 * Send Ctrl+V, but only while `expectedForeground` is in front and before the deadline.
 * The check and the keystroke run in the same script, so no other window can take the
 * foreground in between. Prints `sent`, `moved`, `timeout` or `failed`.
 */
export function pasteScript(expectedForeground: number, deadlineEpochMs: number): string {
  if (!isHandle(expectedForeground)) throw new Error('pasteScript needs a window handle');
  return `
$ErrorActionPreference = 'Stop'
try {
  Add-Type @"
${GUARD_CS}
"@
  ${deadlineLine(deadlineEpochMs)}
  if ([UvGuard]::GetForegroundWindow() -ne [IntPtr]${expectedForeground}) { Write-Output "moved"; exit 0 }
  if ([DateTime]::UtcNow -ge $deadline) { Write-Output "timeout"; exit 0 }
  $wshell = New-Object -ComObject WScript.Shell
  $wshell.SendKeys("^v")
  Write-Output "sent"
} catch {
  Write-Output "failed"
}
`;
}

/** The C# type-out needs: one SendInput call per batch of UTF-16 units. */
export const TYPE_CS = `
using System;
using System.Runtime.InteropServices;
public class UvType {
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
  [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  public static uint Send(ushort[] units) {
    INPUT[] batch = new INPUT[units.Length * 2];
    for (int k = 0; k < units.Length; k++) {
      int j = k * 2;
      batch[j].type = 1; batch[j].u.ki.wScan = units[k]; batch[j].u.ki.dwFlags = 0x0004;
      batch[j + 1].type = 1; batch[j + 1].u.ki.wScan = units[k]; batch[j + 1].u.ki.dwFlags = 0x0004 | 0x0002;
    }
    return SendInput((uint)batch.Length, batch, Marshal.SizeOf(typeof(INPUT)));
  }
}`;

/**
 * Type batches of UTF-16 units as Unicode keystrokes (`KEYEVENTF_UNICODE`, so the
 * keyboard layout doesn't matter). The batches arrive on stdin, one per line, as
 * comma-separated decimal units: precomputed by `typeOutChunks`, so a batch never
 * splits an emoji, and nothing in the text can be read as PowerShell.
 *
 * Before every batch: the deadline, the target still in front, and no password field
 * (a UI Automation error counts as a password field). Prints `<word>:<units typed>`,
 * the word one of `sent`, `moved`, `secure`, `timeout` or `failed`.
 */
export function typeScript(expectedForeground: number, deadlineEpochMs: number): string {
  if (!isHandle(expectedForeground)) throw new Error('typeScript needs a window handle');
  return `
$ErrorActionPreference = 'Stop'
$typed = 0
try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type @"
${TYPE_CS}
"@
  ${deadlineLine(deadlineEpochMs)}
  $expected = [IntPtr]${expectedForeground}
  $batches = [Console]::In.ReadToEnd().Split([char]10, [StringSplitOptions]::RemoveEmptyEntries)
  foreach ($line in $batches) {
    if ([DateTime]::UtcNow -ge $deadline) { Write-Output "timeout:$typed"; exit 0 }
    if ([UvType]::GetForegroundWindow() -ne $expected) { Write-Output "moved:$typed"; exit 0 }
    $secure = $true
    try {
      $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
      $secure = ($focused -ne $null) -and $focused.Current.IsPassword
    } catch {
      $secure = $true
    }
    if ($secure) { Write-Output "secure:$typed"; exit 0 }
    [uint16[]]$units = $line.Trim().Split(',') | ForEach-Object { [uint16]$_ }
    $sent = [UvType]::Send($units)
    $typed += [math]::Floor($sent / 2)
    if ($sent -ne ($units.Length * 2)) { Write-Output "failed:$typed"; exit 0 }
    Start-Sleep -Milliseconds 5
  }
  Write-Output "sent:$typed"
} catch {
  Write-Output "failed:$typed"
}
`;
}

/** The C# the foreground read needs: window, title, process and focused child. */
export const FOREGROUND_CS = `
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
}`;

/**
 * Which window has focus: handle, process name, process id, focused child and title,
 * separated by the unit separator (parsed by `parseForegroundLine`). Prints nothing on
 * failure.
 */
export function foregroundScript(): string {
  return `
$ErrorActionPreference = 'Stop'
try {
  Add-Type @"
${FOREGROUND_CS}
"@
  $h = [UvForeground]::GetForegroundWindow()
  $len = [UvForeground]::GetWindowTextLength($h)
  $sb = New-Object System.Text.StringBuilder ($len + 1)
  [void][UvForeground]::GetWindowText($h, $sb, $sb.Capacity)
  $procId = 0
  $thread = [UvForeground]::GetWindowThreadProcessId($h, [ref]$procId)
  $focus = [UvForeground]::Focus($thread)
  $name = ""
  try { $name = (Get-Process -Id $procId).ProcessName } catch {}
  # A unit-separator character is used rather than a tab: PowerShell would need a
  # backtick escape for a tab, and the backtick collides with JS template syntax.
  # The title goes last: it is the only field that could ever contain odd characters.
  Write-Output ("{0}{1}{2}{1}{3}{1}{4}{1}{5}" -f $h.ToInt64(), [char]31, $name, $procId, $focus, $sb.ToString())
} catch {
  exit 0
}
`;
}

/** The C# a reactivation needs. */
export const REACTIVATE_CS = `
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
}`;

/** Bring a window (and its focused child) to the front. Prints `ok`, `gone` or `refused`. */
export function reactivateScript(handle: number, focusHandle: number | undefined): string {
  if (!isHandle(handle)) throw new Error('reactivateScript needs a window handle');
  const focus = isHandle(focusHandle) ? focusHandle : 0;
  return `
$ErrorActionPreference = 'Stop'
try {
  Add-Type @"
${REACTIVATE_CS}
"@
  Write-Output ([UvReactivate]::Bring([IntPtr]${handle}, [IntPtr]${focus}))
} catch {
  Write-Output "refused"
}
`;
}

/** Which UI Automation element is the address bar, per browser family. */
export type AddressBarKind = 'chromium' | 'firefox';

/**
 * Read a browser window's address bar with UI Automation. Only the real address bar
 * is accepted: an edit control whose ClassName is `OmniboxViewViews` (Chrome, Edge,
 * Brave) or whose AutomationId is `urlbar-input` (Firefox). Both are fixed internal
 * names, not localised labels, and no other edit control on a page carries them. Any
 * other edit (a search box on the page) is never read. Prints the value as base64 of
 * UTF-8, or nothing.
 */
export function browserAddressScript(handle: number, kind: AddressBarKind): string {
  if (!isHandle(handle)) throw new Error('browserAddressScript needs a window handle');
  const match =
    kind === 'chromium'
      ? `New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'OmniboxViewViews')`
      : `New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'urlbar-input')`;
  return `
$ErrorActionPreference = 'Stop'
try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]${handle})
  $isEdit = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
  $isBar = ${match}
  $cond = New-Object System.Windows.Automation.AndCondition($isEdit, $isBar)
  $edit = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
  if ($edit -eq $null) { exit 0 }
  $value = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
  Write-Output ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value)))
} catch {
  exit 0
}
`;
}

/** The C# a foreground restore needs. */
export const RESTORE_CS = `
using System;
using System.Runtime.InteropServices;
public class UvRestore {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}`;

/**
 * Bring a window back after the language picker closes, only while `onlyIfForeground`
 * (the picker) is still in front. Prints `True`, `False`, `moved`, `gone` or `failed`.
 */
export function restoreForegroundScript(handle: number, onlyIfForeground: number | undefined): string {
  if (!isHandle(handle)) throw new Error('restoreForegroundScript needs a window handle');
  if (onlyIfForeground !== undefined && !isHandle(onlyIfForeground)) {
    throw new Error('restoreForegroundScript needs a window handle to guard on');
  }
  const guard =
    onlyIfForeground === undefined
      ? ''
      : `  # The user clicked somewhere else while this started: leave their choice alone.
  if ([UvRestore]::GetForegroundWindow() -ne [IntPtr]${onlyIfForeground}) { Write-Output "moved"; exit 0 }
`;
  return `
$ErrorActionPreference = 'Stop'
try {
  Add-Type @"
${RESTORE_CS}
"@
  $h = [IntPtr]${handle}
${guard}  if (-not [UvRestore]::IsWindow($h)) { Write-Output "gone"; exit 0 }
  if ([UvRestore]::IsIconic($h)) { [void][UvRestore]::ShowWindow($h, 9) }
  Write-Output ([UvRestore]::SetForegroundWindow($h))
} catch {
  Write-Output "failed"
}
`;
}

/** Play a cue file. The path is quoted for a single-quoted PowerShell string. */
export function cueScript(file: string): string {
  return `(New-Object Media.SoundPlayer '${file.replace(/'/g, "''")}').PlaySync()`;
}

/** Every C# block, for the compile check in `tests/powershellScripts.test.ts`. */
export const CSHARP_BLOCKS = { GUARD_CS, TYPE_CS, FOREGROUND_CS, REACTIVATE_CS, RESTORE_CS } as const;
