import { describe, expect, it } from 'vitest';
import { DictationService, type CapturedAudio, type RecorderPort } from '../src/main/dictationService.js';
import { MediaPausePolicy, type MediaEffects } from '../src/core/media/mediaPausePolicy.js';
import { DEFAULT_SETTINGS, emptySnapshot } from '../src/core/models.js';

/**
 * The real dictation service and the real media policy, with a scripted recorder and a
 * scripted player: for every way a recording can end, what was paused plays again, and it
 * does so before transcription finishes.
 */
const audio: CapturedAudio = { wav: new Uint8Array(64_000), durationSeconds: 2, peak: 0.5, hadSpeech: true };

class Recorder implements RecorderPort {
  startError: Error | null = null;
  stopError: Error | null = null;
  startGate: Promise<void> | null = null;
  async start(): Promise<void> {
    if (this.startGate) await this.startGate;
    if (this.startError) throw this.startError;
  }
  async stop(): Promise<CapturedAudio> {
    if (this.stopError) throw this.stopError;
    return audio;
  }
  async cancel(): Promise<void> {}
}

function setup() {
  const status: Record<string, 'Playing' | 'Paused'> = { spotify: 'Playing', edge: 'Playing', idle: 'Paused' };
  const calls: string[] = [];
  const effects: MediaEffects = {
    async listPlaying() {
      calls.push('list');
      return Object.keys(status)
        .filter((id) => status[id] === 'Playing')
        .map((id) => ({ id, position: 0, updated: 0 }));
    },
    async pause(ids) {
      calls.push('pause');
      const done = [];
      for (const id of ids) {
        if (status[id] !== 'Playing') continue;
        status[id] = 'Paused';
        done.push({ id, position: 0, updated: 0 });
      }
      return done;
    },
    async resume(held) {
      calls.push('resume');
      for (const { id } of held) if (status[id] === 'Paused') status[id] = 'Playing';
    },
  };
  const logs: string[] = [];
  const media = new MediaPausePolicy({ effects, enabled: () => true, log: (m) => logs.push(m), graceMs: 10 });
  const recorder = new Recorder();
  let releaseTranscript: (() => void) | null = null;
  const service = new DictationService({
    recorder,
    // Never answers until released: resuming must not wait for it.
    transcriber: {
      transcribe: () =>
        new Promise((resolve) => {
          releaseTranscript = () => resolve({ text: 'hello world', durationSeconds: 1, detectedLanguage: null });
        }),
    },
    sink: { deliver: async () => ({ delivered: true, clipboardFallback: false }) },
    settings: () => DEFAULT_SETTINGS,
    memory: () => emptySnapshot(),
    apiKey: async () => 'key',
    onStatus: () => undefined,
    onRecording: (event) => (event === 'start' ? media.recordingStarted() : media.recordingEnded()),
    deliveryTimeoutMs: 200,
    deliveryGraceMs: 50,
  });
  return { service, recorder, media, status, calls, logs, release: () => releaseTranscript?.() };
}

const allPlaying = { spotify: 'Playing', edge: 'Playing', idle: 'Paused' };

describe('media while dictating, through the dictation service', () => {
  it('pauses at the press and plays again at stop, before the transcript arrives', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.media.settled();
    expect(ctx.status).toEqual({ spotify: 'Paused', edge: 'Paused', idle: 'Paused' });
    const processing = ctx.service.stopAndProcess();
    await new Promise((resolve) => setTimeout(resolve, 0));
    await ctx.media.settled();
    expect(ctx.service.currentState).toBe('transcribing');
    expect(ctx.status).toEqual(allPlaying);
    ctx.release();
    await processing;
  });

  it('plays again after a forced stop (the recording limit)', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'hotkey' });
    const stopping = ctx.service.forceStop('Recording limit reached.');
    await new Promise((resolve) => setTimeout(resolve, 0));
    await ctx.media.settled();
    expect(ctx.status).toEqual(allPlaying);
    ctx.release();
    await stopping;
  });

  it('plays again after Esc during the recording', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'window' });
    await ctx.media.settled();
    await ctx.service.cancel();
    await ctx.media.settled();
    expect(ctx.status).toEqual(allPlaying);
  });

  it('plays again after Esc while the recorder is still starting', async () => {
    const ctx = setup();
    let open!: () => void;
    ctx.recorder.startGate = new Promise<void>((resolve) => {
      open = resolve;
    });
    const starting = ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.cancel();
    open();
    await starting;
    await ctx.media.settled();
    expect(ctx.status).toEqual(allPlaying);
  });

  it('plays again when the recorder fails to start', async () => {
    const ctx = setup();
    ctx.recorder.startError = new Error('Permission denied: microphone access is blocked.');
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.media.settled();
    expect(ctx.service.currentState).toBe('error');
    expect(ctx.status).toEqual(allPlaying);
  });

  it('plays again when the recorder dies mid-recording', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.media.settled();
    await ctx.service.recorderFailed(new Error('device unplugged'));
    await ctx.media.settled();
    expect(ctx.status).toEqual(allPlaying);
  });

  it('plays again when stopping the recorder fails', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'hotkey' });
    ctx.recorder.stopError = new Error('device gone');
    await ctx.service.stopAndProcess();
    await ctx.media.settled();
    expect(ctx.status).toEqual(allPlaying);
  });

  it('keeps media paused across two dictations in a row and plays it once at the end', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.media.settled();
    const first = ctx.service.stopAndProcess();
    await ctx.service.cancel();
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.media.settled();
    expect(ctx.status.spotify).toBe('Paused');
    await ctx.service.cancel();
    await ctx.media.settled();
    expect(ctx.status).toEqual(allPlaying);
    // The second press landed inside the grace: still paused, never paused again.
    expect(ctx.calls.filter((call) => call === 'pause')).toHaveLength(1);
    ctx.release();
    await first;
  });

  it('never turns a media failure into a dictation error', async () => {
    const ctx = setup();
    const broken = new DictationService({
      recorder: ctx.recorder,
      transcriber: { transcribe: async () => ({ text: 'hi there friend', durationSeconds: 1, detectedLanguage: null }) },
      sink: { deliver: async () => ({ delivered: true, clipboardFallback: false }) },
      settings: () => DEFAULT_SETTINGS,
      memory: () => emptySnapshot(),
      apiKey: async () => 'key',
      onStatus: () => undefined,
      onRecording: () => {
        throw new Error('hook exploded');
      },
    });
    await broken.startRecording({ source: 'hotkey' });
    expect(broken.currentState).toBe('recording');
    await broken.cancel();
    expect(broken.currentState).toBe('idle');
  });
});
