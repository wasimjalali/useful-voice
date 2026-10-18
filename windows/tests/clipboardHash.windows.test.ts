import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { FOREGROUND_TYPE, clipboardHash, parsePasteOutput, pasteScriptBody } from '../src/main/keystroke.js';

/**
 * The paste script's hash against a real Windows clipboard.
 *
 * The script reads `Get-Clipboard -Raw`, normalises line endings to LF and hashes the
 * UTF-8 bytes; the main process hashes the dictation the same way. If the two ever differ
 * (CRLF added by the clipboard, an emoji, right-to-left text, a trailing newline) every
 * paste would be refused as "the clipboard changed". This writes each sample the way
 * Chromium does (CF_UNICODETEXT, which is what `Set-Clipboard` writes) and runs the real
 * script with a stub in place of SendKeys.
 *
 * Skipped off Windows, like the other real-desktop tests, since it needs a real clipboard
 * and Windows PowerShell.
 */
const onWindows = process.platform === 'win32';

/** Stands in for the WScript.Shell object, so no key is ever sent. */
const STUB_SHELL = `
$uvShell = New-Object psobject
$uvShell | Add-Member -MemberType ScriptMethod -Name SendKeys -Value { param($keys) }
`;

function powershell(script: string): string {
  return execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script], {
    encoding: 'utf8',
    timeout: 30_000,
    windowsHide: true,
  });
}

function setClipboard(text: string): void {
  const encoded = Buffer.from(text, 'utf8').toString('base64');
  powershell(`Set-Clipboard -Value ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded}')))`);
}

function runPasteScript(dictation: string): string {
  const body = pasteScriptBody({
    ownPid: process.pid,
    // Our own process is the foreground in no case here, but the guard is not under test.
    allowOwnWindow: true,
    clipboardHash: clipboardHash(dictation),
  });
  return powershell(FOREGROUND_TYPE + STUB_SHELL + body);
}

const SAMPLES: Array<[string, string]> = [
  ['CRLF line endings', 'first line\r\nsecond line\r\nthird'],
  ['LF line endings', 'first line\nsecond line'],
  ['an emoji', 'ship it \u{1F680} today \u{1F600}'],
  ['Dari text', 'سلام دنیا، این یک آزمون است.'],
  ['a trailing newline', 'ends with a newline\n'],
  ['a leading newline and a blank line', '\nstarts blank\n\nthen text'],
  ['mixed text', 'café سلام \u{1F680}\r\nline two\n'],
];

describe.skipIf(!onWindows)('the paste script hash on a real Windows clipboard', () => {
  it.each(SAMPLES)('matches the main process hash for %s', (_name, text) => {
    setClipboard(text);
    expect(parsePasteOutput(runPasteScript(text))).toBe('sent');
  });

  it('refuses text that differs, trailing newline included', () => {
    setClipboard('ends with a newline');
    expect(parsePasteOutput(runPasteScript('ends with a newline\n'))).toBe('blocked-clipboard');
  });

  it('does not block on an unrelated process id when the guard is on', () => {
    // Whoever is in the foreground while the test runs is not process 1, so the guard stays
    // quiet and the matching hash is enough to send.
    setClipboard('hello');
    const body = pasteScriptBody({ ownPid: 1, allowOwnWindow: false, clipboardHash: clipboardHash('hello') });
    expect(parsePasteOutput(powershell(FOREGROUND_TYPE + STUB_SHELL + body))).toBe('sent');
  });
});
