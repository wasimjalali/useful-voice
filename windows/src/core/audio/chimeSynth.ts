/**
 * The start/stop dictation cues, rendered as stereo 16-bit 44.1 kHz WAV files.
 *
 * Each cue is a soft woody tap (a low thump gliding down plus a short airy click), a
 * rounded "boop", and quieter, darker echoes of the boop about every 130 ms, panned
 * between left and right. Start boops on C5; stop is lower and quieter, on G3 and B3,
 * and leans left. Mirrors `Sources/UsefulVoiceCore/Audio/ChimeSynth.swift`; both are
 * checked against `Tests/Fixtures/chimes/cues.json`.
 */

export const CHIME_SAMPLE_RATE = 44_100;
export const CHIME_SECONDS = 0.62;
/** When the tap starts. Keeps the first sample silent without delaying the cue. */
const ONSET = 0.006;

export interface ChimePartial {
  ratio: number;
  weight: number;
  /** Scaled by each boop's brightness, so later echoes lose it first. */
  darkens: boolean;
}

export interface ChimeBoop {
  time: number;
  frequency: number;
  gain: number;
  /** -1 is full left, 1 full right (constant power). */
  pan: number;
  brightness: number;
}

export interface ChimeRecipe {
  thumpStart: number;
  thumpEnd: number;
  thumpDecay: number;
  thumpAmp: number;
  clickAmp: number;
  clickDecay: number;
  hold: number;
  release: number;
  boopAmp: number;
  partials: ChimePartial[];
  boops: ChimeBoop[];
}

export const CHIME_RECIPES: Record<'start' | 'stop', ChimeRecipe> = {
  start: {
    thumpStart: 240, thumpEnd: 100, thumpDecay: 0.022, thumpAmp: 0.17,
    clickAmp: 0.032, clickDecay: 0.016, hold: 0.05, release: 0.007, boopAmp: 0.12,
    partials: [
      { ratio: 1, weight: 1, darkens: false },
      { ratio: 2, weight: 0.02, darkens: false },
      { ratio: 4.03, weight: 0.32, darkens: true },
    ],
    boops: [
      { time: 0.014, frequency: 523.25, gain: 0.16, pan: -0.15, brightness: 1 },
      { time: 0.136, frequency: 523.25, gain: 1, pan: 0.65, brightness: 0.12 },
      { time: 0.266, frequency: 523.25, gain: 0.2, pan: -0.65, brightness: 0.04 },
      { time: 0.396, frequency: 523.25, gain: 0.03, pan: 0.65, brightness: 0.01 },
    ],
  },
  stop: {
    thumpStart: 280, thumpEnd: 95, thumpDecay: 0.022, thumpAmp: 0.15,
    clickAmp: 0.03, clickDecay: 0.008, hold: 0.045, release: 0.008, boopAmp: 0.12,
    partials: [
      { ratio: 1, weight: 1, darkens: false },
      { ratio: 2, weight: 0.35, darkens: false },
      { ratio: 3, weight: 0.05, darkens: true },
      { ratio: 4.3, weight: 0.04, darkens: true },
    ],
    boops: [
      { time: 0.014, frequency: 196.0, gain: 0.42, pan: -0.15, brightness: 1 },
      { time: 0.136, frequency: 246.94, gain: 0.2, pan: -0.4, brightness: 0.3 },
      { time: 0.266, frequency: 196.0, gain: 0.09, pan: -0.25, brightness: 0.1 },
      { time: 0.396, frequency: 246.94, gain: 0.05, pan: -0.4, brightness: 0.05 },
    ],
  },
};

/** Interleaved left/right samples. */
export function renderChime(recipe: ChimeRecipe): Int16Array {
  const sampleRate = CHIME_SAMPLE_RATE;
  const count = Math.trunc(CHIME_SECONDS * sampleRate);
  const left = new Float64Array(count);
  const right = new Float64Array(count);
  const onsetIndex = Math.trunc(ONSET * sampleRate);

  // Thump: a sine gliding down from thumpStart to thumpEnd, with a 12 ms swell, a 30 ms
  // hold, a quick decay and a faint long tail so it never ends dry.
  let phase = 0;
  for (let n = onsetIndex; n < count; n += 1) {
    const t = (n - onsetIndex) / sampleRate;
    const frequency = recipe.thumpEnd + (recipe.thumpStart - recipe.thumpEnd) * Math.exp(-t / 0.006);
    if (n > onsetIndex) phase += (2 * Math.PI * frequency) / sampleRate;
    const swell = t < 0.012 ? 0.5 - 0.5 * Math.cos((Math.PI * t) / 0.012) : 1;
    const after = Math.max(t - 0.03, 0);
    const envelope = swell * (0.92 * Math.exp(-after / recipe.thumpDecay) + 0.08 * Math.exp(-after / 0.16));
    const value = 0.75 * recipe.thumpAmp * envelope * Math.sin(phase);
    left[n] = (left[n] as number) + value;
    right[n] = (right[n] as number) + value;
  }

  // Click: seeded noise band-limited to about 1-6 kHz, so it reads as a tap, not a hiss.
  const lowpass = 1 - Math.exp((-2 * Math.PI * 6_000) / sampleRate);
  const highpass = 1 - Math.exp((-2 * Math.PI * 1_000) / sampleRate);
  let seed = 0x5eed;
  let smooth = 0;
  let slow = 0;
  const clickLength = Math.min(Math.trunc(0.05 * sampleRate), count - onsetIndex);
  for (let i = 0; i < clickLength; i += 1) {
    seed = (Math.imul(seed, 1_664_525) + 1_013_904_223) >>> 0;
    const raw = seed / 2_147_483_648 - 1;
    smooth += lowpass * (raw - smooth);
    slow += highpass * (smooth - slow);
    const t = i / sampleRate;
    const envelope = Math.min(t / 0.001, 1) * Math.exp(-t / recipe.clickDecay);
    const value = 0.75 * recipe.clickAmp * envelope * (smooth - slow);
    left[onsetIndex + i] = (left[onsetIndex + i] as number) + value;
    right[onsetIndex + i] = (right[onsetIndex + i] as number) + value;
  }

  // Boops: a 3 ms rounded attack, a flat hold, then a short exponential release.
  const attack = 0.003;
  for (const boop of recipe.boops) {
    const first = Math.trunc(boop.time * sampleRate);
    if (first >= count) continue;
    const angle = ((boop.pan + 1) * Math.PI) / 4;
    const gainLeft = Math.cos(angle);
    const gainRight = Math.sin(angle);
    const weights = recipe.partials.map((p) => (p.darkens ? p.weight * boop.brightness : p.weight));
    for (let i = 0; i < count - first; i += 1) {
      const t = i / sampleRate;
      let envelope: number;
      if (t < attack) {
        envelope = 0.5 - 0.5 * Math.cos((Math.PI * t) / attack);
      } else if (t > attack + recipe.hold) {
        envelope = Math.exp(-(t - attack - recipe.hold) / recipe.release);
        if (envelope < 1e-6) break;
      } else {
        envelope = 1;
      }
      let tone = 0;
      recipe.partials.forEach((partial, index) => {
        tone += (weights[index] as number) * Math.sin(2 * Math.PI * boop.frequency * partial.ratio * t);
      });
      const value = boop.gain * recipe.boopAmp * envelope * tone;
      left[first + i] = (left[first + i] as number) + value * gainLeft;
      right[first + i] = (right[first + i] as number) + value * gainRight;
    }
  }

  // A 30 ms fade so the last sample is silent.
  const fade = Math.trunc(0.03 * sampleRate);
  for (let i = 0; i < fade; i += 1) {
    const gain = 0.5 + 0.5 * Math.cos((Math.PI * i) / fade);
    left[count - fade + i] = (left[count - fade + i] as number) * gain;
    right[count - fade + i] = (right[count - fade + i] as number) * gain;
  }

  const samples = new Int16Array(count * 2);
  for (let n = 0; n < count; n += 1) {
    samples[n * 2] = Math.round(Math.max(-1, Math.min(1, left[n] as number)) * 32_767);
    samples[n * 2 + 1] = Math.round(Math.max(-1, Math.min(1, right[n] as number)) * 32_767);
  }
  return samples;
}

/** Standard 44-byte WAV header (PCM, stereo, 16-bit) plus interleaved samples. */
export function chimeWav(kind: 'start' | 'stop'): Uint8Array {
  const samples = renderChime(CHIME_RECIPES[kind]);
  const dataBytes = samples.length * 2;
  const view = new DataView(new ArrayBuffer(44 + dataBytes));
  const ascii = (offset: number, value: string) => {
    for (let i = 0; i < value.length; i += 1) view.setUint8(offset + i, value.charCodeAt(i));
  };
  ascii(0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, true);                      // fmt chunk size
  view.setUint16(20, 1, true);                       // PCM
  view.setUint16(22, 2, true);                       // stereo
  view.setUint32(24, CHIME_SAMPLE_RATE, true);
  view.setUint32(28, CHIME_SAMPLE_RATE * 4, true);   // byte rate
  view.setUint16(32, 4, true);                       // block align
  view.setUint16(34, 16, true);                      // bits per sample
  ascii(36, 'data');
  view.setUint32(40, dataBytes, true);
  samples.forEach((sample, index) => view.setInt16(44 + index * 2, sample, true));
  return new Uint8Array(view.buffer);
}
