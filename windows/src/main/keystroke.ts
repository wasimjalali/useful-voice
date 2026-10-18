import { createHash } from 'node:crypto';
import type { KeystrokeResult } from '../core/delivery/pasteFlow.js';
import { PowerShellHostError, type RunOptions } from './powershellHost.js';

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
  return `
$uvOwnPid = ${input.ownPid}
$uvAllowOwn = ${input.allowOwnWindow ? '$true' : '$false'}
$uvWant = '${input.clipboardHash}'
$h = [UvForeground]::GetForegroundWindow()
$procId = 0
[void][UvForeground]::GetWindowThreadProcessId($h, [ref]$procId)
$have = 'unreadable'
try {
  $text = Get-Clipboard -Raw
  if ($null -eq $text) { $text = '' }
  $text = $text.Replace(([string][char]13 + [string][char]10), [string][char]10)
  $sha = [Security.Cryptography.SHA256]::Create()
  $have = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '').ToLower()
} catch {}
if ((-not $uvAllowOwn) -and ($procId -eq $uvOwnPid)) {
  Write-Output '${TOKEN.blockedOwn}'
} elseif ($have -ne $uvWant) {
  Write-Output '${TOKEN.blockedClipboard}'
} else {
  $uvShell.SendKeys('^v')
  Write-Output '${TOKEN.sent}'
}
`;
}

/** What the script said, from the last line it printed. Anything unexpected is indeterminate. */
export function parsePasteOutput(stdout: string): 'sent' | 'blocked-own' | 'blocked-clipboard' | 'indeterminate' {
  const last = stdout.trim().split(/\r?\n/).pop()?.trim();
  if (last === TOKEN.sent) return 'sent';
  if (last === TOKEN.blockedOwn) return 'blocked-own';
  if (last === TOKEN.blockedClipboard) return 'blocked-clipboard';
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

export interface HostedGuard {
  signal?: AbortSignal;
  beforeWrite?: () => boolean;
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
  timeoutMs: number,
  guard: HostedGuard = {},
): Promise<string> {
  const { signal, beforeWrite } = guard;
  if (host && !host.isUnavailable) {
    try {
      return await host.run(hostScript, { timeoutMs, signal, beforeWrite });
    } catch (error) {
      if (!(error instanceof PowerShellHostError) || error.sent || error.kind === 'aborted') throw error;
      // Never written (the host would not start, or was given up on): fall through.
    }
  }
  // The same checks as the host makes before it writes: a keystroke script never starts
  // after an abort or once the caller's condition stopped holding.
  if (signal?.aborted || (beforeWrite && !beforeWrite())) {
    throw new PowerShellHostError('aborted', 'aborted before it was sent', false);
  }
  return oneShot(oneShotScript, timeoutMs, signal);
}

export interface SendDeps {
  host: ScriptHost | null;
  oneShot: OneShotRunner;
  /** What a one-shot process needs before the body: the types and `$uvShell`. */
  oneShotPrelude: string;
  timeoutMs: number;
}

export interface SendRequest {
  text: string;
  signal?: AbortSignal;
  canSend: () => boolean;
  allowOwnWindow: boolean;
  ownPid: number;
}

/**
 * Send Ctrl+V if it is still right to, and say what is known about it.
 *
 * `signal` and `canSend` are checked when the request reaches the front of the host's
 * queue, right before it is written, and again before a one-shot process is started. A
 * one-shot process is also killed if the signal aborts while it runs, but that proves
 * nothing, so it is indeterminate.
 */
export async function sendPasteKeystroke(deps: SendDeps, request: SendRequest): Promise<KeystrokeResult> {
  if (request.signal?.aborted || !request.canSend()) return 'blocked';
  const body = pasteScriptBody({
    ownPid: request.ownPid,
    allowOwnWindow: request.allowOwnWindow,
    clipboardHash: clipboardHash(request.text),
  });
  try {
    const stdout = await runHosted(deps.host, deps.oneShot, body, deps.oneShotPrelude + body, deps.timeoutMs, {
      signal: request.signal,
      beforeWrite: request.canSend,
    });
    return parsePasteOutput(stdout);
  } catch (error) {
    // Proven unsent: it never left the queue, or no process ever started.
    if (error instanceof PowerShellHostError && !error.sent) return error.kind === 'aborted' ? 'blocked' : 'failed';
    // Written, or a process was started, and then it ended some other way.
    return 'indeterminate';
  }
}
