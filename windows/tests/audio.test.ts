import { describe, expect, it } from 'vitest';
import {
  BYTES_PER_SECOND,
  MINIMUM_AUDIO_BYTES,
  SPEECH_PEAK_THRESHOLD,
  TARGET_SAMPLE_RATE,
  WAV_HEADER_BYTES,
  WavError,
  containsSpeech,
  downmixToMono,
  encodeWav,
  meterLevel,
  peak,
  readWavFormat,
  resampleTo16k,
  rms,
} from '../src/core/audio/wav.js';
import { RecordingClock, SilenceWatchdog, isTooShortToTranscribe } from '../src/core/audio/silenceWatchdog.js';

describe('encodeWav', () => {
  it('writes a well-formed 16 kHz mono 16-bit header', () => {
    const wav = encodeWav(new Float32Array(1600));
    const format = readWavFormat(wav);
    expect(format.sampleRate).toBe(TARGET_SAMPLE_RATE);
    expect(format.channels).toBe(1);
    expect(format.bitsPerSample).toBe(16);
    expect(format.dataBytes).toBe(3200);
    expect(format.durationSeconds).toBeCloseTo(0.1, 5);
  });

  it('produces the expected total length', () => {
    const samples = new Float32Array(1000);
    expect(encodeWav(samples).length).toBe(WAV_HEADER_BYTES + 2000);
  });

  it('writes the RIFF sizes consistently', () => {
    const samples = new Float32Array(500);
    const wav = encodeWav(samples);
    const view = new DataView(wav.buffer);
    expect(String.fromCharCode(...wav.slice(0, 4))).toBe('RIFF');
    expect(String.fromCharCode(...wav.slice(8, 12))).toBe('WAVE');
    expect(view.getUint32(4, true)).toBe(36 + 1000);
    expect(view.getUint32(40, true)).toBe(1000);
  });

  it('clamps samples instead of wrapping them', () => {
    // A value beyond full scale must saturate. Wrapping would turn a loud passage
    // into noise.
    const wav = encodeWav(new Float32Array([2, -2, 0]));
    const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);
    expect(view.getInt16(WAV_HEADER_BYTES, true)).toBe(32767);
    expect(view.getInt16(WAV_HEADER_BYTES + 2, true)).toBe(-32768);
    expect(view.getInt16(WAV_HEADER_BYTES + 4, true)).toBe(0);
  });

  it('encodes silence as zeros', () => {
    const wav = encodeWav(new Float32Array(4));
    const view = new DataView(wav.buffer);
    expect(view.getInt16(WAV_HEADER_BYTES, true)).toBe(0);
  });

  it('matches the documented byte rate', () => {
    const oneSecond = encodeWav(new Float32Array(TARGET_SAMPLE_RATE));
    expect(oneSecond.length - WAV_HEADER_BYTES).toBe(BYTES_PER_SECOND);
  });

  it('handles an empty sample array as a header-only file', () => {
    const wav = encodeWav(new Float32Array(0));
    expect(wav.length).toBe(WAV_HEADER_BYTES);
    expect(readWavFormat(wav).dataBytes).toBe(0);
  });
});

describe('readWavFormat', () => {
  it('rejects a file that is too small', () => {
    expect(() => readWavFormat(new Uint8Array(10))).toThrow(WavError);
  });

  it('rejects a non-RIFF file', () => {
    const notWav = new Uint8Array(WAV_HEADER_BYTES + 4);
    expect(() => readWavFormat(notWav)).toThrow(WavError);
  });

  it('rejects a header declaring zero channels or sample rate', () => {
    const wav = encodeWav(new Float32Array(10));
    const view = new DataView(wav.buffer);
    view.setUint16(22, 0, true);
    expect(() => readWavFormat(wav)).toThrow(WavError);
  });
});

describe('resampleTo16k', () => {
  it('returns the input unchanged when already at the target rate', () => {
    const input = new Float32Array([0.1, 0.2, 0.3]);
    expect(resampleTo16k(input, TARGET_SAMPLE_RATE)).toBe(input);
  });

  it('halves the length when downsampling 32 kHz', () => {
    const input = new Float32Array(3200);
    expect(resampleTo16k(input, 32_000).length).toBe(1600);
  });

  it('uses a length derived from the exact ratio', () => {
    const input = new Float32Array(4800);
    // 48000 -> 16000 is exactly a third.
    expect(resampleTo16k(input, 48_000).length).toBe(1600);
  });

  it('preserves a constant signal', () => {
    const input = new Float32Array(480).fill(0.5);
    const output = resampleTo16k(input, 48_000);
    for (const sample of output) expect(sample).toBeCloseTo(0.5, 6);
  });

  it('rejects a non-positive input rate', () => {
    expect(() => resampleTo16k(new Float32Array(10), 0)).toThrow(WavError);
  });

  it('produces at least one sample for a tiny input', () => {
    expect(resampleTo16k(new Float32Array(1), 44_100).length).toBeGreaterThanOrEqual(1);
  });
});

describe('downmixToMono', () => {
  it('averages two channels', () => {
    const left = new Float32Array([1, 0, -1]);
    const right = new Float32Array([0, 1, 1]);
    const mono = downmixToMono([left, right]);
    expect(Array.from(mono)).toEqual([0.5, 0.5, 0]);
  });

  it('passes a single channel through unchanged', () => {
    const only = new Float32Array([0.25]);
    expect(downmixToMono([only])).toBe(only);
  });

  it('truncates to the shortest channel rather than reading past the end', () => {
    const mono = downmixToMono([new Float32Array([1, 1, 1]), new Float32Array([1])]);
    expect(mono.length).toBe(1);
  });

  it('throws when given no channels', () => {
    expect(() => downmixToMono([])).toThrow(WavError);
  });
});

describe('level measurement', () => {
  it('computes RMS of a known signal', () => {
    expect(rms(new Float32Array([1, -1, 1, -1]))).toBeCloseTo(1, 6);
    expect(rms(new Float32Array([0, 0, 0, 0]))).toBe(0);
  });

  it('returns zero RMS for empty input', () => {
    expect(rms(new Float32Array(0))).toBe(0);
  });

  it('finds the peak magnitude, including negatives', () => {
    expect(peak(new Float32Array([0.1, -0.7, 0.3]))).toBeCloseTo(0.7, 6);
  });

  it('keeps the meter level in range', () => {
    expect(meterLevel(new Float32Array([0, 0]))).toBe(0);
    expect(meterLevel(new Float32Array([5, 5]))).toBeLessThanOrEqual(1);
  });
});

describe('containsSpeech', () => {
  /**
   * The gate exists because a silent clip can make a speech model echo its own
   * prompt bias (the dictionary) back as a fake transcript.
   */
  it('rejects a silent buffer', () => {
    expect(containsSpeech(new Float32Array(1000))).toBe(false);
    expect(containsSpeech(new Float32Array(1000).fill(0.005))).toBe(false);
  });

  it('accepts a buffer with voiced peaks', () => {
    const buffer = new Float32Array(1000).fill(0.001);
    buffer[500] = 0.5;
    expect(containsSpeech(buffer)).toBe(true);
  });

  it('uses the documented threshold', () => {
    // Values are stored as float32, in which 0.02 round-trips to
    // 0.019999999552965164 — below the threshold. Nudge past it so the fixture
    // tests the gate rather than float32 rounding.
    expect(containsSpeech(new Float32Array([SPEECH_PEAK_THRESHOLD + 1e-6]))).toBe(true);
    expect(containsSpeech(new Float32Array([SPEECH_PEAK_THRESHOLD - 0.001]))).toBe(false);
  });
});

describe('SilenceWatchdog', () => {
  it('does not stop while the user is speaking', () => {
    const watchdog = new SilenceWatchdog({ timeoutSeconds: 5 });
    expect(watchdog.observe(0.5, 0)).toBe(false);
    expect(watchdog.observe(0.5, 4)).toBe(false);
  });

  it('stops after the timeout of continuous silence', () => {
    const watchdog = new SilenceWatchdog({ timeoutSeconds: 5 });
    expect(watchdog.observe(0.5, 0)).toBe(false);
    expect(watchdog.observe(0.0, 4)).toBe(false);
    expect(watchdog.observe(0.0, 5)).toBe(true);
  });

  it('resets the silence timer when speech resumes', () => {
    const watchdog = new SilenceWatchdog({ timeoutSeconds: 5 });
    watchdog.observe(0.5, 0);
    watchdog.observe(0.0, 4);
    expect(watchdog.observe(0.5, 4.5)).toBe(false);
    expect(watchdog.observe(0.0, 8)).toBe(false);
    expect(watchdog.observe(0.0, 9.5)).toBe(true);
  });

  /**
   * Measuring silence from the first loud frame would let a user who never speaks
   * leave the recorder running until the hard cap, because `lastLoudAt` stays null.
   */
  it('measures silence from the start when nothing was ever loud', () => {
    const watchdog = new SilenceWatchdog({ timeoutSeconds: 3 });
    expect(watchdog.observe(0, 1)).toBe(false);
    expect(watchdog.observe(0, 3)).toBe(true);
  });

  it('treats a zero timeout as auto-stop disabled', () => {
    const watchdog = new SilenceWatchdog({ timeoutSeconds: 0 });
    expect(watchdog.observe(0, 9999)).toBe(false);
  });

  it('reports how long the silence has lasted', () => {
    const watchdog = new SilenceWatchdog({ timeoutSeconds: 5 });
    watchdog.observe(0.5, 2);
    expect(watchdog.silenceSeconds(6)).toBeCloseTo(4, 6);
  });

  it('resets to an unstarted state', () => {
    const watchdog = new SilenceWatchdog({ timeoutSeconds: 5 });
    watchdog.observe(0.5, 10);
    watchdog.reset();
    expect(watchdog.silenceSeconds(0)).toBe(0);
  });

  it('honours a custom threshold', () => {
    const loud = new SilenceWatchdog({ timeoutSeconds: 5, silenceThreshold: 0.2 });
    expect(loud.observe(0.1, 1)).toBe(false);
    expect(loud.observe(0.1, 6)).toBe(true);
  });
});

describe('RecordingClock', () => {
  /**
   * The hard cap must be enforceable without any buffer arriving. Both the
   * watchdog and the cap used to live only inside the audio callback, so losing
   * buffers left the app recording forever.
   */
  it('reports elapsed time and the limit from a clock, not from buffers', () => {
    let now = 1_000;
    const clock = new RecordingClock(10, () => now);
    clock.start();
    now += 5_000;
    expect(clock.elapsedSeconds()).toBeCloseTo(5, 6);
    expect(clock.isOverLimit()).toBe(false);
    expect(clock.remainingSeconds()).toBeCloseTo(5, 6);
  });

  it('flags the limit once reached', () => {
    let now = 0;
    const clock = new RecordingClock(10, () => now);
    clock.start();
    now += 10_000;
    expect(clock.isOverLimit()).toBe(true);
  });

  it('reports zero and not-over-limit when stopped', () => {
    const clock = new RecordingClock(10, () => Date.now());
    expect(clock.elapsedSeconds()).toBe(0);
    expect(clock.isOverLimit()).toBe(false);
    expect(clock.isRunning).toBe(false);
  });

  it('never reports negative elapsed time if the clock steps backwards', () => {
    let now = 10_000;
    const clock = new RecordingClock(10, () => now);
    clock.start();
    now -= 5_000;
    expect(clock.elapsedSeconds()).toBe(0);
  });
});

describe('isTooShortToTranscribe', () => {
  it('rejects header-only and near-empty audio', () => {
    expect(isTooShortToTranscribe(WAV_HEADER_BYTES, MINIMUM_AUDIO_BYTES)).toBe(true);
    expect(isTooShortToTranscribe(MINIMUM_AUDIO_BYTES - 1, MINIMUM_AUDIO_BYTES)).toBe(true);
  });

  it('accepts a payload at the threshold', () => {
    expect(isTooShortToTranscribe(MINIMUM_AUDIO_BYTES, MINIMUM_AUDIO_BYTES)).toBe(false);
  });
});
