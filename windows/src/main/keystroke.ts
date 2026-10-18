import { createHash } from 'node:crypto';
import type { Authorization, KeystrokeResult } from '../core/delivery/pasteFlow.js';
import { PowerShellHostError, type RunOptions } from './powershellHost.js';

/** The C# behind the foreground-window reads, compiled once in the host and per call in a one-shot process. */
export const FOREGROUND_TYPE = `
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
`;

/**
 * Sending Ctrl+V through PowerShell, and knowing afterwards what is and is not known.
 *
 * This file imports nothing from Electron, so the boundary cases (a request that is
 * written and then aborted, a one-shot process that is killed while it starts, a host
 * that dies mid-request) are tested with fakes on any platform.
 *
 * What the outcome means:
 *  - The script prints one token. `UVSENT`, `UVBLOCKED:own` and `UVBLOCKED:clipboard`
 *    are certain.
 *  - A request that never left the queue, or was refused by `canSend`, or a one-shot
 *    process that never started, is certainly unsent.
 *  - Anything else after the request was written or a process was started (abort,
 *    timeout, script error, process death) is INDETERMINATE: the key may have gone out.
 *    An abort after the write therefore does not need to kill the host, and nothing here
 *    pretends it proves anything.
 */

/** The last line the paste script prints. */
const TOKEN = {
  sent: 'UVSENT',
  blockedOwn: 'UVBLOCKED:own',
  blockedClipboard: 'UVBLOCKED:clipboard',
  blockedUnreadable: 'UVBLOCKED:unreadable',
} as const;

/** SHA-256 of the dictation as the script computes it: UTF-8, line endings as LF. */
export function clipboardHash(text: string): string {
  return createHash('sha256').update(text.replace(/\r\n/g, '\n'), 'utf8').digest('hex');
}

export interface PasteScriptInput {
  /** Our own process id: the script sends nothing while that process owns the foreground window. */
  ownPid: number;
  /** The dictation started in our window, so the foreground check is skipped. */
  allowOwnWindow: boolean;
  /** `clipboardHash` of the dictation. The text itself never goes into a script. */
  clipboardHash: string;
}

/**
 * The script that checks and sends Ctrl+V. Assumes `UvForeground` and `$uvShell` exist
 * (the host's setup, or the one-shot prelude).
 *
 * Both checks run immediately before `SendKeys`, in the same script, because the
 * foreground window and the clipboard change while a request waits: the foreground
 * process must not be ours (unless the dictation started in our window), and the
 * clipboard text must still hash to the dictation. The only values interpolated are a
 * validated integer, a boolean and a validated hex string.
 */
export function pasteScriptBody(input: PasteScriptInput): string {
  if (!Number.isSafeInteger(input.ownPid) || input.ownPid <= 0) throw new Error('invalid process id');
  if (!/^[0-9a-f]{64}$/.test(input.clipboardHash)) throw new Error('invalid clipboard hash');
  // The order is deliberate: the clipboard is read and hashed first, and the foreground
  // window only afterwards, so the pid that is checked is the one that will receive the
  // key, with nothing slow between the read and SendKeys.
  return `
$uvOwnPid = ${input.ownPid}
$uvAllowOwn = ${input.allowOwnWindow ? '$true' : '$false'}
$uvWant = '${input.clipboardHash}'
$have = $null
try {
  $text = Get-Clipboard -Raw
  if ($null -eq $text) { $text = '' }
  $text = $text.Replace(([string][char]13 + [string][char]10), [string][char]10)
  $sha = [Security.Cryptography.SHA256]::Create()
  $have = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLower()
} catch {}
$h = [UvForeground]::GetForegroundWindow()
$procId = 0
[void][UvForeground]::GetWindowThreadProcessId($h, [ref]$procId)
if ($null -eq $have) {
  Write-Output '${TOKEN.blockedUnreadable}'
} elseif ($have -ne $uvWant) {
  Write-Output '${TOKEN.blockedClipboard}'
} elseif ((-not $uvAllowOwn) -and ($procId -eq $uvOwnPid)) {
  Write-Output '${TOKEN.blockedOwn}'
} else {
  $uvShell.SendKeys('^v')
  Write-Output '${TOKEN.sent}'
}
`;
}

/** What the script said, from the last line it printed. Anything unexpected is indeterminate. */
export function parsePasteOutput(
  stdout: string,
): 'sent' | 'blocked-own' | 'blocked-clipboard' | 'blocked-unreadable' | 'indeterminate' {
  const last = stdout.trim().split(/\r?\n/).pop()?.trim();
  if (last === TOKEN.sent) return 'sent';
  if (last === TOKEN.blockedOwn) return 'blocked-own';
  if (last === TOKEN.blockedClipboard) return 'blocked-clipboard';
  if (last === TOKEN.blockedUnreadable) return 'blocked-unreadable';
  return 'indeterminate';
}

/** The part of the PowerShell host this file uses. */
export interface ScriptHost {
  readonly isUnavailable: boolean;
  run(script: string, options: RunOptions): Promise<string>;
}

/**
 * Run a script in a fresh process. Throws a `PowerShellHostError` with `sent: false` only
 * when the process never started; any other failure means it ran or may have.
 */
export type OneShotRunner = (script: string, timeoutMs: number, signal?: AbortSignal) => Promise<string>;

/**
 * A text-field check older than this no longer justifies pasting into our own window: the
 * focus may have moved since. The check runs right before the request is written, so on the
 * warm host it is milliseconds old; a cold one-shot process takes far longer and never gets
 * the permission.
 */
export const OWN_FIELD_FRESH_MS = 300;

export interface Timeouts {
  /** The limit on a request written to the warm host. */
  hostMs: number;
  /** The limit on a one-shot process: a cold powershell.exe, the C# compile, the work. */
  oneShotMs: number;
}

/**
 * Run a script in the PowerShell host, or in a one-shot process when there is none.
 *
 * `hostScript` assumes the host's setup has run; `oneShotScript` carries everything it
 * needs itself. The fallback is taken only for a request that never reached the host: a
 * request that was written and then timed out or died may already have run, and running
 * a paste twice is worse than not at all.
 */
export async function runHosted(
  host: ScriptHost | null,
  oneShot: OneShotRunner,
  hostScript: string,
  oneShotScript: string,
  timeouts: Timeouts,
  signal?: AbortSignal,
): Promise<string> {
  if (host && !host.isUnavailable) {
    try {
      return await host.run(hostScript, { timeoutMs: timeouts.hostMs, signal });
    } catch (error) {
      if (!(error instanceof PowerShellHostError) || error.sent || error.kind === 'aborted') throw error;
      // Never written (the host would not start, or was given up on): fall through.
    }
  }
  if (signal?.aborted) throw new PowerShellHostError('aborted', 'aborted before it was sent', false);
  return oneShot(oneShotScript, timeouts.oneShotMs, signal);
}

/** The same limit for the host and for a one-shot process: for reads, which are never slow. */
export function readTimeouts(ms: number): Timeouts {
  return { hostMs: ms, oneShotMs: ms };
}

/**
 * Decides at the last moment what to send: the script, or false to send nothing. `oneShot`
 * tells it the script will run in a cold process, which starts far too slowly to rely on
 * anything it checked just now.
 */
export type Prepare = (context: { oneShot: boolean }) => string | false | Promise<string | false>;

/**
 * Like `runHosted` for a script that is decided at the last moment. `prepare` runs when the
 * request reaches the front of the host's queue, or just before a one-shot process is
 * started, and its answer is what is sent. A refusal is `aborted` and unsent.
 */
export async function runPrepared(
  host: ScriptHost | null,
  oneShot: OneShotRunner,
  oneShotPrelude: string,
  prepare: Prepare,
  timeouts: Timeouts,
  signal?: AbortSignal,
): Promise<string> {
  if (host && !host.isUnavailable) {
    try {
      return await host.run('', { timeoutMs: timeouts.hostMs, signal, prepare: () => prepare({ oneShot: false }) });
    } catch (error) {
      if (!(error instanceof PowerShellHostError) || error.sent || error.kind === 'aborted') throw error;
      // Never written: fall through to a one-shot process, after preparing again.
    }
  }
  if (signal?.aborted) throw new PowerShellHostError('aborted', 'aborted before it was sent', false);
  let script: string | false;
  try {
    script = await prepare({ oneShot: true });
  } catch {
    script = false;
  }
  // The preparing can take time (a look at the window): the signal may have aborted.
  if (script === false || signal?.aborted) {
    throw new PowerShellHostError('aborted', 'aborted before it was sent', false);
  }
  return oneShot(oneShotPrelude + script, timeouts.oneShotMs, signal);
}

export interface SendDeps {
  host: ScriptHost | null;
  oneShot: OneShotRunner;
  /** What a one-shot process needs before the body: the types and `$uvShell`. */
  oneShotPrelude: string;
  timeouts: Timeouts;
}

export interface SendRequest {
  text: string;
  signal?: AbortSignal;
  /** Asked at the last moment; the script is built from the answer. */
  authorize: () => Authorization | Promise<Authorization>;
  ownPid: number;
}

/**
 * Send Ctrl+V if it is still right to, and say what is known about it.
 *
 * The script is built at the last moment, from `authorize`, so the own-process guard is
 * lifted only for a check that has just passed. A one-shot process is killed if the
 * signal aborts while it runs, but that proves nothing, so it is indeterminate.
 */
export async function sendPasteKeystroke(deps: SendDeps, request: SendRequest): Promise<KeystrokeResult> {
  if (request.signal?.aborted) return 'blocked';
  const hash = clipboardHash(request.text);
  const build = (authorization: Authorization, oneShot: boolean): string | false => {
    if (authorization === false) return false;
    // The own-process guard is lifted only for a text-field check that is still fresh, and
    // never for a cold process, which cannot send before the check has gone stale. The script
    // itself re-checks the foreground pid and the clipboard just before SendKeys.
    const fresh = authorization.checkedAt !== undefined && Date.now() - authorization.checkedAt <= OWN_FIELD_FRESH_MS;
    return pasteScriptBody({
      ownPid: request.ownPid,
      allowOwnWindow: authorization.allowOwnWindow && fresh && !oneShot,
      clipboardHash: hash,
    });
  };
  const prepare: Prepare = ({ oneShot }) => {
    const authorization = request.authorize();
    return authorization instanceof Promise
      ? authorization.then((answer) => build(answer, oneShot))
      : build(authorization, oneShot);
  };
  try {
    const stdout = await runPrepared(deps.host, deps.oneShot, deps.oneShotPrelude, prepare, deps.timeouts, request.signal);
    return parsePasteOutput(stdout);
  } catch (error) {
    // Proven unsent: it never left the queue, or no process ever started.
    if (error instanceof PowerShellHostError && !error.sent) return error.kind === 'aborted' ? 'blocked' : 'failed';
    // Written, or a process was started, and then it ended some other way.
    return 'indeterminate';
  }
}
