import { ProviderError } from '../transcription/deepgramProvider.js';
import { DEEPGRAM_LANGUAGES } from '../transcription/languages.js';
import type { ParakeetVersion } from './parakeet.js';

/** The files a Parakeet model folder must hold (sherpa-onnx int8 release). */
export const PARAKEET_FILES = ['encoder.int8.onnx', 'decoder.int8.onnx', 'joiner.int8.onnx', 'tokens.txt'] as const;

export function parakeetArchiveUrl(version: ParakeetVersion): string {
  return `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-${version}-int8.tar.bz2`;
}

/** Parakeet TDT 0.6B v3: the 25 European languages NVIDIA lists. */
export const PARAKEET_V3_LANGUAGES: readonly string[] = [
  'bg', 'hr', 'cs', 'da', 'nl', 'en', 'et', 'fi', 'fr', 'de', 'el', 'hu', 'it',
  'lv', 'lt', 'mt', 'pl', 'pt', 'ro', 'sk', 'sl', 'es', 'sv', 'ru', 'uk',
];

function languageName(code: string): string {
  return DEEPGRAM_LANGUAGES.find((l) => l.code.toLowerCase() === code.toLowerCase())?.name ?? code;
}

/**
 * Fail fast when the pinned language isn't one the model speaks. `auto` (and `multi`) always
 * pass: Parakeet picks the language itself. Returns the pin to report, or null for auto.
 */
export function checkParakeetLanguage(version: ParakeetVersion, language: string | undefined): string | null {
  const pin = (language ?? 'auto').trim();
  if (pin === '' || pin === 'auto' || pin === 'multi') return null;
  const base = pin.toLowerCase().split(/[-_]/)[0] ?? '';
  if (version === 'v2') {
    if (base === 'en') return pin;
    throw new ProviderError(
      'badRequest',
      `Parakeet v2 only speaks English. Pick another voice model or switch the language to English.`,
    );
  }
  if (PARAKEET_V3_LANGUAGES.includes(base)) return pin;
  throw new ProviderError(
    'badRequest',
    `Parakeet v3 doesn't speak ${languageName(pin)}. Pick another voice model or switch the language.`,
  );
}

export interface ParsedWav {
  samples: Float32Array;
  sampleRate: number;
  durationSeconds: number;
}

/** Read our 16 kHz mono 16-bit PCM WAV into Float32 samples in [-1, 1). */
export function parseWavToFloat32(bytes: Uint8Array): ParsedWav {
  const bad = (m: string) => new ProviderError('badRequest', `Can't read the recording: ${m}`);
  if (bytes.length < 12) throw bad('the audio is too short to be a WAV file.');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const tag = (o: number) => String.fromCharCode(bytes[o]!, bytes[o + 1]!, bytes[o + 2]!, bytes[o + 3]!);
  if (tag(0) !== 'RIFF' || tag(8) !== 'WAVE') throw bad('it is not a WAV file.');

  let format: { code: number; channels: number; rate: number; bits: number } | null = null;
  let offset = 12;
  while (offset + 8 <= bytes.length) {
    const id = tag(offset);
    const declared = view.getUint32(offset + 4, true);
    const body = offset + 8;
    if (id === 'fmt ') {
      if (body + 16 > bytes.length) throw bad('the format header is cut off.');
      format = {
        code: view.getUint16(body, true),
        channels: view.getUint16(body + 2, true),
        rate: view.getUint32(body + 4, true),
        bits: view.getUint16(body + 14, true),
      };
    } else if (id === 'data') {
      if (!format) throw bad('the data comes before the format header.');
      if (format.code !== 1 || format.bits !== 16) throw bad('only 16-bit PCM audio is supported.');
      if (format.channels !== 1) throw bad('only mono audio is supported.');
      if (format.rate !== 16000) throw bad('only 16 kHz audio is supported.');
      // A streamed file can declare 0 or too large a size; trust the bytes that are there.
      const available = bytes.length - body;
      const length = Math.min(declared === 0 ? available : declared, available) & ~1;
      const count = length / 2;
      const samples = new Float32Array(count);
      for (let i = 0; i < count; i += 1) samples[i] = view.getInt16(body + i * 2, true) / 32768;
      return { samples, sampleRate: format.rate, durationSeconds: count / format.rate };
    }
    offset = body + declared + (declared % 2);
  }
  throw bad('it has no audio data.');
}
