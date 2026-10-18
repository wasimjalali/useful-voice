import { describe, expect, it } from 'vitest';
import {
  MEDIA_PRELUDE,
  encodeSessionIds,
  parsePausedOutput,
  pausePlayingScript,
  resumeScript,
} from '../src/main/mediaScripts.js';

const b64 = (text: string): string => Buffer.from(text, 'utf8').toString('base64');

describe('parsePausedOutput', () => {
  it('decodes the ids the script paused and ignores anything else it printed', () => {
    const out = ['noise', `UVPAUSED:${b64('Spotify.exe')}`, 'UVSKIP:some session threw', `UVPAUSED:${b64('MSEdge')}\r`].join('\r\n');
    expect(parsePausedOutput(out)).toEqual(['Spotify.exe', 'MSEdge']);
  });

  it('returns an empty list for no sessions', () => {
    expect(parsePausedOutput('')).toEqual([]);
  });

  it('drops lines that are not strict base64, and duplicates', () => {
    const out = [`UVPAUSED:${b64('a')}`, 'UVPAUSED:not base64!', 'UVPAUSED:', `UVPAUSED:${b64('a')}`].join('\n');
    expect(parsePausedOutput(out)).toEqual(['a']);
  });
});

describe('encodeSessionIds', () => {
  it('encodes each id on its own, comma separated', () => {
    expect(encodeSessionIds(['Spotify.exe', 'Chrome'])).toBe(`${b64('Spotify.exe')},${b64('Chrome')}`);
  });

  it('refuses nothing it can encode, however hostile the text', () => {
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
  it('put no raw id into the resume script, only base64', () => {
    const hostile = `evil'$(calc)"\`n`;
    const script = resumeScript([hostile, 'Spotify.exe']);
    expect(script).not.toContain(hostile);
    expect(script).not.toContain('calc');
    expect(script).toContain(b64('Spotify.exe'));
  });

  it('pause only what is Playing and resume only what is Paused', () => {
    expect(pausePlayingScript()).toContain("'Playing'");
    expect(pausePlayingScript()).toContain('TryPauseAsync');
    expect(resumeScript(['a'])).toContain("'Paused'");
    expect(resumeScript(['a'])).toContain('TryPlayAsync');
  });

  it('skip Useful Voice\'s own sessions when pausing', () => {
    expect(pausePlayingScript()).toContain("'ai.useful.voice'");
  });

  it('load the WinRT manager the documented way', () => {
    expect(MEDIA_PRELUDE).toContain('GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime');
    expect(MEDIA_PRELUDE).toContain('System.WindowsRuntimeSystemExtensions');
    expect(MEDIA_PRELUDE).toContain('RequestAsync');
  });

  it('have no backtick, which would collide with the template literals they are built from', () => {
    for (const script of [MEDIA_PRELUDE, pausePlayingScript(), resumeScript(['a']), 'x']) {
      expect(script.includes('`')).toBe(false);
    }
  });
});
