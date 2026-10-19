import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { CHIME_RECIPES, CHIME_SAMPLE_RATE, chimeWav, renderChime } from '../src/core/audio/chimeSynth.js';
import { readWavFormat } from '../src/core/audio/wav.js';

// How a cue can fail: a header SoundPlayer rejects, a click at either edge, clipping or a cue
// too quiet to hear, a first sound that lags the hotkey, a tail that drags on, start and stop
// sounding the same, left and right swapped, or Windows drifting from macOS (the fixture holds
// the shared recipe and a loudness fingerprint that ChimeSynthTests.swift checks too).

const fixture = JSON.parse(
  readFileSync(
    path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'Tests', 'Fixtures', 'chimes', 'cues.json'),
    'utf8',
  ),
) as {
  recipes: typeof CHIME_RECIPES;
  fingerprint: Record<'start' | 'stop', { left: number[]; right: number[] }>;
};

const kinds = ['start', 'stop'] as const;
const channel = (samples: Int16Array, side: 0 | 1) => samples.filter((_, index) => index % 2 === side);

describe('chime synth', () => {
  it.each(kinds)('%s is a stereo 16-bit 44.1 kHz WAV', (kind) => {
    const wav = chimeWav(kind);
    const format = readWavFormat(wav);
    expect(format).toMatchObject({ sampleRate: 44_100, channels: 2, bitsPerSample: 16, dataBytes: wav.length - 44 });
    const view = new DataView(wav.buffer);
    expect(view.getUint32(4, true)).toBe(wav.length - 8);
    expect(view.getUint32(28, true)).toBe(44_100 * 4);
    expect(view.getUint16(32, true)).toBe(4);
  });

  it.each(kinds)('%s has no click at either edge, a safe level and a prompt, short sound', (kind) => {
    const samples = renderChime(CHIME_RECIPES[kind]);
    for (const value of [samples[0], samples[1], samples.at(-2), samples.at(-1)]) {
      expect(Math.abs(value as number)).toBeLessThan(200);
    }
    const peak = samples.reduce((max, value) => Math.max(max, Math.abs(value)), 0);
    expect(peak).toBeGreaterThan(2_600); // above -22 dBFS
    expect(peak).toBeLessThan(8_200); // below -12 dBFS
    const first = samples.findIndex((value) => Math.abs(value) > 300);
    expect(Math.floor(first / 2) / CHIME_SAMPLE_RATE).toBeLessThan(0.025);
    expect(samples.length / 2 / CHIME_SAMPLE_RATE).toBeLessThanOrEqual(0.7);
  });

  it('start and stop differ', () => {
    expect(Buffer.from(chimeWav('start')).equals(Buffer.from(chimeWav('stop')))).toBe(false);
  });

  it('the start boop sits on the right and its echo on the left', () => {
    const samples = renderChime(CHIME_RECIPES.start);
    const energy = (from: number, to: number, side: 0 | 1) =>
      channel(samples, side)
        .slice(Math.trunc(from * CHIME_SAMPLE_RATE), Math.trunc(to * CHIME_SAMPLE_RATE))
        .reduce((sum, value) => sum + value * value, 0);
    expect(energy(0.14, 0.19, 1)).toBeGreaterThan(energy(0.14, 0.19, 0) * 4);
    expect(energy(0.27, 0.32, 0)).toBeGreaterThan(energy(0.27, 0.32, 1) * 4);
  });

  it('the recipes match the fixture macOS uses', () => {
    expect(CHIME_RECIPES).toEqual(fixture.recipes);
  });

  it.each(kinds)('%s renders within 1 dB of the shared fingerprint', (kind) => {
    const samples = renderChime(CHIME_RECIPES[kind]);
    for (const [side, key] of [[0, 'left'], [1, 'right']] as const) {
      const values = channel(samples, side);
      const levels: number[] = [];
      for (let start = 0; start < values.length; start += 882) {
        const block = values.slice(start, start + 882);
        const mean = block.reduce((sum, value) => sum + (value / 32_768) ** 2, 0) / block.length;
        levels.push(Math.max(-90, 10 * Math.log10(mean + 1e-12)));
      }
      const expected = fixture.fingerprint[kind][key];
      expect(levels).toHaveLength(expected.length);
      levels.forEach((level, index) => expect(Math.abs(level - (expected[index] as number))).toBeLessThanOrEqual(1));
    }
  });
});
