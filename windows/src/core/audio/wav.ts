/**
 * WAV encoding and PCM conversion for 16 kHz mono Int16 audio.
 *
 * This is the format the recorder produces and the transcription endpoint
 * expects. It is kept pure (no Web Audio, no Node buffers in the API) so it can be
 * tested directly.
 */

export const TARGET_SAMPLE_RATE = 16_000;
export const TARGET_CHANNELS = 1;
/** 16 kHz * 1 channel * 2 bytes = 32 000 bytes per second. */
export const BYTES_PER_SECOND = TARGET_SAMPLE_RATE * TARGET_CHANNELS * 2;
export const MAX_RECORDING_SECONDS = 600;
export const WAV_HEADER_BYTES = 44;

/** The smallest payload worth sending: a fraction of a second of audio. */
export const MINIMUM_AUDIO_BYTES = WAV_HEADER_BYTES + 3200;

export class WavError extends Error {}

/**
 * Encode Float32 samples in [-1, 1] as a 16-bit mono PCM WAV file.
 *
 * Values outside [-1, 1] are clamped rather than wrapped: wrapping would turn a
 * loud passage into noise, and a clipped sample is far less damaging to a
 * transcript than a sign-flipped one.
 */
export function encodeWav(samples: Float32Array, sampleRate = TARGET_SAMPLE_RATE): Uint8Array {
  const dataBytes = samples.length * 2;
  const buffer = new ArrayBuffer(WAV_HEADER_BYTES + dataBytes);
  const view = new DataView(buffer);

  writeAscii(view, 0, 'RIFF');
  // RIFF chunk size is everything after this field: 36 + data bytes.
  view.setUint32(4, 36 + dataBytes, true);
  writeAscii(view, 8, 'WAVE');

  writeAscii(view, 12, 'fmt ');
  view.setUint32(16, 16, true);            // PCM fmt chunk size
  view.setUint16(20, 1, true);             // PCM
  view.setUint16(22, TARGET_CHANNELS, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * TARGET_CHANNELS * 2, true); // byte rate
  view.setUint16(32, TARGET_CHANNELS * 2, true);              // block align
  view.setUint16(34, 16, true);            // bits per sample

  writeAscii(view, 36, 'data');
  view.setUint32(40, dataBytes, true);

  for (let i = 0; i < samples.length; i += 1) {
    const sample = samples[i] as number;
    const clamped = sample < -1 ? -1 : sample > 1 ? 1 : sample;
    // Asymmetric scaling: the Int16 range is -32768..32767.
    const scaled = clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff;
    view.setInt16(WAV_HEADER_BYTES + i * 2, Math.round(scaled), true);
  }

  return new Uint8Array(buffer);
}

/**
 * Read a WAV file's format header.
 *
 * Used to verify a produced file before it is uploaded: a header that disagrees
 * with the declared format is the difference between a transcript and a
 * meaningless one.
 */
export interface WavFormat {
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  dataBytes: number;
  durationSeconds: number;
}

export function readWavFormat(bytes: Uint8Array): WavFormat {
  if (bytes.length < WAV_HEADER_BYTES) {
    throw new WavError('Audio file is too small to be a WAV file.');
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (readAscii(view, 0, 4) !== 'RIFF' || readAscii(view, 8, 4) !== 'WAVE') {
    throw new WavError('Audio file is not a RIFF/WAVE file.');
  }
  const channels = view.getUint16(22, true);
  const sampleRate = view.getUint32(24, true);
  const bitsPerSample = view.getUint16(34, true);
  const dataBytes = view.getUint32(40, true);
  if (channels === 0 || sampleRate === 0) {
    throw new WavError('Audio file declares an unusable format.');
  }
  const bytesPerSecond = sampleRate * channels * (bitsPerSample / 8);
  return {
    sampleRate,
    channels,
    bitsPerSample,
    dataBytes,
    durationSeconds: bytesPerSecond > 0 ? dataBytes / bytesPerSecond : 0,
  };
}

function writeAscii(view: DataView, offset: number, value: string): void {
  for (let i = 0; i < value.length; i += 1) {
    view.setUint8(offset + i, value.charCodeAt(i));
  }
}

function readAscii(view: DataView, offset: number, length: number): string {
  let out = '';
  for (let i = 0; i < length; i += 1) {
    out += String.fromCharCode(view.getUint8(offset + i));
  }
  return out;
}

/**
 * Resample Float32 audio to 16 kHz by linear interpolation.
 *
 * Linear interpolation is deliberately chosen over a windowed-sinc resampler: the
 * input already comes from the microphone at 44.1/48 kHz, the target is speech
 * recognition rather than music, and the small amount of aliasing is far below
 * what the model cares about. Simplicity here keeps the whole path testable.
 */
export function resampleTo16k(samples: Float32Array, inputRate: number): Float32Array {
  if (inputRate === TARGET_SAMPLE_RATE) return samples;
  if (inputRate <= 0) throw new WavError('Input sample rate must be positive.');

  const ratio = TARGET_SAMPLE_RATE / inputRate;
  const outputLength = Math.max(1, Math.floor(samples.length * ratio));
  const output = new Float32Array(outputLength);
  const lastIndex = samples.length - 1;

  for (let i = 0; i < outputLength; i += 1) {
    const position = i / ratio;
    const lower = Math.floor(position);
    const upper = Math.min(lower + 1, lastIndex);
    const weight = position - lower;
    const a = samples[Math.min(lower, lastIndex)] as number;
    const b = samples[upper] as number;
    output[i] = a + (b - a) * weight;
  }
  return output;
}

/** Downmix interleaved or per-channel frames to a single mono channel. */
export function downmixToMono(channels: readonly Float32Array[]): Float32Array {
  if (channels.length === 0) throw new WavError('No audio channels supplied.');
  if (channels.length === 1) return channels[0] as Float32Array;

  const length = Math.min(...channels.map((channel) => channel.length));
  const output = new Float32Array(length);
  for (let i = 0; i < length; i += 1) {
    let sum = 0;
    for (const channel of channels) sum += channel[i] as number;
    output[i] = sum / channels.length;
  }
  return output;
}

/** Root-mean-square level, for the HUD meter and the silence watchdog. */
export function rms(samples: Float32Array): number {
  if (samples.length === 0) return 0;
  let sum = 0;
  for (let i = 0; i < samples.length; i += 1) {
    const sample = samples[i] as number;
    sum += sample * sample;
  }
  return Math.sqrt(sum / samples.length);
}

/** Peak absolute sample, for the speech gate. */
export function peak(samples: Float32Array): number {
  let maximum = 0;
  for (let i = 0; i < samples.length; i += 1) {
    const magnitude = Math.abs(samples[i] as number);
    if (magnitude > maximum) maximum = magnitude;
  }
  return maximum;
}

/**
 * Peak at or above which a buffer counts as containing speech.
 *
 * Gated on PEAK rather than the buffer-averaged RMS the watchdog uses: a soft
 * word's RMS can average below the silence line and be washed out, while its
 * voiced peaks still stand clear of room tone. 0.02 sits in the gap — low enough
 * for a quiet speaker or a low-gain microphone, high enough to reject a genuinely
 * silent clip. Silence must be rejected because a silent clip can make a speech
 * model echo its own prompt bias (the dictionary) back as a fake transcript.
 */
export const SPEECH_PEAK_THRESHOLD = 0.02;

/** Whether a buffer contains speech rather than room tone. */
export function containsSpeech(samples: Float32Array): boolean {
  return peak(samples) >= SPEECH_PEAK_THRESHOLD;
}

/** Level 0..1 for the visual meter, from RMS. */
export function meterLevel(samples: Float32Array): number {
  const value = rms(samples);
  // ~0.5 is already very loud speech; scaling keeps the meter responsive in the
  // normal speaking range instead of sitting near zero.
  return Math.max(0, Math.min(1, value * 3));
}
