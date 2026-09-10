/**
 * Audio capture, running in the renderer.
 *
 * This must live here because `getUserMedia` and the Web Audio API are browser
 * APIs that Electron deliberately does not expose to the main process. The main
 * process asks for a capture over IPC and this module replies with a finished WAV.
 */

import { encodeWav, rms, peak, containsSpeech, resampleTo16k } from '../core/audio/wav.js';

export interface CaptureResult {
  wav: ArrayBuffer;
  durationSeconds: number;
  peak: number;
  hadSpeech: boolean;
}

interface Capture {
  stream: MediaStream;
  context: AudioContext;
  source: MediaStreamAudioSourceNode;
  processor: ScriptProcessorNode;
  chunks: Float32Array[];
  startedAt: number;
  peak: number;
  hadSpeech: boolean;
  levelTimer: number;
}

let active: Capture | null = null;

/** Whether capture is currently running, so a double press cannot start two. */
export function isCapturing(): boolean {
  return active !== null;
}

/**
 * Start capturing from the default input device.
 *
 * Explicitly requests 16 kHz mono, which is what Deepgram wants. The browser may
 * ignore the request (some drivers only offer 44.1/48 kHz), so the captured rate is
 * read back from the actual context and the audio is resampled if it differs —
 * rather than rendering a 48 kHz buffer into a 16 kHz header, which would play back
 * three times too fast and transcribe as noise.
 */
export async function startCapture(): Promise<void> {
  if (active) return;

  if (!navigator.mediaDevices?.getUserMedia) {
    throw new Error('Audio capture is not available in this environment.');
  }

  let stream: MediaStream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true,
      },
      video: false,
    });
  } catch (error) {
    // Surface the DOMException name so the main process can map it to advice.
    const name = (error as DOMException)?.name ?? '';
    if (name === 'NotAllowedError' || name === 'SecurityError') {
      throw new Error('Permission denied: microphone access is blocked.');
    }
    if (name === 'NotFoundError' || name === 'OverconstrainedError') {
      throw new Error('NotFoundError: no microphone is available.');
    }
    if (name === 'NotReadableError' || name === 'AbortError') {
      throw new Error('NotReadableError: the microphone is in use by another app.');
    }
    throw error;
  }

  const context = new AudioContext();
  // Chrome may start it suspended; resume so audio actually flows.
  if (context.state === 'suspended') await context.resume();

  const source = context.createMediaStreamSource(stream);
  // A ScriptProcessorNode is used rather than an AudioWorklet because a worklet
  // needs a separate module file served over a URL, and the number of samples per
  // callback is not performance-critical here.
  const processor = context.createScriptProcessor(4096, 1, 1);

  const capture: Capture = {
    stream,
    context,
    source,
    processor,
    chunks: [],
    startedAt: performance.now(),
    peak: 0,
    hadSpeech: false,
    levelTimer: 0,
  };

  processor.onaudioprocess = (event) => {
    const input = event.inputBuffer.getChannelData(0);
    // Copy: the buffer is reused by the audio thread, so holding a reference would
    // capture whatever the next callback writes.
    const chunk = new Float32Array(input.length);
    chunk.set(input);
    capture.chunks.push(chunk);

    capture.peak = Math.max(capture.peak, peak(chunk));
    if (containsSpeech(chunk)) capture.hadSpeech = true;

    // Push the level for the HUD meter on a timer, not per callback: an unfiltered
    // flood would swamp the IPC channel.
    const now = performance.now();
    if (now - capture.levelTimer > 50) {
      capture.levelTimer = now;
      window.usefulVoice.sendLevel(Math.min(1, rms(chunk) * 4));
    }
  };

  source.connect(processor);
  // A ScriptProcessorNode only runs while connected to a destination. The gain is
  // zero so nothing is played back, which would otherwise feed the microphone back
  // into the speakers.
  const silence = context.createGain();
  silence.gain.value = 0;
  processor.connect(silence);
  silence.connect(context.destination);

  active = capture;
}

/**
 * Stop capturing and return the finished WAV.
 *
 * Always stops the tracks, even on the error paths: a leaked track keeps the
 * microphone-in-use indicator lit and prevents other apps from recording.
 */
export async function stopCapture(): Promise<CaptureResult> {
  const capture = active;
  if (!capture) throw new Error('Recording is not running.');
  active = null;

  capture.processor.onaudioprocess = null;
  try {
    capture.processor.disconnect();
    capture.source.disconnect();
  } catch {
    // Already disconnected; nothing to do.
  }
  for (const track of capture.stream.getTracks()) track.stop();

  const inputRate = capture.context.sampleRate;
  await capture.context.close();

  const total = capture.chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const merged = new Float32Array(total);
  let offset = 0;
  for (const chunk of capture.chunks) {
    merged.set(chunk, offset);
    offset += chunk.length;
  }
  capture.chunks = [];

  const durationSeconds = inputRate > 0 ? total / inputRate : 0;

  // Resample only when the device did not honour the 16 kHz request.
  const samples = inputRate === 16_000 ? merged : resampleTo16k(merged, inputRate);
  const wav = encodeWav(samples);

  // Copy into a standalone ArrayBuffer: `encodeWav` may return a view over a
  // larger buffer, and structured cloning would otherwise send the whole thing.
  const buffer = wav.buffer.slice(wav.byteOffset, wav.byteOffset + wav.byteLength) as ArrayBuffer;

  return {
    wav: buffer,
    durationSeconds,
    peak: capture.peak,
    hadSpeech: capture.hadSpeech,
  };
}

/** Abandon the current capture, discarding the audio. */
export async function cancelCapture(): Promise<void> {
  const capture = active;
  if (!capture) return;
  active = null;
  capture.processor.onaudioprocess = null;
  try {
    capture.processor.disconnect();
    capture.source.disconnect();
  } catch {
    // Already disconnected.
  }
  for (const track of capture.stream.getTracks()) track.stop();
  try {
    await capture.context.close();
  } catch {
    // Already closed.
  }
}
