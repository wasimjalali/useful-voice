import { execFileSync } from 'node:child_process';
import { describe, expect, it } from 'vitest';
import { MEDIA_PRELUDE, parsePausedOutput, pausePlayingScript, resumeScript } from '../src/main/mediaScripts.js';

/**
 * The media scripts against real Windows PowerShell 5.1 and the real Global System Media
 * Transport Controls. Skipped off Windows, like the other real-desktop tests.
 *
 * What it can prove on any Windows machine, with or without anything playing: every script
 * parses, the WinRT manager loads, the AsTask await works, and the session list comes back
 * (possibly empty). It deliberately does not pause anything the person is playing: the
 * pause script runs only when no session is Playing, and the resume script is given an id
 * no session has.
 */
const onWindows = process.platform === 'win32';

function powershell(script: string): string {
  return execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script], {
    encoding: 'utf8',
    timeout: 60_000,
    windowsHide: true,
  });
}

describe.skipIf(!onWindows)('the media scripts on real Windows', () => {
  it('parse as PowerShell', () => {
    const scripts = [MEDIA_PRELUDE, MEDIA_PRELUDE + pausePlayingScript(), MEDIA_PRELUDE + resumeScript(['Spotify.exe', "it's"])];
    for (const script of scripts) {
      const encoded = Buffer.from(script, 'utf8').toString('base64');
      const errors = powershell(
        `$t = $null; $e = $null; [void][System.Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${encoded}')), [ref]$t, [ref]$e); $e.Count`,
      );
      expect(errors.trim()).toBe('0');
    }
  });

  it('loads the session manager and lists sessions, possibly none', () => {
    const output = powershell(
      MEDIA_PRELUDE +
        `
$sessions = @(Get-UvMediaSessions)
Write-Output ('UVCOUNT:' + $sessions.Count)
foreach ($s in $sessions) { Write-Output ('UVSESSION:' + $s.SourceAppUserModelId + ':' + $s.GetPlaybackInfo().PlaybackStatus.ToString()) }
`,
    );
    expect(output).toMatch(/UVCOUNT:\d+/);
  });

  it('pauses nothing and resumes nothing when nothing is Playing or listed', () => {
    const listing = powershell(
      MEDIA_PRELUDE + `foreach ($s in @(Get-UvMediaSessions)) { Write-Output ('UVSESSION:' + $s.GetPlaybackInfo().PlaybackStatus.ToString()) }`,
    );
    // Never interrupt the person's real music from a test run.
    if (/UVSESSION:Playing/.test(listing)) return;
    expect(parsePausedOutput(powershell(MEDIA_PRELUDE + pausePlayingScript()))).toEqual([]);
    expect(powershell(MEDIA_PRELUDE + resumeScript(['no-such-app-id-for-this-test']))).toContain('UVRESUMED:0');
  });
});
