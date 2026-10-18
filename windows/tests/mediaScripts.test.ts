import { describe, expect, it } from 'vitest';
import { TOUCH_TOLERANCE_MS } from '../src/core/media/mediaPausePolicy.js';
import {
  MEDIA_PRELUDE,
  encodeSessionIds,
  listPlayingScript,
  parsePauseOutput,
  parsePlayingOutput,
  parseResumeOutput,
  parseTimelineOutput,
  PAUSE_WAIT_MS,
  PAUSE_WAIT_QUITTING_MS,
  pauseScript,
  resumeScript,
  timelineScript,
} from '../src/main/mediaScripts.js';

const b64 = (text: string): string => Buffer.from(text, 'utf8').toString('base64');

describe('parsePlayingOutput', () => {
  it('decodes ids and timelines and ignores anything else the script printed', () => {
    const out = ['noise', `UVPLAYING:${b64('Spotify.exe')}:12000:1700000000000`, 'UVSKIP:-', `UVPLAYING:${b64('MSEdge')}:0:-62135596800000\r`].join('\r\n');
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

describe('parsePauseOutput', () => {
  it('reads confirmed sessions with their timeline and the ones Windows refused', () => {
    const out = [`UVPLAYING:${b64('x')}:1:1`, `UVPAUSED:${b64('Spotify.exe')}:5000:77`, `UVREFUSED:${b64('Chrome')}`, 'UVSKIP:-'].join('\n');
    expect(parsePauseOutput(out)).toEqual({ confirmed: [{ id: 'Spotify.exe', position: 5000, updated: 77 }], refused: ['Chrome'], skipped: [] });
  });

  it('names a session whose pause could not finish, and ignores a skip with no id', () => {
    const out = [`UVSKIP:${b64('Edge')}`, 'UVSKIP:-', 'UVSKIP:'].join('\n');
    expect(parsePauseOutput(out)).toEqual({ confirmed: [], refused: [], skipped: ['Edge'] });
  });

  it('reports nothing for an empty answer, which the caller must not mistake for success', () => {
    expect(parsePauseOutput('')).toEqual({ confirmed: [], refused: [], skipped: [] });
  });
});

describe('parseResumeOutput', () => {
  it('refuses output without the closing UVRESUMED line: the script did not finish', () => {
    expect(() => parseResumeOutput('')).toThrow('did not finish');
    expect(() => parseResumeOutput(`UVTOUCHED:${b64('a')}`)).toThrow('did not finish');
    expect(() => parseResumeOutput('UVERR:something broke')).toThrow('did not finish');
  });

  it('accepts it with Windows line endings and the sessions it left alone', () => {
    expect(parseResumeOutput(`UVTOUCHED:${b64('a')}\r\nUVRESUMED:0\r\n`)).toEqual({ refused: [], touched: ['a'], unconfirmed: [] });
  });
});

describe('parseTimelineOutput and parseResumeOutput', () => {
  it('read their own tags only', () => {
    expect(parseTimelineOutput(`UVTIMELINE:${b64('a')}:10:20\nUVPAUSED:${b64('b')}:1:1`)).toEqual([{ id: 'a', position: 10, updated: 20 }]);
    const out = [`UVREFUSED:${b64('a')}`, `UVTOUCHED:${b64('b')}`, `UVUNCONFIRMED:${b64('c')}`, 'UVRESUMED:2', 'UVTOUCHED:!!'].join('\n');
    expect(parseResumeOutput(out)).toEqual({ refused: ['a'], touched: ['b'], unconfirmed: ['c'] });
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
    for (const script of [pauseScript([hostile, 'Spotify.exe']), resumeScript([{ id: hostile, confirmed: true, requestedAt: 1 }, { id: 'Spotify.exe', confirmed: true, requestedAt: 1 }])]) {
      expect(script).not.toContain(hostile);
      expect(script).not.toContain('calc');
      expect(script).toContain(b64('Spotify.exe'));
    }
  });

  it('carry the timeline into the resume script as plain numbers only', () => {
    const script = resumeScript([
      { id: 'a', confirmed: true, requestedAt: 1700, settled: { position: 1234.6, updated: 99 } },
      { id: 'b', confirmed: false, requestedAt: 1800 },
    ]);
    expect(script).toContain(`${b64('a')}:1:1235:99:1700`);
    expect(script).toContain(`${b64('b')}:0:n:n:1800`);
    const base = { id: 'a', confirmed: true, requestedAt: 1 };
    expect(() => resumeScript([{ ...base, settled: { position: Number.NaN, updated: 1 } }])).toThrow();
    expect(() => resumeScript([{ ...base, settled: { position: 1e30, updated: 1 } }])).toThrow();
    expect(() => resumeScript([{ ...base, requestedAt: Number.NaN }])).toThrow();
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
    expect(script).toContain('UVPAUSED');
    // Windows saying no is reported, not swallowed.
    expect(script).toContain('UVREFUSED');
    // The settle wait lives in the app now, where quitting can cut it short.
    expect(script).not.toContain('Start-Sleep');
  });

  it('cap each WinRT call in a pause at 1.5 s, and at 1 s once quitting', () => {
    expect(pauseScript(['a'])).toContain(`$uvWaitMs = ${PAUSE_WAIT_MS}`);
    expect(pauseScript(['a'], { quitting: true })).toContain(`$uvWaitMs = ${PAUSE_WAIT_QUITTING_MS}`);
    expect(PAUSE_WAIT_QUITTING_MS).toBeLessThan(PAUSE_WAIT_MS);
    // Every script sets its own cap: a host keeps variables between requests.
    for (const script of [listPlayingScript(), timelineScript(['a']), resumeScript([{ id: 'a', confirmed: true, requestedAt: 1 }])]) {
      expect(script).toContain('$uvWaitMs = 3000');
    }
  });

  it('resume only what is Paused, untouched and confirmed, with the same tolerance as the policy', () => {
    const script = resumeScript([{ id: 'a', confirmed: true, requestedAt: 1 }]);
    expect(script).toContain('UVUNCONFIRMED');
    expect(script).toContain('UVTOUCHED');
    expect(script).toContain('UVREFUSED');
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
    for (const script of [MEDIA_PRELUDE, listPlayingScript(), pauseScript(['a']), resumeScript([{ id: 'a', confirmed: true, requestedAt: 1 }]), timelineScript(['a'])]) {
      expect(script.includes('`')).toBe(false);
    }
  });
});
