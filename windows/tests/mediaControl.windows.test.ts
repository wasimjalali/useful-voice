import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  MEDIA_PRELUDE,
  listPlayingScript,
  parsePausedOutput,
  parsePlayingOutput,
  pauseScript,
  resumeScript,
} from '../src/main/mediaScripts.js';

/**
 * The media scripts against real Windows PowerShell 5.1 and the real Global System Media
 * Transport Controls. Skipped off Windows, like the other real-desktop tests.
 *
 * It proves, on any Windows machine, that every script parses, the WinRT manager loads, the
 * AsTask await works and the session list comes back (possibly empty). Then it makes a
 * genuine media session of its own (a MediaPlayer looping a silent WAV in a child
 * PowerShell, which Windows lists like any app) and drives list, pause and resume against
 * it. It never touches anything the person is playing: only the id of the session it made.
 * A runner that cannot create a session (no audio device, a locked-down desktop) skips that
 * test with a message, so the skip is visible in the report.
 */
const onWindows = process.platform === 'win32';

function powershell(script: string): string {
  return execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script], {
    encoding: 'utf8',
    timeout: 60_000,
    windowsHide: true,
  });
}

/** Half a second of 8 kHz mono silence: enough for a MediaPlayer to hold a session when looped. */
function silentWav(): Buffer {
  const samples = 4000;
  const buffer = Buffer.alloc(44 + samples, 0x80);
  buffer.write('RIFF', 0, 'ascii');
  buffer.writeUInt32LE(36 + samples, 4);
  buffer.write('WAVEfmt ', 8, 'ascii');
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(8000, 24);
  buffer.writeUInt32LE(8000, 28);
  buffer.writeUInt16LE(1, 32);
  buffer.writeUInt16LE(8, 34);
  buffer.write('data', 36, 'ascii');
  buffer.writeUInt32LE(samples, 40);
  return buffer;
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

async function until<T>(read: () => T, ok: (value: T) => boolean, timeoutMs: number): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let value = read();
  while (!ok(value) && Date.now() < deadline) {
    await sleep(500);
    value = read();
  }
  return value;
}

describe.skipIf(!onWindows)('the media scripts on real Windows', () => {
  it('parse as PowerShell', () => {
    const scripts = [
      MEDIA_PRELUDE,
      MEDIA_PRELUDE + listPlayingScript(),
      MEDIA_PRELUDE + pauseScript(['Spotify.exe', "it's"]),
      MEDIA_PRELUDE + resumeScript([{ id: 'Spotify.exe', settled: { position: 5, updated: 6 } }, { id: "it's" }]),
    ];
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
`,
    );
    expect(output).toMatch(/UVCOUNT:\d+/);
    // And the real list-playing script runs to the end and prints only lines we can parse.
    expect(() => parsePlayingOutput(powershell(MEDIA_PRELUDE + listPlayingScript()))).not.toThrow();
  });

  it('resumes nothing for an id no session has', () => {
    expect(powershell(MEDIA_PRELUDE + resumeScript([{ id: 'no-such-app-id-for-this-test' }]))).toContain('UVRESUMED:0');
  });

  it('lists, pauses and resumes a real session: Playing, then Paused, then Playing', async (context) => {
    const directory = mkdtempSync(path.join(os.tmpdir(), 'uv-media-test-'));
    const wav = path.join(directory, 'silence.wav');
    writeFileSync(wav, silentWav());
    const uri = `file:///${wav.replace(/\\/g, '/').replace(/'/g, "''")}`;

    const playing = (): Map<string, { position: number; updated: number }> =>
      new Map(parsePlayingOutput(powershell(MEDIA_PRELUDE + listPlayingScript())).map((s) => [s.id, s]));
    const before = new Set(playing().keys());

    // A real media session: MediaPlayer integrates with the transport controls by itself.
    const child = spawn(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        `
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Playback.MediaPlayer,Windows.Media.Playback,ContentType=WindowsRuntime]
$null = [Windows.Media.Core.MediaSource,Windows.Media.Core,ContentType=WindowsRuntime]
$p = New-Object Windows.Media.Playback.MediaPlayer
$p.IsLoopingEnabled = $true
$p.Source = [Windows.Media.Core.MediaSource]::CreateFromUri([Uri]'${uri}')
$p.Play()
Write-Output 'UVPLAYER:started'
[Console]::Out.Flush()
[void][Console]::In.ReadLine()
$p.Dispose()
`,
      ],
      { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] },
    );
    let started = false;
    child.stdout.on('data', (chunk: Buffer) => {
      if (chunk.toString().includes('UVPLAYER:started')) started = true;
    });
    try {
      await until(() => started, Boolean, 20_000);
      const during = await until(playing, (now) => [...now.keys()].some((id) => !before.has(id)), 20_000);
      const id = [...during.keys()].find((candidate) => !before.has(candidate));
      if (!started || !id) {
        console.warn('SKIPPED: this machine could not create a media session (no audio device or a locked-down desktop)');
        context.skip();
        return;
      }

      // Playing: list-playing sees it, with a timeline.
      expect(during.get(id)).toMatchObject({ id });

      // Paused: pause answers with the timeline after the pause, and the session leaves the list.
      const paused = parsePausedOutput(powershell(MEDIA_PRELUDE + pauseScript([id])));
      expect(paused.map((s) => s.id)).toEqual([id]);
      const afterPause = await until(playing, (now) => !now.has(id), 10_000);
      expect(afterPause.has(id)).toBe(false);

      // Playing again: resume plays it, as it is still Paused and untouched.
      const settled = paused[0] ? { position: paused[0].position, updated: paused[0].updated } : undefined;
      expect(powershell(MEDIA_PRELUDE + resumeScript([{ id, settled }]))).toContain('UVRESUMED:1');
      const afterResume = await until(playing, (now) => now.has(id), 10_000);
      expect(afterResume.has(id)).toBe(true);

      // A session that is already Playing is left alone by a second resume.
      expect(powershell(MEDIA_PRELUDE + resumeScript([{ id, settled }]))).toContain('UVRESUMED:0');
    } finally {
      try {
        child.stdin.write('quit\n');
      } catch {
        // Already gone.
      }
      await sleep(300);
      child.kill();
      rmSync(directory, { recursive: true, force: true });
    }
  }, 120_000);
});
