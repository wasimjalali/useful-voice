import { describe, expect, it } from 'vitest';
import { TOUCH_TOLERANCE_MS } from '../src/core/media/mediaPausePolicy.js';
import {
  MEDIA_PRELUDE,
  encodeSessionIds,
  listPlayingScript,
  parsePausedOutput,
  parsePlayingOutput,
  pauseScript,
  resumeScript,
} from '../src/main/mediaScripts.js';

const b64 = (text: string): string => Buffer.from(text, 'utf8').toString('base64');

describe('parsePlayingOutput', () => {
  it('decodes ids and timelines and ignores anything else the script printed', () => {
    const out = ['noise', `UVPLAYING:${b64('Spotify.exe')}:12000:1700000000000`, 'UVSKIP:session', `UVPLAYING:${b64('MSEdge')}:0:-62135596800000\r`].join('\r\n');
    expect(parsePlayingOutput(out)).toEqual([
      { id: 'Spotify.exe', position: 12000, updated: 1700000000000 },
      { id: 'MSEdge', position: 0, updated: -62135596800000 },
    ]);
  });

  it('returns an empty list for no sessions', () => {
    expect(parsePlayingOutput('')).toEqual([]);
  });

  it('drops lines that are not strict, and duplicates', () => {
    const out = [
      `UVPLAYING:${b64('a')}:1:2`,
      'UVPLAYING:not base64!:1:2',
      `UVPLAYING:${b64('b')}:one:2`,
      `UVPLAYING:${b64('c')}`,
      `UVPLAYING:${b64('a')}:9:9`,
    ].join('\n');
    expect(parsePlayingOutput(out)).toEqual([{ id: 'a', position: 1, updated: 2 }]);
  });
});

describe('parsePausedOutput', () => {
  it('reads the post-pause timeline and ignores UVPLAYING lines', () => {
    const out = [`UVPLAYING:${b64('x')}:1:1`, `UVPAUSED:${b64('Spotify.exe')}:5000:77`].join('\n');
    expect(parsePausedOutput(out)).toEqual([{ id: 'Spotify.exe', position: 5000, updated: 77 }]);
  });
});

describe('encodeSessionIds', () => {
  it('encodes each id on its own, comma separated', () => {
    expect(encodeSessionIds(['Spotify.exe', 'Chrome'])).toBe(`${b64('Spotify.exe')},${b64('Chrome')}`);
  });

  it('encodes hostile text so it cannot leave its quotes', () => {
    const hostile = `'; Remove-Item C:\\ -Recurse; '`;
    const encoded = encodeSessionIds([hostile]);
    expect(encoded).toMatch(/^[A-Za-z0-9+/=,]+$/);
    expect(Buffer.from(encoded, 'base64').toString('utf8')).toBe(hostile);
  });

  it('refuses an empty list, an empty id and an absurd number of ids', () => {
    expect(() => encodeSessionIds([])).toThrow();
    expect(() => encodeSessionIds([''])).toThrow();
    expect(() => encodeSessionIds(Array.from({ length: 65 }, (_, i) => `id${i}`))).toThrow();
    expect(() => encodeSessionIds(['x'.repeat(2000)])).toThrow();
  });
});

describe('the scripts', () => {
  const hostile = `evil'$(calc)"\`n`;

  it('put no raw id into the pause or resume script, only base64', () => {
    for (const script of [pauseScript([hostile, 'Spotify.exe']), resumeScript([{ id: hostile }, { id: 'Spotify.exe' }])]) {
      expect(script).not.toContain(hostile);
      expect(script).not.toContain('calc');
      expect(script).toContain(b64('Spotify.exe'));
    }
  });

  it('carry the timeline into the resume script as plain numbers only', () => {
    const script = resumeScript([{ id: 'a', settled: { position: 1234.6, updated: 99 } }, { id: 'b' }]);
    expect(script).toContain(`${b64('a')}:1235:99`);
    expect(script).toContain(`${b64('b')}:n:n`);
    expect(() => resumeScript([{ id: 'a', settled: { position: Number.NaN, updated: 1 } }])).toThrow();
    expect(() => resumeScript([{ id: 'a', settled: { position: 1e30, updated: 1 } }])).toThrow();
  });

  it('list only what is Playing, and change nothing', () => {
    const script = listPlayingScript();
    expect(script).toContain("'Playing'");
    expect(script).not.toContain('TryPauseAsync');
    expect(script).not.toContain('TryPlayAsync');
  });

  it('pause only what is Playing, and read the timeline after the pause', () => {
    const script = pauseScript(['a']);
    expect(script).toContain("'Playing'");
    expect(script).toContain('TryPauseAsync');
    expect(script.indexOf('Start-Sleep')).toBeGreaterThan(script.indexOf('TryPauseAsync'));
    expect(script.indexOf('UVPAUSED')).toBeGreaterThan(script.indexOf('Start-Sleep'));
  });

  it('resume only what is Paused and untouched, with the same tolerance as the policy', () => {
    const script = resumeScript([{ id: 'a' }]);
    expect(script).toContain("'Paused'");
    expect(script).toContain('TryPlayAsync');
    expect(script).toContain(`-gt ${TOUCH_TOLERANCE_MS}`);
  });

  it("skip Useful Voice's own sessions when listing, and refuse an app id with odd characters", () => {
    expect(listPlayingScript()).toContain("'ai.useful.voice'");
    expect(() => listPlayingScript("x'; calc; '")).toThrow();
  });

  it('load the WinRT manager the documented way', () => {
    expect(MEDIA_PRELUDE).toContain('GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime');
    expect(MEDIA_PRELUDE).toContain('System.WindowsRuntimeSystemExtensions');
    expect(MEDIA_PRELUDE).toContain('RequestAsync');
  });

  it('have no backtick, which would collide with the template literals they are built from', () => {
    for (const script of [MEDIA_PRELUDE, listPlayingScript(), pauseScript(['a']), resumeScript([{ id: 'a' }])]) {
      expect(script.includes('`')).toBe(false);
    }
  });
});
