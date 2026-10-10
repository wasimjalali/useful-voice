/**
 * Ways the dictation source, typed errors, outcomes, telemetry and the silence and
 * max-length guards can fail. Written before the code; each one has a test below
 * (or, where it cannot run on plain Node, a note on what covers it).
 *
 * Source (hotkey pastes, window copies)
 *   1. The source is read from the wrong moment: a stop pressed from the other
 *      surface changes how the text is delivered. It is fixed at recording start.
 *   2. The source of one dictation leaks into the next (window, then hotkey, and the
 *      reverse), or a failed start leaves its source behind.
 *   3. A window dictation still pastes, or still records a target app ("Unknown").
 *   4. Retry delivers by paste into whatever is frontmost instead of copying.
 *   5. An auto-stop or force-stop quietly swaps the source.
 *
 * Races between entry points
 *   6. A hotkey and a window press arrive while the recorder is still starting:
 *      two recorder starts, or a stop of a recording that has not begun.
 *   7. A second stop (hotkey, auto-stop on silence, max length) arrives while the
 *      first stop is still waiting for the recorder: two stops, two uploads.
 *   8. Auto-stop fires after the user already stopped manually.
 *   9. Max length is reached while transcribing: a second stop of a finished recording.
 *  10. Esc (cancel) during an in-flight stop: the captured audio still gets
 *      processed after the cancel.
 *  11. Esc during delivering: a late sink result still records history and fires
 *      an outcome after the cancel.
 *  12. A late result of a cancelled dictation lands on top of the next dictation.
 *  13. Retry while recording or transcribing starts a second pipeline.
 *
 * Outcomes
 *  14. Two outcomes for one dictation (clipboard fallback plus timeout, cancel after done).
 *  15. An outcome after a cancel, or a cancelled outcome when nothing was running.
 *  16. The outcome arrives after the idle status, so the window never sees its line.
 *  17. A word count that treats runs of spaces or newlines as words.
 *
 * Errors
 *  18. A kind missing or wrong for a failure, so the UI attaches the wrong fix.
 *  19. A stale `error` carried onto a later, healthy status.
 *
 * Silence watchdog and max length
 *  20. The watchdog or its ticker keeps running after cancel, error or stop.
 *  21. Input that stops delivering buffers never trips the silence limit.
 *  22. A silence limit of zero (off) still stops the recording.
 *  23. A short loud burst fails to reset the silence timer.
 *
 * Telemetry
 *  24. Level samples sent after the stop, or while idle.
 *  25. More than ~30 updates a second to the window.
 *  26. A countdown shown with more than 5 s left, or with fractional seconds.
 *  27. A non-finite or out-of-range level reaching the window.
 *
 * Clipboard
 *  28. A copy-mode delivery asks the sink to paste, or to restore the old clipboard.
 *      (The clipboard snapshot and restore themselves live in src/main/index.ts, which
 *      needs Electron; this file proves the service never asks for them in copy mode.)
 */
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  DictationService,
  classifyRecordingFailure,
  classifyTranscriptionFailure,
  countWords,
  describeRecordingFailure,
  describeTranscriptionFailure,
  type CapturedAudio,
  type DictationStatus,
  type FormatterPort,
  type RecorderPort,
  type TextSinkPort,
  type TranscriberPort,
} from '../src/main/dictationService.js';
import { ProviderError, type Transcript } from '../src/core/transcription/deepgramProvider.js';
import { DETECTION_CODES, resolveDetectedLanguage } from '../src/core/transcription/languages.js';
import {
  DEFAULT_SETTINGS,
  emptySnapshot,
  type AppSettings,
  type DictationOutcomeEvent,
  type DictationTelemetry,
  type LanguageMemorySnapshot,
  type MemoryTerm,
} from '../src/core/models.js';

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
  startCalls = 0;
  stopCalls = 0;
  cancelCalls = 0;
  startError: Error | null = null;
  audio: CapturedAudio = capturedAudio();
  /** When set, start()/stop() wait for it, to hold a call in flight. */
  startGate: Promise<void> | null = null;
  stopGate: Promise<void> | null = null;

  async start(): Promise<void> {
    this.startCalls += 1;
    if (this.startGate) await this.startGate;
    if (this.startError) throw this.startError;
    this.started = true;
  }

  async stop(): Promise<CapturedAudio> {
    this.stopCalls += 1;
    if (this.stopGate) await this.stopGate;
    this.stopped = true;
    return this.audio;
  }

  async cancel(): Promise<void> {
    this.cancelCalls += 1;
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
  requests: Array<{ text: string; targetApp?: string; mode: string }> = [];
  result: { delivered: boolean; clipboardFallback: boolean } = { delivered: true, clipboardFallback: false };
  /** Never resolves, to exercise the delivery timeout. */
  hang = false;
  error: Error | null = null;

  async deliver(request: { text: string; targetApp?: string; mode: string }): Promise<{ delivered: boolean; clipboardFallback: boolean }> {
    this.delivered.push(request.text);
    this.requests.push(request);
    if (this.error) throw this.error;
    if (this.hang) return new Promise(() => {});
    return this.result;
  }
}

/** A dictionary term with the fields every test has to fill in anyway. */
function memoryTerm(overrides: Partial<MemoryTerm> & Pick<MemoryTerm, 'id' | 'phrase'>): MemoryTerm {
  return {
    aliases: [],
    pronunciations: [],
    language: 'auto',
    priority: 'high',
    notes: '',
    usageCount: 0,
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    ...overrides,
  };
}

function setup(options: {
  settings?: Partial<AppSettings>;
  memory?: Partial<LanguageMemorySnapshot>;
  apiKey?: string | null;
  formatter?: FormatterPort;
  tickMs?: number;
} = {}) {
  const recorder = new FakeRecorder();
  const transcriber = new FakeTranscriber();
  const sink = new FakeSink();
  const statuses: DictationStatus[] = [];
  const outcomes: DictationOutcomeEvent[] = [];
  const telemetry: DictationTelemetry[] = [];
  /** Statuses and outcomes in the order they were emitted. */
  const events: string[] = [];
  const records: Array<{ text: string; appName: string }> = [];
  const completed: string[] = [];
  const diagnostics: Array<{ category: string; message: string }> = [];

  const settings: AppSettings = { ...DEFAULT_SETTINGS, ...options.settings };
  const memory = { ...emptySnapshot(), ...options.memory };

  const service = new DictationService({
    recorder,
    transcriber,
    sink,
    settings: () => settings,
    memory: () => memory,
    apiKey: async () => (options.apiKey === undefined ? 'test-key' : options.apiKey),
    onStatus: (status) => {
      statuses.push(status);
      events.push(`status:${status.state}`);
    },
    onOutcome: (outcome) => {
      outcomes.push(outcome);
      events.push(`outcome:${outcome.kind}`);
    },
    onTelemetry: (sample) => telemetry.push(sample),
    onCompleted: (outcome) => {
      completed.push(outcome.text);
      records.push({ text: outcome.text, appName: outcome.appName });
    },
    onDiagnostic: (category, message) => diagnostics.push({ category, message }),
    idFactory,
    formatter: options.formatter,
    deliveryTimeoutMs: 200,
    tickMs: options.tickMs,
  });

  return {
    service, recorder, transcriber, sink, statuses, outcomes, telemetry, events, records,
    completed, diagnostics, settings, memory,
  };
}

describe('happy path', () => {
  it('records, transcribes and delivers', async () => {
    const ctx = setup();
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.service.currentState).toBe('recording');
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.transcriber.requests[0]?.audio.byteLength).toBe(64_000);
    expect(ctx.sink.delivered).toEqual(['hello world']);
    expect(ctx.service.currentState).toBe('idle');
  });

  it('reports a completed outcome with the text and mode', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.completed).toEqual(['hello world']);
    expect(ctx.service.mostRecent?.text).toBe('hello world');
    expect(ctx.service.mostRecent?.mode).toBe('raw');
  });

  it('walks through the documented state sequence', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.transcriber.requests[0]?.keyterms).toContain('Kubernetes');
  });

  it('uses the detected language when the provider reports one', async () => {
    const ctx = setup();
    ctx.transcriber.transcript = { text: 'hallo', durationSeconds: 1, detectedLanguage: 'de-DE' };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    // The raw provider code round-trips into history, region subtag included.
    expect(ctx.service.mostRecent?.language).toBe('de-DE');
  });
});

describe('formatter integration', () => {
  it('runs the formatter and marks the mode', async () => {
    const ctx = setup({ formatter: async (text) => `${text}.` });
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['hello world']);
    expect(ctx.service.currentState).toBe('idle');
  });

  it('falls back to raw text when the formatter returns nothing usable', async () => {
    const ctx = setup({ formatter: async () => '   ' });
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey', rawMode: true });
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['deploy Kubernetes']);
  });
});

describe('rejections before upload', () => {
  it('refuses audio that is too short', async () => {
    const ctx = setup();
    ctx.recorder.audio = capturedAudio({ wav: new Uint8Array(100) });
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.transcriber.requests).toHaveLength(0);
    expect(ctx.statuses.at(-1)?.message).toContain('No speech detected');
  });

  it('explains how to fix a missing API key', async () => {
    const ctx = setup({ apiKey: null });
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.transcriber.requests).toHaveLength(0);
    expect(ctx.statuses.at(-1)?.message).toContain('Settings');
  });

  it('discards an empty transcript and says so', async () => {
    const ctx = setup();
    ctx.transcriber.transcript = { text: '   ', durationSeconds: 1, detectedLanguage: null };
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey' });
    expect(ctx.service.currentState).toBe('error');
    expect(ctx.statuses.at(-1)?.message).toContain('Microphone access is blocked');
  });

  it('reports a missing device distinctly from a permission problem', async () => {
    const ctx = setup();
    ctx.recorder.startError = new Error('NotFoundError: no device');
    await ctx.service.startRecording({ source: 'hotkey' });
    expect(ctx.statuses.at(-1)?.message).toContain('No microphone was found');
  });

  it('reports a busy device', async () => {
    const ctx = setup();
    ctx.recorder.startError = new Error('NotReadableError: track start failed');
    await ctx.service.startRecording({ source: 'hotkey' });
    expect(ctx.statuses.at(-1)?.message).toContain('in use by another app');
  });

  it('recovers from the error state on the next press', async () => {
    const ctx = setup();
    ctx.recorder.startError = new Error('boom');
    await ctx.service.startRecording({ source: 'hotkey' });
    expect(ctx.service.currentState).toBe('error');
    ctx.recorder.startError = null;
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.service.currentState).toBe('recording');
  });
});

describe('transcription failures and retry', () => {
  it('keeps the audio so Retry does not need a re-record', async () => {
    const ctx = setup();
    ctx.transcriber.error = new ProviderError('transport', 'network down');
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.service.canRetry).toBe(true);
    expect(ctx.statuses.at(-1)?.message).toContain('Could not reach Deepgram');
  });

  it('retries the retained audio successfully', async () => {
    const ctx = setup();
    ctx.transcriber.error = new ProviderError('transport', 'network down');
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    ctx.transcriber.error = null;
    await ctx.service.retryLast();
    expect(ctx.sink.delivered).toEqual(['hello world']);
    expect(ctx.service.canRetry).toBe(false);
  });

  it('clears the retry offer after a successful retry', async () => {
    const ctx = setup();
    ctx.transcriber.error = new ProviderError('serverError', 'down');
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey' });
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

    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.service.currentState).toBe('idle');
    expect(ctx.statuses.at(-1)?.message).toContain('clipboard');
  });

  it('stays usable for the next dictation after a timeout', async () => {
    const ctx = setup();
    ctx.sink.hang = true;
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    // The service must accept a new dictation.
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.service.currentState).toBe('recording');
  });

  it('treats a throwing sink as delivered-to-clipboard, not as a lost dictation', async () => {
    const ctx = setup();
    ctx.sink.error = new Error('sink failed');
    ctx.sink.hang = false;
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.service.currentState).toBe('idle');
  });

  it('reports the clipboard fallback when the sink says it did not land', async () => {
    const ctx = setup();
    ctx.sink.result = { delivered: false, clipboardFallback: true };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.statuses.at(-1)?.message).toContain('Ctrl+V');
  });
});

describe('re-entrancy', () => {
  it('ignores a hotkey press while transcribing', async () => {
    const ctx = setup();
    let release!: (value: Transcript) => void;
    ctx.transcriber.transcribe = () => new Promise<Transcript>((resolve) => { release = resolve; });
    await ctx.service.startRecording({ source: 'hotkey' });
    const processing = ctx.service.stopAndProcess();
    await new Promise((resolve) => setTimeout(resolve, 0));

    await ctx.service.toggle({ source: 'hotkey' });
    // Still transcribing, not recording: a second press must not start capture.
    expect(ctx.service.currentState).toBe('transcribing');
    release({ text: 'done', durationSeconds: 1, detectedLanguage: null });
    await processing;
  });

  it('ignores a hotkey press while delivering', async () => {
    const ctx = setup();
    ctx.sink.hang = true;
    await ctx.service.startRecording({ source: 'hotkey' });
    const processing = ctx.service.stopAndProcess();
    await new Promise((resolve) => setTimeout(resolve, 0));
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.service.currentState).toBe('delivering');
    await processing;
  });

  it('reports busy while working', async () => {
    const ctx = setup();
    ctx.sink.hang = true;
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey', rawMode: true });
    await ctx.service.stopAndProcess();
    expect(ctx.service.currentState).toBe('error');

    // Second dictation is normal and MUST be formatted.
    ctx.transcriber.error = null;
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['F:hello world']);
    expect(ctx.service.mostRecent?.mode).toBe('formatted');
  });

  it('does not leak raw mode past a too-short failure', async () => {
    const ctx = setup({ formatter: async (text) => `F:${text}` });
    ctx.recorder.audio = capturedAudio({ wav: new Uint8Array(10) });
    await ctx.service.startRecording({ source: 'hotkey', rawMode: true });
    await ctx.service.stopAndProcess();

    ctx.recorder.audio = capturedAudio();
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['F:hello world']);
  });

  it('does not leak raw mode past a silent-clip failure', async () => {
    const ctx = setup({ formatter: async (text) => `F:${text}` });
    ctx.recorder.audio = capturedAudio({ hadSpeech: false });
    await ctx.service.startRecording({ source: 'hotkey', rawMode: true });
    await ctx.service.stopAndProcess();

    ctx.recorder.audio = capturedAudio();
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.sink.delivered).toEqual(['F:hello world']);
  });
});

describe('max-duration guard', () => {
  it('force-stops a recording and still processes what was captured', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'hotkey' });
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
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.forceStop('The microphone was disconnected.');
    expect(ctx.service.currentState).toBe('error');
    expect(ctx.statuses.at(-1)?.message).toContain('microphone was disconnected');
  });
});

describe('resolveDetectedLanguage', () => {
  it('keeps a catalogue regional tag exact rather than collapsing it', () => {
    // de-CH is its own catalogue row (Swiss German), not German.
    expect(resolveDetectedLanguage('de-CH')).toBe('de-CH');
  });

  it('resolves a non-catalogue regional tag to its base language', () => {
    expect(resolveDetectedLanguage('de-DE')).toBe('de');
    expect(resolveDetectedLanguage('en-US')).toBe('en');
    expect(resolveDetectedLanguage('zh-CN')).toBe('zh');
  });

  it('resolves an unknown code to auto, never the requested pin', () => {
    // Intentional change from the old coerceLanguage('is', 'en') === 'en': the
    // pin would scope memory to a language the transcript is not in, while
    // 'auto' keeps matching permissive and is never sent to the provider.
    expect(resolveDetectedLanguage('is')).toBe('auto');
  });

  it('resolves empty input to auto', () => {
    expect(resolveDetectedLanguage('')).toBe('auto');
    expect(resolveDetectedLanguage('   ')).toBe('auto');
  });

  it('is case-insensitive but resolves to the catalogue casing', () => {
    expect(resolveDetectedLanguage('DE-CH')).toBe('de-CH');
    expect(resolveDetectedLanguage('DE')).toBe('de');
  });

  it('resolves every detectable code to itself — none collapses or remaps', () => {
    // F-2 regression guard: the old hardcoded mapping silently discarded 24 of
    // the 34 codes Deepgram can report (ru, sv, uk, bg, ...). Every detection
    // code is a verbatim catalogue member, so === code holds and would also
    // catch a swapped-mapping regression that "not auto" misses.
    expect(DETECTION_CODES).toHaveLength(34);
    for (const code of DETECTION_CODES) {
      expect(resolveDetectedLanguage(code), code).toBe(code);
    }
  });

  it('keeps nl-BE resolvable even though Deepgram cannot detect it', () => {
    // nl-BE is pinned-only (absent from DETECTION_CODES because
    // detect_language rejects it), but if a provider ever returned it, the
    // catalogue match keeps the region.
    expect(resolveDetectedLanguage('nl-BE')).toBe('nl-BE');
  });

  it("resolves 'multi' to auto — the code-switching mode is not a detected language", () => {
    expect(resolveDetectedLanguage('multi')).toBe('auto');
  });
});

describe('detected language handling', () => {
  it('scopes memory by the resolved base language while history stores the raw regional code', async () => {
    const ctx = setup({
      memory: {
        terms: [
          memoryTerm({ id: 't-de', phrase: 'Kubernetes', pronunciations: ['kubernets'], language: 'de' }),
          memoryTerm({ id: 't-en', phrase: 'TypeScript', pronunciations: ['type script'], language: 'en' }),
        ],
      },
    });
    ctx.transcriber.transcript = {
      text: 'deploy kubernets and type script',
      durationSeconds: 1,
      detectedLanguage: 'de-DE',
    };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    // de-DE resolves to de for processing: the German-scoped term fires, the
    // English-scoped one does not (an 'auto' scope would have fixed both).
    expect(ctx.sink.delivered).toEqual(['deploy Kubernetes and type script']);
    expect(ctx.service.mostRecent?.memoryHitIds).toEqual(['t-de']);
    expect(ctx.service.mostRecent?.language).toBe('de-DE');
  });

  it('applies a Russian-scoped term when detection reports ru, and not an English-scoped one', async () => {
    const ctx = setup({
      memory: {
        terms: [
          memoryTerm({ id: 't-ru', phrase: 'Kubernetes', pronunciations: ['kubernets'], language: 'ru' }),
          memoryTerm({ id: 't-en', phrase: 'TypeScript', pronunciations: ['type script'], language: 'en' }),
        ],
      },
    });
    ctx.transcriber.transcript = {
      text: 'deploy kubernets and type script',
      durationSeconds: 1,
      detectedLanguage: 'ru',
    };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    // Previously ru collapsed to the pin (auto), so every language's rules ran.
    expect(ctx.sink.delivered).toEqual(['deploy Kubernetes and type script']);
    expect(ctx.service.mostRecent?.memoryHitIds).toEqual(['t-ru']);
    expect(ctx.service.mostRecent?.language).toBe('ru');
  });

  it('processes an unknown detected code as auto, stores it raw, and warns without transcript text', async () => {
    const transcriptText = 'kubernets and type script';
    const ctx = setup({
      memory: {
        terms: [
          memoryTerm({ id: 't-en', phrase: 'Kubernetes', pronunciations: ['kubernets'], language: 'en' }),
          memoryTerm({ id: 't-ru', phrase: 'TypeScript', pronunciations: ['type script'], language: 'ru' }),
        ],
      },
    });
    ctx.transcriber.transcript = { text: transcriptText, durationSeconds: 1, detectedLanguage: 'is' };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    // Effective 'auto': terms from every language participate.
    expect(ctx.sink.delivered).toEqual(['Kubernetes and TypeScript']);
    // But history records what Deepgram actually said.
    expect(ctx.service.mostRecent?.language).toBe('is');
    expect(ctx.diagnostics).toHaveLength(1);
    expect(ctx.diagnostics[0]?.category).toBe('dictation');
    expect(ctx.diagnostics[0]?.message).toContain("'is'");
    // The warning names the code only — never the transcript or the key.
    expect(ctx.diagnostics[0]?.message).not.toContain(transcriptText);
    expect(ctx.diagnostics[0]?.message).not.toContain('test-key');
  });

  it('warns when detection left Nova-3, but not for a regional form Nova-3 handles', async () => {
    const ctx = setup();
    ctx.transcriber.transcript = { text: 'hello', durationSeconds: 1, detectedLanguage: 'en-US' };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.service.mostRecent?.language).toBe('en-US');
    expect(ctx.diagnostics).toEqual([]);
  });

  it('stores the requested pin when nothing is detected, with no diagnostic', async () => {
    const ctx = setup({ settings: { languagePin: 'de' } });
    ctx.transcriber.transcript = { text: 'hallo', durationSeconds: 1, detectedLanguage: null };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.service.mostRecent?.language).toBe('de');
    expect(ctx.diagnostics).toEqual([]);
  });

  it('round-trips a raw regional code into history', async () => {
    const ctx = setup();
    ctx.transcriber.transcript = { text: 'hallo', durationSeconds: 1, detectedLanguage: 'de-DE' };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.service.mostRecent?.language).toBe('de-DE');
  });

  it('treats a whitespace-only detection as absent and stores the pin', async () => {
    const ctx = setup({ settings: { languagePin: 'de' } });
    ctx.transcriber.transcript = { text: 'hallo', durationSeconds: 1, detectedLanguage: '   ' };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.service.mostRecent?.language).toBe('de');
    expect(ctx.diagnostics).toEqual([]);
  });

  it('hands the resolved language to the formatter, not the raw code', async () => {
    let seen: string | undefined;
    const ctx = setup({
      formatter: async (text, language) => {
        seen = language;
        return text;
      },
    });
    ctx.transcriber.transcript = { text: 'hallo', durationSeconds: 1, detectedLanguage: 'de-DE' };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(seen).toBe('de');
    // History still stores the raw regional code.
    expect(ctx.service.mostRecent?.language).toBe('de-DE');
  });

  it('strips control characters from a detected code before storing or logging it', async () => {
    const ctx = setup();
    ctx.transcriber.transcript = {
      text: 'hallo',
      durationSeconds: 1,
      detectedLanguage: 'de\n-DE injected',
    };
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.service.mostRecent?.language).toBe('de-DEinjected');
    for (const entry of ctx.diagnostics) {
      expect(entry.message).not.toContain('\n');
    }
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

// ---------------------------------------------------------------------------
// Source, typed errors, outcomes, races, silence and max length, telemetry
// ---------------------------------------------------------------------------

/** A promise that stays pending until `open()` is called, to hold a call in flight. */
function gate(): { promise: Promise<void>; open: () => void } {
  let open!: () => void;
  const promise = new Promise<void>((resolve) => {
    open = resolve;
  });
  return { promise, open };
}

/** Let queued microtasks and zero-delay timers run (real timers only). */
const settle = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));

/** Hold the transcriber on its first call; later calls answer normally. */
function holdFirstTranscription(ctx: ReturnType<typeof setup>): (value: Transcript) => void {
  let release!: (value: Transcript) => void;
  let first = true;
  ctx.transcriber.transcribe = (request) => {
    ctx.transcriber.requests.push(request);
    if (first) {
      first = false;
      return new Promise<Transcript>((resolve) => {
        release = resolve;
      });
    }
    return Promise.resolve(ctx.transcriber.transcript);
  };
  return (value) => release(value);
}

describe('dictation source', () => {
  it('pastes a hotkey dictation into the app that was frontmost at the start', async () => {
    const ctx = setup();
    await ctx.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.sink.requests).toEqual([{ text: 'hello world', targetApp: 'Slack', mode: 'paste' }]);
    expect(ctx.outcomes).toEqual([{ kind: 'delivered', words: 2, result: 'pasted', appName: 'Slack' }]);
    expect(ctx.records[0]?.appName).toBe('Slack');
  });

  it('never pastes a window dictation and records no target app', async () => {
    const ctx = setup();
    // Even a target handed in by mistake is dropped: a window start has none.
    await ctx.service.toggle({ source: 'window', targetApp: 'Slack' });
    await ctx.service.toggle({ source: 'window' });
    expect(ctx.sink.requests).toEqual([{ text: 'hello world', mode: 'copy' }]);
    expect(ctx.sink.requests[0]).not.toHaveProperty('targetApp', 'Slack');
    expect(ctx.outcomes).toEqual([{ kind: 'delivered', words: 2, result: 'copied' }]);
    expect(ctx.outcomes[0]).not.toHaveProperty('appName');
    // Not "Unknown": the history row simply has no target app.
    expect(ctx.records[0]?.appName).toBe('');
    const recording = ctx.statuses.find((status) => status.state === 'recording');
    expect(recording?.targetApp).toBeUndefined();
    expect(ctx.statuses.at(-1)).toEqual({ state: 'idle' });
  });

  it('keeps the source it had at the start when the other surface stops it', async () => {
    const windowStart = setup();
    await windowStart.service.toggle({ source: 'window' });
    await windowStart.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    expect(windowStart.sink.requests[0]?.mode).toBe('copy');
    expect(windowStart.outcomes[0]).toMatchObject({ result: 'copied' });

    const hotkeyStart = setup();
    await hotkeyStart.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    await hotkeyStart.service.toggle({ source: 'window' });
    expect(hotkeyStart.sink.requests[0]).toMatchObject({ mode: 'paste', targetApp: 'Slack' });
  });

  it('keeps the source through a force-stop and a direct stop', async () => {
    const forced = setup();
    await forced.service.startRecording({ source: 'window' });
    await forced.service.forceStop('limit');
    expect(forced.sink.requests[0]?.mode).toBe('copy');

    const direct = setup();
    await direct.service.startRecording({ source: 'hotkey', targetApp: 'Notepad' });
    await direct.service.stopAndProcess();
    expect(direct.sink.requests[0]).toMatchObject({ mode: 'paste', targetApp: 'Notepad' });
  });

  it('does not leak the source into the next dictation', async () => {
    const ctx = setup();
    await ctx.service.toggle({ source: 'window' });
    await ctx.service.toggle({ source: 'window' });
    await ctx.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    await ctx.service.toggle({ source: 'hotkey' });
    await ctx.service.toggle({ source: 'window' });
    await ctx.service.toggle({ source: 'window' });
    expect(ctx.sink.requests.map((request) => request.mode)).toEqual(['copy', 'paste', 'copy']);
    expect(ctx.sink.requests[2]?.targetApp).toBeUndefined();
  });

  it('does not let a failed start leave its source behind', async () => {
    const ctx = setup();
    ctx.recorder.startError = new Error('Permission denied');
    await ctx.service.toggle({ source: 'window' });
    expect(ctx.service.currentState).toBe('error');
    ctx.recorder.startError = null;
    await ctx.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.sink.requests[0]).toMatchObject({ mode: 'paste', targetApp: 'Slack' });
  });

  it('always delivers a retry as a copy, even for a hotkey dictation', async () => {
    const ctx = setup();
    ctx.transcriber.error = new ProviderError('transport', 'network down');
    await ctx.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.service.canRetry).toBe(true);

    ctx.transcriber.error = null;
    await ctx.service.retryLast();
    expect(ctx.sink.requests).toEqual([{ text: 'hello world', mode: 'copy' }]);
    expect(ctx.outcomes).toEqual([{ kind: 'delivered', words: 2, result: 'copied' }]);
    expect(ctx.records[0]?.appName).toBe('');

    // And the retry's source does not stick to the next hotkey dictation.
    await ctx.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.sink.requests[1]).toMatchObject({ mode: 'paste', targetApp: 'Slack' });
  });

  it('never asks the sink to paste or restore anything in copy mode', async () => {
    const ctx = setup();
    await ctx.service.toggle({ source: 'window' });
    await ctx.service.toggle({ source: 'window' });
    expect(ctx.sink.requests.every((request) => request.mode === 'copy')).toBe(true);
    // A copy never reports itself as pasted, whatever the sink flags say.
    ctx.sink.result = { delivered: true, clipboardFallback: true };
    await ctx.service.toggle({ source: 'window' });
    await ctx.service.toggle({ source: 'window' });
    expect(ctx.outcomes.map((outcome) => (outcome.kind === 'delivered' ? outcome.result : outcome.kind))).toEqual([
      'copied',
      'copied',
    ]);
  });

  it('reports a copy that could not reach the clipboard instead of claiming it', async () => {
    const ctx = setup();
    ctx.sink.error = new Error('clipboard busy');
    await ctx.service.toggle({ source: 'window' });
    await ctx.service.toggle({ source: 'window' });
    expect(ctx.service.currentState).toBe('error');
    expect(ctx.statuses.at(-1)?.message).toContain('saved');
    expect(ctx.outcomes).toEqual([]);
    // The dictation itself is safe in history.
    expect(ctx.completed).toEqual(['hello world']);
  });
});

describe('typed errors', () => {
  it('types each microphone failure and points at the microphone settings', async () => {
    for (const message of ['Permission denied', 'NotFoundError: no device', 'NotReadableError: busy', 'boom']) {
      const ctx = setup();
      ctx.recorder.startError = new Error(message);
      await ctx.service.toggle({ source: 'hotkey' });
      const status = ctx.statuses.at(-1);
      expect(status?.state).toBe('error');
      expect(status?.error).toEqual({
        kind: 'micUnavailable',
        message: describeRecordingFailure(new Error(message)),
        fix: 'openMicrophoneSettings',
      });
      // The legacy message stays in step with the typed one.
      expect(status?.message).toBe(status?.error?.message);
    }
  });

  it('types a recorder that will not stop', async () => {
    const ctx = setup();
    ctx.recorder.stop = vi.fn(async () => {
      throw new Error('device gone');
    });
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.statuses.at(-1)?.error).toEqual({
      kind: 'stopFailed',
      message: 'Recording could not be saved: device gone',
    });
  });

  it('types a clip that is too short and one with no speech, with no fix to offer', async () => {
    const short = setup();
    short.recorder.audio = capturedAudio({ wav: new Uint8Array(100) });
    await short.service.startRecording({ source: 'hotkey' });
    await short.service.stopAndProcess();
    expect(short.statuses.at(-1)?.error?.kind).toBe('tooShort');
    expect(short.statuses.at(-1)?.error?.fix).toBeUndefined();

    const silent = setup();
    silent.recorder.audio = capturedAudio({ hadSpeech: false });
    await silent.service.startRecording({ source: 'hotkey' });
    await silent.service.stopAndProcess();
    expect(silent.statuses.at(-1)?.error?.kind).toBe('noSpeech');

    const empty = setup();
    empty.transcriber.transcript = { text: ' ', durationSeconds: 1, detectedLanguage: null };
    await empty.service.startRecording({ source: 'hotkey' });
    await empty.service.stopAndProcess();
    expect(empty.statuses.at(-1)?.error?.kind).toBe('noSpeech');
  });

  it('types a missing key and keeps the audio for a retry', async () => {
    const ctx = setup({ apiKey: null });
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.statuses.at(-1)?.error).toMatchObject({ kind: 'noProvider', fix: 'openEngineSettings' });
    expect(ctx.service.canRetry).toBe(true);
  });

  it('types every provider failure with the right fix', async () => {
    const cases: Array<[ProviderError, string, string | undefined]> = [
      [new ProviderError('unauthorized', 'x'), 'keyRejected', 'openEngineSettings'],
      [new ProviderError('outOfCredits', 'x'), 'outOfCredits', 'openEngineSettings'],
      [new ProviderError('transport', 'x'), 'offline', 'retry'],
      [new ProviderError('timedOut', 'x'), 'timedOut', 'retry'],
      [new ProviderError('rateLimited', 'x'), 'providerFailed', 'retry'],
      [new ProviderError('serverError', 'x'), 'providerFailed', 'retry'],
      [new ProviderError('malformedResponse', 'x'), 'providerFailed', 'retry'],
      // A rejected request fails identically forever, so it is never offered a retry.
      [new ProviderError('badRequest', 'Keyterm limit exceeded.'), 'providerFailed', undefined],
    ];
    for (const [error, kind, fix] of cases) {
      const ctx = setup();
      ctx.transcriber.error = error;
      await ctx.service.startRecording({ source: 'hotkey' });
      await ctx.service.stopAndProcess();
      const typed = ctx.statuses.at(-1)?.error;
      expect(typed?.kind, error.kind).toBe(kind);
      expect(typed?.fix, error.kind).toBe(fix);
      expect(typed?.message).toBe(describeTranscriptionFailure(error));
      expect(classifyTranscriptionFailure(error)).toEqual(typed);
    }
  });

  it('keeps today\'s wording for the text-only failures', () => {
    expect(classifyTranscriptionFailure(new ProviderError('outOfCredits', 'out')).message).toContain('Transcription failed');
    expect(classifyTranscriptionFailure(new Error('weird')).kind).toBe('providerFailed');
    expect(classifyRecordingFailure(new Error('Permission denied')).message).toContain('Microphone access is blocked');
  });

  it('carries no error on a healthy status, and none after the next start', async () => {
    const ctx = setup();
    ctx.recorder.startError = new Error('Permission denied');
    await ctx.service.toggle({ source: 'hotkey' });
    ctx.recorder.startError = null;
    await ctx.service.toggle({ source: 'hotkey' });
    await ctx.service.toggle({ source: 'hotkey' });
    const afterError = ctx.statuses.slice(ctx.statuses.findIndex((status) => status.state === 'error') + 1);
    expect(afterError.length).toBeGreaterThan(0);
    for (const status of afterError) expect(status).not.toHaveProperty('error');
  });
});

describe('outcomes', () => {
  it('counts whitespace-separated tokens', () => {
    expect(countWords('hello')).toBe(1);
    expect(countWords('  one  two\n\nthree\tfour ')).toBe(4);
    expect(countWords('   ')).toBe(0);
    expect(countWords('')).toBe(0);
  });

  it('reports the word count of the delivered text', async () => {
    const ctx = setup();
    ctx.transcriber.transcript = { text: 'one  two\nthree', durationSeconds: 1, detectedLanguage: null };
    await ctx.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.outcomes).toEqual([{ kind: 'delivered', words: 3, result: 'pasted', appName: 'Slack' }]);
  });

  it('emits the outcome after history is written and before the idle status', async () => {
    const ctx = setup();
    await ctx.service.toggle({ source: 'hotkey' });
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.events).toEqual([
      'status:recording',
      'status:transcribing',
      'status:delivering',
      'outcome:delivered',
      'status:idle',
    ]);
  });

  it('reports a paste that could not be confirmed as copied-not-pasted, once', async () => {
    const ctx = setup();
    ctx.sink.hang = true;
    await ctx.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.outcomes).toEqual([{ kind: 'delivered', words: 2, result: 'copiedNotPasted', appName: 'Slack' }]);
    expect(ctx.statuses.at(-1)?.message).toContain('Ctrl+V');

    // A cancel after the dictation is done is not a second outcome.
    await ctx.service.cancel();
    expect(ctx.outcomes).toHaveLength(1);
  });

  it('reports a sink that says it did not land as copied-not-pasted', async () => {
    const ctx = setup();
    ctx.sink.result = { delivered: false, clipboardFallback: true };
    await ctx.service.toggle({ source: 'hotkey', targetApp: 'Notepad' });
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.outcomes).toEqual([{ kind: 'delivered', words: 2, result: 'copiedNotPasted', appName: 'Notepad' }]);
  });

  it('emits no outcome for a failure', async () => {
    const ctx = setup();
    ctx.recorder.audio = capturedAudio({ hadSpeech: false });
    await ctx.service.toggle({ source: 'hotkey' });
    await ctx.service.toggle({ source: 'hotkey' });
    expect(ctx.outcomes).toEqual([]);
  });

  it('emits a cancelled outcome before the idle status for every cancellable stage', async () => {
    // Recording.
    const recording = setup();
    await recording.service.toggle({ source: 'hotkey' });
    await recording.service.cancel();
    expect(recording.events.slice(-2)).toEqual(['outcome:cancelled', 'status:idle']);
    expect(recording.outcomes).toEqual([{ kind: 'cancelled' }]);

    // Transcribing.
    const transcribing = setup();
    const release = holdFirstTranscription(transcribing);
    await transcribing.service.startRecording({ source: 'hotkey' });
    const processing = transcribing.service.stopAndProcess();
    await settle();
    await transcribing.service.cancel();
    expect(transcribing.outcomes).toEqual([{ kind: 'cancelled' }]);
    release({ text: 'late', durationSeconds: 1, detectedLanguage: null });
    await processing;
    expect(transcribing.outcomes).toEqual([{ kind: 'cancelled' }]);

    // Delivering.
    const delivering = setup();
    delivering.sink.hang = true;
    await delivering.service.startRecording({ source: 'hotkey' });
    const delivery = delivering.service.stopAndProcess();
    await settle();
    expect(delivering.service.currentState).toBe('delivering');
    await delivering.service.cancel();
    expect(delivering.outcomes).toEqual([{ kind: 'cancelled' }]);
    await delivery;
    expect(delivering.outcomes).toEqual([{ kind: 'cancelled' }]);
  });

  it('emits no outcome when there was nothing to cancel', async () => {
    const idle = setup();
    await idle.service.cancel();
    expect(idle.outcomes).toEqual([]);

    // Dismissing an error is not cancelling a dictation.
    const failed = setup();
    failed.recorder.startError = new Error('Permission denied');
    await failed.service.toggle({ source: 'hotkey' });
    await failed.service.cancel();
    expect(failed.service.currentState).toBe('idle');
    expect(failed.outcomes).toEqual([]);
  });

  it('emits one cancelled outcome when cancel is pressed twice', async () => {
    const ctx = setup();
    await ctx.service.toggle({ source: 'hotkey' });
    await Promise.all([ctx.service.cancel(), ctx.service.cancel()]);
    expect(ctx.outcomes).toEqual([{ kind: 'cancelled' }]);
    expect(ctx.recorder.cancelCalls).toBe(1);
    expect(ctx.statuses.filter((status) => status.state === 'idle')).toHaveLength(1);
  });
});

describe('races between entry points', () => {
  it('starts the recorder once when a second press arrives while it is starting', async () => {
    const ctx = setup();
    const starting = gate();
    ctx.recorder.startGate = starting.promise;
    const first = ctx.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    // The window button pressed in the same instant.
    await ctx.service.toggle({ source: 'window' });
    starting.open();
    await first;
    expect(ctx.recorder.startCalls).toBe(1);
    expect(ctx.service.currentState).toBe('recording');
    // The first press owns the dictation, so it is the hotkey's.
    await ctx.service.toggle({ source: 'window' });
    expect(ctx.sink.requests[0]).toMatchObject({ mode: 'paste', targetApp: 'Slack' });
  });

  it('stops the recorder once however many stops arrive while it is stopping', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'hotkey' });
    const stopping = gate();
    ctx.recorder.stopGate = stopping.promise;
    const first = ctx.service.stopAndProcess();
    const second = ctx.service.toggle({ source: 'hotkey' });
    const third = ctx.service.forceStop('limit');
    stopping.open();
    await Promise.all([first, second, third]);
    expect(ctx.recorder.stopCalls).toBe(1);
    expect(ctx.transcriber.requests).toHaveLength(1);
    expect(ctx.outcomes).toHaveLength(1);
  });

  it('drops the captured audio when a cancel lands while the recorder is still stopping', async () => {
    const ctx = setup();
    await ctx.service.startRecording({ source: 'hotkey' });
    const stopping = gate();
    ctx.recorder.stopGate = stopping.promise;
    const processing = ctx.service.stopAndProcess();
    await ctx.service.cancel();
    stopping.open();
    await processing;
    expect(ctx.transcriber.requests).toHaveLength(0);
    expect(ctx.sink.delivered).toEqual([]);
    expect(ctx.service.currentState).toBe('idle');
    expect(ctx.outcomes).toEqual([{ kind: 'cancelled' }]);
  });

  it('records nothing and says nothing when a delivery returns after an Esc', async () => {
    const ctx = setup();
    ctx.sink.hang = true;
    await ctx.service.startRecording({ source: 'hotkey' });
    const processing = ctx.service.stopAndProcess();
    await settle();
    expect(ctx.service.currentState).toBe('delivering');
    await ctx.service.cancel();
    const statusesAfterCancel = ctx.statuses.length;
    await processing; // resolves when the delivery timeout fires
    expect(ctx.statuses).toHaveLength(statusesAfterCancel);
    expect(ctx.completed).toEqual([]);
    expect(ctx.outcomes).toEqual([{ kind: 'cancelled' }]);
  });

  it('does not let the late result of a cancelled dictation land on the next one', async () => {
    const ctx = setup();
    const release = holdFirstTranscription(ctx);
    await ctx.service.startRecording({ source: 'hotkey', targetApp: 'Slack' });
    const old = ctx.service.stopAndProcess();
    await settle();
    await ctx.service.cancel();

    // A new dictation starts while the old upload is still outstanding.
    await ctx.service.startRecording({ source: 'window' });
    release({ text: 'late', durationSeconds: 1, detectedLanguage: null });
    await old;
    expect(ctx.service.currentState).toBe('recording');
    expect(ctx.completed).toEqual([]);

    await ctx.service.stopAndProcess();
    expect(ctx.completed).toEqual(['hello world']);
    expect(ctx.sink.requests).toEqual([{ text: 'hello world', mode: 'copy' }]);
    expect(ctx.outcomes.map((outcome) => outcome.kind)).toEqual(['cancelled', 'delivered']);
  });

  it('ignores a retry while recording or transcribing', async () => {
    const ctx = setup();
    ctx.transcriber.error = new ProviderError('transport', 'down');
    await ctx.service.startRecording({ source: 'hotkey' });
    await ctx.service.stopAndProcess();
    expect(ctx.service.canRetry).toBe(true);
    ctx.transcriber.error = null;

    await ctx.service.startRecording({ source: 'window' });
    await ctx.service.retryLast();
    expect(ctx.transcriber.requests).toHaveLength(1);
    expect(ctx.service.currentState).toBe('recording');

    const release = holdFirstTranscription(ctx);
    const processing = ctx.service.stopAndProcess();
    await settle();
    expect(ctx.service.currentState).toBe('transcribing');
    await ctx.service.retryLast();
    expect(ctx.transcriber.requests).toHaveLength(2);
    release({ text: 'done', durationSeconds: 1, detectedLanguage: null });
    await processing;
  });
});

describe('silence watchdog and max length', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('stops and processes a recording after the silence limit', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 10 } });
    await ctx.service.toggle({ source: 'hotkey', targetApp: 'Slack' });
    ctx.service.reportLevel(0.8);
    await vi.advanceTimersByTimeAsync(9_000);
    expect(ctx.service.currentState).toBe('recording');
    await vi.advanceTimersByTimeAsync(2_000);
    expect(ctx.service.currentState).toBe('idle');
    expect(ctx.recorder.stopCalls).toBe(1);
    expect(ctx.sink.requests).toEqual([{ text: 'hello world', targetApp: 'Slack', mode: 'paste' }]);
    expect(ctx.outcomes).toHaveLength(1);
  });

  it('restarts the silence timer when the user speaks again', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 10 } });
    await ctx.service.toggle({ source: 'hotkey' });
    ctx.service.reportLevel(0.8);
    await vi.advanceTimersByTimeAsync(8_000);
    ctx.service.reportLevel(0.8);
    await vi.advanceTimersByTimeAsync(8_000);
    expect(ctx.service.currentState).toBe('recording');
    await vi.advanceTimersByTimeAsync(3_000);
    expect(ctx.service.currentState).toBe('idle');
  });

  it('judges a quiet frame by real RMS, not by the scaled meter level', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 10 } });
    await ctx.service.toggle({ source: 'hotkey' });
    // A meter level of 0.2 is an RMS of 0.05, which is speech; 0.02 is an RMS of 0.005.
    for (let second = 0; second < 15; second += 1) {
      ctx.service.reportLevel(0.2);
      await vi.advanceTimersByTimeAsync(1_000);
    }
    expect(ctx.service.currentState).toBe('recording');
    for (let second = 0; second < 12; second += 1) {
      ctx.service.reportLevel(0.02);
      await vi.advanceTimersByTimeAsync(1_000);
    }
    expect(ctx.service.currentState).toBe('idle');
  });

  it('still stops on silence when the input delivers no buffers at all', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 10 } });
    await ctx.service.toggle({ source: 'hotkey' });
    await vi.advanceTimersByTimeAsync(11_000);
    expect(ctx.service.currentState).toBe('idle');
    expect(ctx.recorder.stopCalls).toBe(1);
  });

  it('does not stop on silence when the setting is off', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 0, maxRecordingSeconds: 600 } });
    await ctx.service.toggle({ source: 'hotkey' });
    await vi.advanceTimersByTimeAsync(300_000);
    expect(ctx.service.currentState).toBe('recording');
    expect(ctx.recorder.stopCalls).toBe(0);
  });

  it('force-stops at the maximum length and keeps the source', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 0, maxRecordingSeconds: 30 } });
    await ctx.service.toggle({ source: 'window' });
    ctx.service.reportLevel(0.8);
    await vi.advanceTimersByTimeAsync(29_000);
    expect(ctx.service.currentState).toBe('recording');
    await vi.advanceTimersByTimeAsync(2_000);
    expect(ctx.service.currentState).toBe('idle');
    expect(ctx.sink.requests).toEqual([{ text: 'hello world', mode: 'copy' }]);
  });

  it('reports a max-length stop that the recorder cannot complete', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 0, maxRecordingSeconds: 5 } });
    ctx.recorder.stop = vi.fn(async () => {
      throw new Error('device gone');
    });
    await ctx.service.toggle({ source: 'hotkey' });
    await vi.advanceTimersByTimeAsync(6_000);
    expect(ctx.service.currentState).toBe('error');
    expect(ctx.statuses.at(-1)?.error?.kind).toBe('stopFailed');
    expect(ctx.recorder.cancelCalls).toBe(1);
  });

  it('does not stop a second time when the limit passes while transcribing', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 0, maxRecordingSeconds: 20 } });
    const release = holdFirstTranscription(ctx);
    await ctx.service.toggle({ source: 'hotkey' });
    await vi.advanceTimersByTimeAsync(5_000);
    const processing = ctx.service.stopAndProcess();
    await vi.advanceTimersByTimeAsync(0);
    expect(ctx.service.currentState).toBe('transcribing');
    await vi.advanceTimersByTimeAsync(60_000);
    expect(ctx.recorder.stopCalls).toBe(1);
    expect(ctx.service.currentState).toBe('transcribing');
    release({ text: 'done', durationSeconds: 1, detectedLanguage: null });
    await processing;
    expect(ctx.outcomes).toHaveLength(1);
  });

  it('does not auto-stop after a manual stop is already in flight', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 10 } });
    await ctx.service.toggle({ source: 'hotkey' });
    await vi.advanceTimersByTimeAsync(9_800);
    const stopping = gate();
    ctx.recorder.stopGate = stopping.promise;
    const manual = ctx.service.stopAndProcess();
    await vi.advanceTimersByTimeAsync(2_000); // the silence limit passes here
    stopping.open();
    await manual;
    expect(ctx.recorder.stopCalls).toBe(1);
    expect(ctx.transcriber.requests).toHaveLength(1);
  });

  it('leaves no timer and no late stop behind after cancel, error or a finished dictation', async () => {
    vi.useFakeTimers();

    const cancelled = setup({ settings: { silenceTimeoutSeconds: 10 } });
    await cancelled.service.toggle({ source: 'hotkey' });
    await cancelled.service.cancel();
    expect(vi.getTimerCount()).toBe(0);
    await vi.advanceTimersByTimeAsync(1_000_000);
    expect(cancelled.recorder.stopCalls).toBe(0);

    const failed = setup({ settings: { silenceTimeoutSeconds: 10 } });
    failed.recorder.audio = capturedAudio({ wav: new Uint8Array(100) });
    await failed.service.toggle({ source: 'hotkey' });
    await failed.service.toggle({ source: 'hotkey' });
    expect(failed.service.currentState).toBe('error');
    expect(vi.getTimerCount()).toBe(0);

    const startFailed = setup({ settings: { silenceTimeoutSeconds: 10 } });
    startFailed.recorder.startError = new Error('Permission denied');
    await startFailed.service.toggle({ source: 'hotkey' });
    expect(vi.getTimerCount()).toBe(0);

    const done = setup({ settings: { silenceTimeoutSeconds: 10 } });
    await done.service.toggle({ source: 'hotkey' });
    await done.service.toggle({ source: 'hotkey' });
    expect(done.service.currentState).toBe('idle');
    expect(vi.getTimerCount()).toBe(0);
  });

  it('starts every recording with a fresh watchdog and clock', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 10 } });
    await ctx.service.toggle({ source: 'hotkey' });
    await vi.advanceTimersByTimeAsync(11_000); // auto-stops
    expect(ctx.service.currentState).toBe('idle');
    await ctx.service.toggle({ source: 'hotkey' });
    await vi.advanceTimersByTimeAsync(5_000);
    expect(ctx.service.currentState).toBe('recording');
  });
});

describe('telemetry', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('sends nothing while idle or after the recording stopped', async () => {
    vi.useFakeTimers();
    const ctx = setup();
    ctx.service.reportLevel(0.5);
    expect(ctx.telemetry).toEqual([]);

    await ctx.service.toggle({ source: 'hotkey' });
    await vi.advanceTimersByTimeAsync(100);
    ctx.service.reportLevel(0.5);
    await ctx.service.toggle({ source: 'hotkey' });
    const count = ctx.telemetry.length;
    expect(count).toBeGreaterThan(0);
    await vi.advanceTimersByTimeAsync(100);
    ctx.service.reportLevel(0.5);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(ctx.telemetry).toHaveLength(count);
  });

  it('throttles to about 30 updates a second', async () => {
    vi.useFakeTimers();
    const ctx = setup();
    await ctx.service.toggle({ source: 'hotkey' });
    for (let i = 0; i < 200; i += 1) {
      ctx.service.reportLevel(0.5);
      await vi.advanceTimersByTimeAsync(5);
    }
    // 200 reports over one second of (fake) time.
    expect(ctx.telemetry.length).toBeLessThanOrEqual(31);
    expect(ctx.telemetry.length).toBeGreaterThanOrEqual(20);
  });

  it('carries the level and elapsed time, clamped, and ignores a non-finite level', async () => {
    vi.useFakeTimers();
    const ctx = setup();
    await ctx.service.toggle({ source: 'hotkey' });
    // Past the tick at 2 s, so the throttle has room for this sample.
    await vi.advanceTimersByTimeAsync(2_100);
    ctx.service.reportLevel(5);
    expect(ctx.telemetry.at(-1)?.level).toBe(1);
    expect(ctx.telemetry.at(-1)?.elapsedSeconds).toBeCloseTo(2.1, 1);
    await vi.advanceTimersByTimeAsync(50);
    ctx.service.reportLevel(-3);
    expect(ctx.telemetry.at(-1)?.level).toBe(0);
    const count = ctx.telemetry.length;
    await vi.advanceTimersByTimeAsync(50);
    ctx.service.reportLevel(Number.NaN);
    ctx.service.reportLevel(Number.POSITIVE_INFINITY);
    expect(ctx.telemetry).toHaveLength(count);
  });

  it('omits both countdowns until 5 s or fewer remain', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 60, maxRecordingSeconds: 600 } });
    await ctx.service.toggle({ source: 'hotkey' });
    await vi.advanceTimersByTimeAsync(10_000);
    const sample = ctx.telemetry.at(-1);
    expect(sample).toBeDefined();
    expect(sample).not.toHaveProperty('silenceRemaining');
    expect(sample).not.toHaveProperty('maxRemaining');
  });

  it('counts down the silence limit in whole seconds over the last 5 s only', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 20, maxRecordingSeconds: 600 } });
    await ctx.service.toggle({ source: 'hotkey' });
    ctx.service.reportLevel(0.8);
    await vi.advanceTimersByTimeAsync(14_000); // 6 s left: not shown
    expect(ctx.telemetry.at(-1)).not.toHaveProperty('silenceRemaining');
    await vi.advanceTimersByTimeAsync(2_500); // 3.5 s left: shown as 4
    expect(ctx.telemetry.at(-1)?.silenceRemaining).toBe(4);
    expect(Number.isInteger(ctx.telemetry.at(-1)?.silenceRemaining)).toBe(true);
    expect(ctx.telemetry.at(-1)).not.toHaveProperty('maxRemaining');

    // Speaking again takes the countdown away.
    ctx.service.reportLevel(0.8);
    await vi.advanceTimersByTimeAsync(300);
    expect(ctx.telemetry.at(-1)).not.toHaveProperty('silenceRemaining');
  });

  it('counts down the maximum length in whole seconds over the last 5 s only', async () => {
    vi.useFakeTimers();
    const ctx = setup({ settings: { silenceTimeoutSeconds: 0, maxRecordingSeconds: 30 } });
    await ctx.service.toggle({ source: 'hotkey' });
    await vi.advanceTimersByTimeAsync(24_000); // 6 s left
    expect(ctx.telemetry.at(-1)).not.toHaveProperty('maxRemaining');
    await vi.advanceTimersByTimeAsync(2_500); // 3.5 s left
    expect(ctx.telemetry.at(-1)?.maxRemaining).toBe(4);
    expect(ctx.telemetry.at(-1)).not.toHaveProperty('silenceRemaining');
  });
});
