import { describe, expect, it, vi } from 'vitest';
import {
  DictationService,
  coerceLanguage,
  describeRecordingFailure,
  describeTranscriptionFailure,
  type CapturedAudio,
  type DictationStatus,
  type RecorderPort,
  type TextSinkPort,
  type TranscriberPort,
} from '../src/main/dictationService.js';
import { ProviderError, type Transcript } from '../src/core/transcription/deepgramProvider.js';
import { DEFAULT_SETTINGS, emptySnapshot, type AppSettings, type LanguageMemorySnapshot } from '../src/core/models.js';

/** Deterministic id factory so assertions do not depend on randomUUID. */
let idCounter = 0;
const idFactory = (): string => {
  idCounter += 1;
  return `id-${idCounter}`;
};

function capturedAudio(overrides: Partial<CapturedAudio> = {}): CapturedAudio {
  return {
    // Above the minimum payload size.
    wav: new Uint8Array(64_000),
    durationSeconds: 2,
    peak: 0.5,
    hadSpeech: true,
    ...overrides,
  };
}

class FakeRecorder implements RecorderPort {
  started = false;
  stopped = false;
  cancelled = false;
  startError: Error | null = null;
  audio: CapturedAudio = capturedAudio();

  async start(): Promise<void> {
    if (this.startError) throw this.startError;
    this.started = true;
  }

  async stop(): Promise<CapturedAudio> {
    this.stopped = true;
    return this.audio;
  }

  async cancel(): Promise<void> {
    this.cancelled = true;
  }
}

class FakeTranscriber implements TranscriberPort {
  requests: Array<{ audio: Uint8Array; keyterms: string[]; language: string }> = [];
  transcript: Transcript = { text: 'hello world', durationSeconds: 1.5, detectedLanguage: null };
  error: Error | null = null;

  async transcribe(request: { audio: Uint8Array; keyterms: string[]; language: string }): Promise<Transcript> {
    this.requests.push(request);
    if (this.error) throw this.error;
    return this.transcript;
  }
}

class FakeSink implements TextSinkPort {
  delivered: string[] = [];
  result: { delivered: boolean; clipboardFallback: boolean } = { delivered: true, clipboardFallback: false };
  /** Never resolves, to exercise the delivery timeout. */
  hang = false;
  error: Error | null = null;

  async deliver(request: { text: string }): Promise<{ delivered: boolean; clipboardFallback: boolean }> {
    this.delivered.push(request.text);
    if (this.error) throw this.error;
    if (this.hang) return new Promise(() => {});
    return this.result;
  }
}

function setup(options: {
  settings?: Partial<AppSettings>;
  memory?: Partial<LanguageMemorySnapshot>;
  apiKey?: string | null;
  formatter?: (text: string) => Promise<string>;
} = {}) {
  const recorder = new FakeRecorder();
  const transcriber = new FakeTranscriber();
  const sink = new FakeSink();
  const statuses: DictationStatus[] = [];
  const completed: string[] = [];

  const settings: AppSettings = { ...DEFAULT_SETTINGS, ...options.settings };
  const memory = { ...emptySnapshot(), ...options.memory };

  const service = new DictationService({
    recorder,
    transcriber,
    sink,
    settings: () => settings,
    memory: () => memory,
    apiKey: async () => (options.apiKey === undefined ? 'test-key' : options.apiKey),
    onStatus: (status) => statuses.push(status),
    onCompleted: (outcome) => completed.push(outcome.text),
    idFactory,
    formatter: options.formatter,
    deliveryTimeoutMs: 200,
  });

  return { service, recorder, transcriber, sink, statuses, completed, settings, memory };
}

describe('happy path', () => {
  it('records, transcribes and delivers', async () => {
    const ctx = setup();
    await ctx.service.toggle();
    expect(ctx.service.currentState).toBe('recording');
    await ctx.service.toggle();
    expect(ctx.transcriber.requests[0]?.audio.byteLength).toBe(64_000);
    expect(ctx.sink.delivered).toEqual(['hello world']);
    expect(ctx.service.currentState).toBe('idle');
  });

  it('reports a completed outcome with the text and mode', async () => {
    const ctx = setup();
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.completed).toEqual(['hello world']);
    expect(ctx.service.mostRecent?.text).toBe('hello world');
    expect(ctx.service.mostRecent?.mode).toBe('raw');
  });

  it('walks through the documented state sequence', async () => {
    const ctx = setup();
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    const states = ctx.statuses.map((status) => status.state);
    expect(states).toContain('recording');
    expect(states).toContain('transcribing');
    expect(states).toContain('delivering');
    expect(states[states.length - 1]).toBe('idle');
  });

  it('applies the dictionary before delivering', async () => {
    const ctx = setup({
      memory: {
        terms: [{
          id: 't1', phrase: 'Kubernetes', aliases: [], pronunciations: ['kubernets'],
          language: 'auto', priority: 'high', notes: '', usageCount: 0,
          createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z',
        }],
      },
    });
    ctx.transcriber.transcript = { text: 'deploy kubernets', durationSeconds: 1, detectedLanguage: null };
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['deploy Kubernetes']);
  });

  it('sends the keyterm list from the dictionary', async () => {
    const ctx = setup({
      memory: {
        terms: [{
          id: 't1', phrase: 'Kubernetes', aliases: [], pronunciations: [],
          language: 'auto', priority: 'always', notes: '', usageCount: 0,
          createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z',
        }],
      },
    });
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.transcriber.requests[0]?.keyterms).toContain('Kubernetes');
  });

  it('uses the detected language when the provider reports one', async () => {
    const ctx = setup();
    ctx.transcriber.transcript = { text: 'hallo', durationSeconds: 1, detectedLanguage: 'de-DE' };
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.service.mostRecent?.language).toBe('de');
  });
});

describe('formatter integration', () => {
  it('runs the formatter and marks the mode', async () => {
    const ctx = setup({ formatter: async (text) => `${text}.` });
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['hello world.']);
    expect(ctx.service.mostRecent?.mode).toBe('formatted');
  });

  it('falls back to raw text when the formatter throws, without losing the dictation', async () => {
    const ctx = setup({
      formatter: async () => {
        throw new Error('formatter exploded');
      },
    });
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['hello world']);
    expect(ctx.service.currentState).toBe('idle');
  });

  it('falls back to raw text when the formatter returns nothing usable', async () => {
    const ctx = setup({ formatter: async () => '   ' });
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['hello world']);
  });

  it('still applies the dictionary in raw mode, only skipping formatting', async () => {
    const ctx = setup({
      formatter: async (text) => `FORMATTED ${text}`,
      memory: {
        terms: [{
          id: 't1', phrase: 'Kubernetes', aliases: [], pronunciations: ['kubernets'],
          language: 'auto', priority: 'high', notes: '', usageCount: 0,
          createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z',
        }],
      },
    });
    ctx.transcriber.transcript = { text: 'deploy kubernets', durationSeconds: 1, detectedLanguage: null };
    await ctx.service.startRecording({ rawMode: true });
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['deploy Kubernetes']);
  });
});

describe('rejections before upload', () => {
  it('refuses audio that is too short', async () => {
    const ctx = setup();
    ctx.recorder.audio = capturedAudio({ wav: new Uint8Array(100) });
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.transcriber.requests).toHaveLength(0);
    expect(ctx.statuses.at(-1)?.message).toContain('too short');
  });

  /**
   * A silent clip can make a speech model echo its own prompt bias (the
   * dictionary) back as a fake transcript.
   */
  it('refuses a silent recording', async () => {
    const ctx = setup();
    ctx.recorder.audio = capturedAudio({ hadSpeech: false, peak: 0.001 });
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.transcriber.requests).toHaveLength(0);
    expect(ctx.statuses.at(-1)?.message).toContain('No speech detected');
  });

  it('explains how to fix a missing API key', async () => {
    const ctx = setup({ apiKey: null });
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.transcriber.requests).toHaveLength(0);
    expect(ctx.statuses.at(-1)?.message).toContain('Settings');
  });

  it('discards an empty transcript and says so', async () => {
    const ctx = setup();
    ctx.transcriber.transcript = { text: '   ', durationSeconds: 1, detectedLanguage: null };
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual([]);
    // `error`, not `idle`: the user pressed the hotkey and got nothing, which is
    // exactly the case where silence would leave them wondering whether the app
    // is broken.
    expect(ctx.service.currentState).toBe('error');
    expect(ctx.statuses.at(-1)?.message).toContain('No speech was recognised');
  });
});

describe('recording failures', () => {
  it('reports an actionable message when the microphone is blocked', async () => {
    const ctx = setup();
    ctx.recorder.startError = new Error('Permission denied');
    await ctx.service.startRecording();
    expect(ctx.service.currentState).toBe('error');
    expect(ctx.statuses.at(-1)?.message).toContain('Microphone access is blocked');
  });

  it('reports a missing device distinctly from a permission problem', async () => {
    const ctx = setup();
    ctx.recorder.startError = new Error('NotFoundError: no device');
    await ctx.service.startRecording();
    expect(ctx.statuses.at(-1)?.message).toContain('No microphone was found');
  });

  it('reports a busy device', async () => {
    const ctx = setup();
    ctx.recorder.startError = new Error('NotReadableError: track start failed');
    await ctx.service.startRecording();
    expect(ctx.statuses.at(-1)?.message).toContain('in use by another app');
  });

  it('recovers from the error state on the next press', async () => {
    const ctx = setup();
    ctx.recorder.startError = new Error('boom');
    await ctx.service.startRecording();
    expect(ctx.service.currentState).toBe('error');
    ctx.recorder.startError = null;
    await ctx.service.toggle();
    expect(ctx.service.currentState).toBe('recording');
  });
});

describe('transcription failures and retry', () => {
  it('keeps the audio so Retry does not need a re-record', async () => {
    const ctx = setup();
    ctx.transcriber.error = new ProviderError('transport', 'network down');
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.service.canRetry).toBe(true);
    expect(ctx.statuses.at(-1)?.message).toContain('Could not reach Deepgram');
  });

  it('retries the retained audio successfully', async () => {
    const ctx = setup();
    ctx.transcriber.error = new ProviderError('transport', 'network down');
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    ctx.transcriber.error = null;
    await ctx.service.retryLast();
    expect(ctx.sink.delivered).toEqual(['hello world']);
    expect(ctx.service.canRetry).toBe(false);
  });

  it('clears the retry offer after a successful retry', async () => {
    const ctx = setup();
    ctx.transcriber.error = new ProviderError('serverError', 'down');
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.service.canRetry).toBe(true);
    ctx.transcriber.error = null;
    await ctx.service.retryLast();
    expect(ctx.service.canRetry).toBe(false);
  });

  /**
   * A retry that fails again must NOT discard the audio: the user would then have
   * to dictate the whole thing a third time.
   */
  it('keeps the audio available when the retry also fails', async () => {
    const ctx = setup();
    ctx.transcriber.error = new ProviderError('transport', 'down');
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    await ctx.service.retryLast();
    expect(ctx.service.canRetry).toBe(true);
  });

  it('does not offer a retry before any failure', () => {
    const ctx = setup();
    expect(ctx.service.canRetry).toBe(false);
  });

  /**
   * A rejected key is permanent, so the message must say what to fix rather than
   * inviting the user to retry forever.
   */
  it('maps each provider failure to an actionable message', () => {
    expect(describeTranscriptionFailure(new ProviderError('unauthorized', 'x'))).toContain('API key');
    expect(describeTranscriptionFailure(new ProviderError('rateLimited', 'x'))).toContain('rate limiting');
    expect(describeTranscriptionFailure(new ProviderError('timedOut', 'x'))).toContain('timed out');
    expect(describeTranscriptionFailure(new ProviderError('serverError', 'x'))).toContain('trouble');
  });

  it('surfaces the provider message for a bad request verbatim', () => {
    const error = new ProviderError('badRequest', 'Keyterm limit exceeded.');
    expect(describeTranscriptionFailure(error)).toBe('Keyterm limit exceeded.');
  });
});

describe('cancellation', () => {
  it('cancels an in-progress recording and discards it', async () => {
    const ctx = setup();
    await ctx.service.startRecording();
    await ctx.service.cancel();
    expect(ctx.recorder.cancelled).toBe(true);
    expect(ctx.service.currentState).toBe('idle');
    expect(ctx.sink.delivered).toEqual([]);
  });

  /**
   * The macOS cancel was gated on `.recording`, so once recording stopped the user
   * had no way to abort a hung upload at all.
   */
  it('cancels during transcription', async () => {
    const ctx = setup();
    let release!: (value: Transcript) => void;
    ctx.transcriber.transcribe = () => new Promise<Transcript>((resolve) => { release = resolve; });

    await ctx.service.startRecording();
    const processing = ctx.service.stopAndProcess();
    // Let the state machine reach `transcribing`.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(ctx.service.currentState).toBe('transcribing');

    await ctx.service.cancel();
    expect(ctx.service.currentState).toBe('idle');

    release({ text: 'late', durationSeconds: 1, detectedLanguage: null });
    await processing;
  });

  it('cancels during delivery', async () => {
    const ctx = setup();
    ctx.sink.hang = true;
    await ctx.service.startRecording();
    const processing = ctx.service.stopAndProcess();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(ctx.service.currentState).toBe('delivering');
    await ctx.service.cancel();
    expect(ctx.service.currentState).toBe('idle');
    await processing;
  });

  it('does nothing when already idle', async () => {
    const ctx = setup();
    await expect(ctx.service.cancel()).resolves.toBeUndefined();
  });
});

describe('delivery that never calls back', () => {
  /**
   * The macOS build returned to idle ONLY when the sink called back, so a lost
   * callback left the app wedged in `delivering` and the hotkey dead until
   * relaunch.
   */
  it('releases the state after the timeout and reports the clipboard fallback', async () => {
    const ctx = setup();
    ctx.sink.hang = true;
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.service.currentState).toBe('idle');
    expect(ctx.statuses.at(-1)?.message).toContain('clipboard');
  });

  it('stays usable for the next dictation after a timeout', async () => {
    const ctx = setup();
    ctx.sink.hang = true;
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    // The service must accept a new dictation.
    await ctx.service.toggle();
    expect(ctx.service.currentState).toBe('recording');
  });

  it('treats a throwing sink as delivered-to-clipboard, not as a lost dictation', async () => {
    const ctx = setup();
    ctx.sink.error = new Error('sink failed');
    ctx.sink.hang = false;
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.service.currentState).toBe('idle');
  });

  it('reports the clipboard fallback when the sink says it did not land', async () => {
    const ctx = setup();
    ctx.sink.result = { delivered: false, clipboardFallback: true };
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.statuses.at(-1)?.message).toContain('Ctrl+V');
  });
});

describe('re-entrancy', () => {
  it('ignores a hotkey press while transcribing', async () => {
    const ctx = setup();
    let release!: (value: Transcript) => void;
    ctx.transcriber.transcribe = () => new Promise<Transcript>((resolve) => { release = resolve; });
    await ctx.service.startRecording();
    const processing = ctx.service.stopAndProcess();
    await new Promise((resolve) => setTimeout(resolve, 0));

    await ctx.service.toggle();
    // Still transcribing, not recording: a second press must not start capture.
    expect(ctx.service.currentState).toBe('transcribing');
    release({ text: 'done', durationSeconds: 1, detectedLanguage: null });
    await processing;
  });

  it('ignores a hotkey press while delivering', async () => {
    const ctx = setup();
    ctx.sink.hang = true;
    await ctx.service.startRecording();
    const processing = ctx.service.stopAndProcess();
    await new Promise((resolve) => setTimeout(resolve, 0));
    await ctx.service.toggle();
    expect(ctx.service.currentState).toBe('delivering');
    await processing;
  });

  it('reports busy while working', async () => {
    const ctx = setup();
    ctx.sink.hang = true;
    await ctx.service.startRecording();
    const processing = ctx.service.stopAndProcess();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(ctx.service.isBusy).toBe(true);
    await processing;
  });
});

describe('raw-mode flag lifetime', () => {
  /**
   * The macOS version cleared the flag only on the success path, so every early
   * return left it set and the NEXT dictation silently skipped formatting.
   */
  it('does not leak raw mode past a failed dictation', async () => {
    const ctx = setup({ formatter: async (text) => `F:${text}` });

    // First dictation in raw mode, which fails before formatting.
    ctx.transcriber.error = new ProviderError('transport', 'down');
    await ctx.service.startRecording({ rawMode: true });
    await ctx.service.stopAndProcess();
    expect(ctx.service.currentState).toBe('error');

    // Second dictation is normal and MUST be formatted.
    ctx.transcriber.error = null;
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['F:hello world']);
    expect(ctx.service.mostRecent?.mode).toBe('formatted');
  });

  it('does not leak raw mode past a too-short failure', async () => {
    const ctx = setup({ formatter: async (text) => `F:${text}` });
    ctx.recorder.audio = capturedAudio({ wav: new Uint8Array(10) });
    await ctx.service.startRecording({ rawMode: true });
    await ctx.service.stopAndProcess();

    ctx.recorder.audio = capturedAudio();
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['F:hello world']);
  });

  it('does not leak raw mode past a silent-clip failure', async () => {
    const ctx = setup({ formatter: async (text) => `F:${text}` });
    ctx.recorder.audio = capturedAudio({ hadSpeech: false });
    await ctx.service.startRecording({ rawMode: true });
    await ctx.service.stopAndProcess();

    ctx.recorder.audio = capturedAudio();
    await ctx.service.startRecording();
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['F:hello world']);
  });
});

describe('max-duration guard', () => {
  it('force-stops a recording and still processes what was captured', async () => {
    const ctx = setup();
    await ctx.service.startRecording();
    await ctx.service.forceStop('Recording limit reached.');
    expect(ctx.sink.delivered).toEqual(['hello world']);
    expect(ctx.service.currentState).toBe('idle');
  });

  it('is a no-op when not recording', async () => {
    const ctx = setup();
    await ctx.service.forceStop('limit');
    expect(ctx.service.currentState).toBe('idle');
  });

  it('reports the reason when the recorder will not stop', async () => {
    const ctx = setup();
    ctx.recorder.stop = vi.fn(async () => {
      throw new Error('device gone');
    });
    await ctx.service.startRecording();
    await ctx.service.forceStop('The microphone was disconnected.');
    expect(ctx.service.currentState).toBe('error');
    expect(ctx.statuses.at(-1)?.message).toContain('microphone was disconnected');
  });
});

describe('coerceLanguage', () => {
  it('maps a regional tag to its base language', () => {
    expect(coerceLanguage('de-DE', 'en')).toBe('de');
    expect(coerceLanguage('en-US', 'de')).toBe('en');
  });

  it('keeps the fallback for an unsupported language', () => {
    expect(coerceLanguage('is', 'en')).toBe('en');
  });

  it('handles malformed input', () => {
    expect(coerceLanguage('', 'de')).toBe('de');
  });
});

describe('describeRecordingFailure', () => {
  it('always produces a non-empty, actionable sentence', () => {
    for (const raw of [
      new Error('Permission denied'),
      new Error('NotFoundError'),
      new Error('NotReadableError'),
      new Error('something entirely unexpected'),
    ]) {
      const message = describeRecordingFailure(raw);
      expect(message.length).toBeGreaterThan(10);
      expect(message).not.toMatch(/error \d+\)/);
    }
  });
});
