import type { AppSettings, LanguageMemorySnapshot, MemoryLanguage } from '../core/models.js';
import { applyMemory } from '../core/memory/memoryPostProcessor.js';
import { selectKeyterms } from '../core/memory/biasBuilder.js';
import { RecordingClock } from '../core/audio/silenceWatchdog.js';
import { MINIMUM_AUDIO_BYTES } from '../core/audio/wav.js';
import { ProviderError, type Transcript } from '../core/transcription/deepgramProvider.js';

export type DictationState = 'idle' | 'recording' | 'transcribing' | 'delivering' | 'error';

export interface DictationStatus {
  state: DictationState;
  message?: string;
  targetApp?: string;
  elapsedSeconds?: number;
}

/** What the recorder must provide. Implemented by the renderer over IPC. */
export interface RecorderPort {
  start(): Promise<void>;
  /** Stop and return the captured audio plus what was observed while capturing. */
  stop(): Promise<CapturedAudio>;
  cancel(): Promise<void>;
}

export interface CapturedAudio {
  wav: Uint8Array;
  durationSeconds: number;
  /** Peak absolute sample, used to reject a silent clip. */
  peak: number;
  /** True when at least one frame crossed the speech threshold. */
  hadSpeech: boolean;
}

export interface TranscriptionRequest {
  audio: Uint8Array;
  language: MemoryLanguage;
  keyterms: string[];
  smartFormat: boolean;
}

export interface TranscriberPort {
  transcribe(request: TranscriptionRequest, signal?: AbortSignal): Promise<Transcript>;
}

export interface DeliveryRequest {
  text: string;
  /** Which app was focused when dictation started. */
  targetApp?: string;
}

export interface DeliveryResult {
  /** Whether the text provably reached the target. */
  delivered: boolean;
  /** Whether the dictation is still on the clipboard as a fallback. */
  clipboardFallback: boolean;
}

export interface TextSinkPort {
  deliver(request: DeliveryRequest): Promise<DeliveryResult>;
}

/** Optional post-processing (the formatter). Absent means raw text is used. */
export type FormatterPort = (text: string, language: MemoryLanguage) => Promise<string>;

export interface DictationServiceDeps {
  recorder: RecorderPort;
  transcriber: TranscriberPort;
  sink: TextSinkPort;
  settings: () => AppSettings;
  memory: () => LanguageMemorySnapshot;
  /**
   * Reads the stored Deepgram key. A function (not a value) so the key is fetched
   * only when a request is about to be made, and so it never has to be held in a
   * component that the renderer can reach.
   */
  apiKey: () => Promise<string | null>;
  onStatus: (status: DictationStatus) => void;
  onCompleted?: (result: DictationOutcome) => void;
  /** Optional post-transcription formatting (the formatter). */
  formatter?: FormatterPort;
  idFactory?: () => string;
  now?: () => number;
  /** Bounded wait for delivery, so a lost callback cannot wedge the app. */
  deliveryTimeoutMs?: number;
}

export interface DictationOutcome {
  id: string;
  text: string;
  rawText: string;
  intermediateText: string;
  language: MemoryLanguage;
  appName: string;
  durationSeconds: number;
  mode: 'raw' | 'formatted';
  createdAt: string;
  replacementRuleIds: string[];
  memoryHitIds: string[];
  snippetIds: string[];
}

/** How long delivery may take before the state is released anyway. */
export const DEFAULT_DELIVERY_TIMEOUT_MS = 5000;

/**
 * The dictation state machine.
 *
 * Written against injected ports rather than Electron APIs so the whole pipeline —
 * including the failure paths that actually break in production — is covered by
 * unit tests. The macOS build's equivalent had no tests at all, and every defect
 * the audit found in this area lived exactly in those untested branches: a
 * delivery that never called back and wedged the app in `delivering`, a retry that
 * targeted a pruned file, and a stale "raw mode" flag leaking into the next
 * dictation.
 */
export class DictationService {
  private state: DictationState = 'idle';
  private clock: RecordingClock;
  private abortController: AbortController | null = null;
  private deliveryTimer: NodeJS.Timeout | null = null;
  private lastFailed: { audio: CapturedAudio; language: MemoryLanguage; targetApp?: string } | null = null;
  private lastOutcome: DictationOutcome | null = null;
  /** Consumed exactly once per dictation, never left set for the next one. */
  private pendingRawMode = false;

  constructor(private readonly deps: DictationServiceDeps) {
    this.clock = new RecordingClock(deps.settings().maxRecordingSeconds, deps.now ?? (() => Date.now()));
  }

  get currentState(): DictationState {
    return this.state;
  }

  get isBusy(): boolean {
    return this.state === 'recording' || this.state === 'transcribing' || this.state === 'delivering';
  }

  get canRetry(): boolean {
    return this.lastFailed !== null;
  }

  get mostRecent(): DictationOutcome | null {
    return this.lastOutcome;
  }

  get elapsedSeconds(): number {
    return this.clock.elapsedSeconds();
  }

  /**
   * The main entry point: start recording, or stop and process.
   *
   * Only `idle` and `recording` are actionable. A press during transcription or
   * delivery is ignored rather than queued, so a hotkey cannot start a second
   * recording mid-paste.
   */
  async toggle(options: { rawMode?: boolean; targetApp?: string } = {}): Promise<void> {
    if (this.state === 'idle' || this.state === 'error') {
      await this.startRecording(options);
      return;
    }
    if (this.state === 'recording') {
      await this.stopAndProcess();
    }
  }

  async startRecording(options: { rawMode?: boolean; targetApp?: string } = {}): Promise<void> {
    if (this.state === 'recording' || this.state === 'transcribing' || this.state === 'delivering') {
      return;
    }
    this.deps.settings(); // ensure settings are current before sizing the cap
    this.clock = new RecordingClock(this.deps.settings().maxRecordingSeconds, this.deps.now ?? (() => Date.now()));
    this.pendingRawMode = options.rawMode === true;

    try {
      await this.deps.recorder.start();
    } catch (error) {
      // A missing/blocked microphone must produce an actionable message, not a
      // bare "error 4" the way the unlocalized Swift enum did.
      this.setState('error', describeRecordingFailure(error));
      return;
    }

    this.clock.start();
    this.setState('recording', undefined, options.targetApp);
  }

  async stopAndProcess(): Promise<void> {
    if (this.state !== 'recording') return;

    let captured: CapturedAudio;
    try {
      captured = await this.deps.recorder.stop();
    } catch (error) {
      this.clock.stop();
      this.setState('error', `Recording could not be saved: ${describe(error)}`);
      return;
    }
    this.clock.stop();

    await this.process(captured, {
      language: this.deps.settings().languagePin,
      targetApp: undefined,
    });
  }

  /** Force-stop even if the recorder is wedged. Used by the max-duration guard. */
  async forceStop(reason: string): Promise<void> {
    if (this.state !== 'recording') return;
    try {
      const captured = await this.deps.recorder.stop();
      this.clock.stop();
      await this.process(captured, { language: this.deps.settings().languagePin });
    } catch {
      this.clock.stop();
      await this.deps.recorder.cancel().catch(() => undefined);
      this.setState('error', reason);
    }
  }

  /**
   * Abort whatever is in flight.
   *
   * Works during transcription and delivery too, not only while recording. The
   * macOS build's cancel was gated on `.recording`, so once a recording stopped
   * the user had no way to abort a hung upload at all.
   */
  async cancel(): Promise<void> {
    if (this.state === 'idle') return;
    if (this.state === 'recording') {
      this.clock.stop();
      this.abortController?.abort();
      await this.deps.recorder.cancel().catch(() => undefined);
      this.setState('idle');
      return;
    }
    // Transcribing or delivering: cancel the request and release the state
    // immediately rather than waiting for a timeout.
    this.abortController?.abort();
    this.clearDeliveryTimer();
    this.setState('idle');
  }

  /** Retry the last failure, re-uploading the retained audio. */
  async retryLast(): Promise<void> {
    const failed = this.lastFailed;
    if (!failed) return;
    if (this.state === 'recording' || this.state === 'transcribing' || this.state === 'delivering') return;
    this.lastFailed = null;
    await this.process(failed.audio, {
      language: failed.language,
      targetApp: failed.targetApp,
    });
  }

  private async process(
    captured: CapturedAudio,
    context: { language: MemoryLanguage; targetApp?: string },
  ): Promise<void> {
    // Consume the raw-mode flag here, exactly once. The macOS version cleared it
    // only on the success path, so every early return (too short, no provider,
    // empty transcript) left it set and the NEXT dictation silently skipped
    // formatting with no explanation.
    const rawMode = this.pendingRawMode;
    this.pendingRawMode = false;

    const settings = this.deps.settings();

    if (captured.wav.byteLength < MINIMUM_AUDIO_BYTES) {
      this.setState('error', 'Recording was too short. Hold the hotkey a moment longer.');
      return;
    }
    // A silent clip can make a speech model echo its prompt bias back as a fake
    // transcript, so it is rejected before any upload.
    if (!captured.hadSpeech) {
      this.setState('error', 'No speech detected. Check your microphone level and try again.');
      return;
    }

    const apiKey = await this.deps.apiKey();
    if (!apiKey) {
      this.retain(captured, context);
      this.setState('error', 'No Deepgram API key is set. Add one in Settings to start dictating.');
      return;
    }

    const snapshot = this.deps.memory();
    const selection = selectKeyterms({
      terms: snapshot.terms,
      replacements: snapshot.replacements,
      snippets: snapshot.snippets,
      language: context.language,
      budget: settings.dictionaryBiasBudget,
    });

    this.abortController = new AbortController();
    this.setState('transcribing', undefined, context.targetApp);

    let transcript: Transcript;
    try {
      transcript = await this.deps.transcriber.transcribe(
        {
          audio: captured.wav,
          language: context.language,
          keyterms: selection.terms,
          smartFormat: settings.formattingEnabled,
        },
        this.abortController.signal,
      );
    } catch (error) {
      // Keep the audio so Retry does not make the user dictate again.
      this.retain(captured, context);
      this.setState('error', describeTranscriptionFailure(error));
      return;
    }

    const rawText = transcript.text.trim();
    if (rawText.length === 0) {
      this.setState('error', 'No speech was recognised in that recording.');
      return;
    }

    const language = transcript.detectedLanguage
      ? coerceLanguage(transcript.detectedLanguage, context.language)
      : context.language;

    // Deterministic memory pass: never skipped, even in raw mode. Raw mode means
    // "do not run the formatter", not "do not apply the user's dictionary".
    const memoryResult = applyMemory(rawText, snapshot, language);

    let finalText = memoryResult.text;
    let mode: 'raw' | 'formatted' = 'raw';
    if (!rawMode && settings.formattingEnabled && this.deps.formatter) {
      try {
        const formatted = await this.deps.formatter(memoryResult.text, language);
        if (formatted.trim().length > 0) {
          const reApplied = applyMemory(formatted, snapshot, language);
          finalText = reApplied.text;
          mode = 'formatted';
        }
      } catch {
        // A formatter failure must never lose the dictation: fall back to the
        // unformatted text, which is already correct.
        mode = 'raw';
      }
    }

    if (finalText.trim().length === 0) {
      this.setState('error', 'The transcript came back empty.');
      return;
    }

    this.setState('delivering', undefined, context.targetApp);
    const delivered = await this.deliver(finalText, context.targetApp);

    const outcome: DictationOutcome = {
      id: (this.deps.idFactory ?? defaultId)(),
      text: finalText,
      rawText,
      intermediateText: memoryResult.text,
      language,
      appName: context.targetApp ?? 'Unknown',
      durationSeconds: transcript.durationSeconds ?? captured.durationSeconds,
      mode,
      createdAt: new Date(this.deps.now ? this.deps.now() : Date.now()).toISOString(),
      replacementRuleIds: memoryResult.appliedRuleIds,
      memoryHitIds: memoryResult.memoryHitIds,
      snippetIds: memoryResult.appliedSnippetIds,
    };
    this.lastOutcome = outcome;
    this.lastFailed = null;
    this.abortController = null;
    this.deps.onCompleted?.(outcome);

    if (!delivered.delivered && delivered.clipboardFallback) {
      this.setState('idle', 'Copied to your clipboard — press Ctrl+V to paste it.');
      return;
    }
    this.setState('idle');
  }

  /**
   * Deliver with a bounded wait.
   *
   * The macOS build returned the state to idle ONLY when the sink called back. A
   * lost callback therefore left the app in `delivering` forever and the hotkey
   * stopped working until relaunch. The timeout makes the contract total: the
   * state is always released, and the dictation is left on the clipboard either
   * way.
   */
  private async deliver(text: string, targetApp?: string): Promise<DeliveryResult> {
    const timeoutMs = this.deps.deliveryTimeoutMs ?? DEFAULT_DELIVERY_TIMEOUT_MS;
    let timer: NodeJS.Timeout | null = null;
    try {
      const result = await Promise.race([
        this.deps.sink.deliver({ text, targetApp }),
        new Promise<DeliveryResult>((resolve) => {
          timer = setTimeout(
            () => resolve({ delivered: false, clipboardFallback: true }),
            timeoutMs,
          );
          timer.unref?.();
        }),
      ]);
      return result;
    } catch {
      // The sink itself failed. The text is on the clipboard, so nothing is lost.
      return { delivered: false, clipboardFallback: true };
    } finally {
      if (timer) clearTimeout(timer);
      this.clearDeliveryTimer();
    }
  }

  private retain(captured: CapturedAudio, context: { language: MemoryLanguage; targetApp?: string }): void {
    this.lastFailed = { audio: captured, ...context };
  }

  private setState(state: DictationState, message?: string, targetApp?: string): void {
    this.state = state;
    const status: DictationStatus = { state };
    if (message !== undefined) status.message = message;
    if (targetApp !== undefined) status.targetApp = targetApp;
    if (state === 'recording') status.elapsedSeconds = this.clock.elapsedSeconds();
    this.deps.onStatus(status);
  }

  private clearDeliveryTimer(): void {
    if (this.deliveryTimer) {
      clearTimeout(this.deliveryTimer);
      this.deliveryTimer = null;
    }
  }
}

function defaultId(): string {
  return globalThis.crypto.randomUUID();
}

/**
 * Turn a recording failure into something the user can act on.
 *
 * The macOS build surfaced the raw `localizedDescription` of an unlocalized enum,
 * so users saw "The operation couldn't be completed. (UsefulVoiceCore.
 * AudioRecorderError error 4.)" — a message that names neither the cause nor the
 * remedy.
 */
export function describeRecordingFailure(error: unknown): string {
  const raw = describe(error).toLowerCase();
  if (raw.includes('permission') || raw.includes('denied') || raw.includes('notallowed')) {
    return 'Microphone access is blocked. Turn it on in Windows Settings > Privacy & security > Microphone.';
  }
  if (raw.includes('notfound') || raw.includes('devicenotfound')) {
    return 'No microphone was found. Connect one and check Windows Settings > System > Sound > Input.';
  }
  if (raw.includes('notreadable') || raw.includes('trackstarterror')) {
    return 'The microphone is in use by another app. Close it, or pick a different input device.';
  }
  return `Recording could not start: ${describe(error)}`;
}

/** Turn a transcription failure into something the user can act on. */
export function describeTranscriptionFailure(error: unknown): string {
  if (error instanceof ProviderError) {
    switch (error.kind) {
      case 'unauthorized':
        return 'Deepgram rejected your API key. Check it in Settings.';
      case 'rateLimited':
        return 'Deepgram is rate limiting requests. Try again in a moment.';
      case 'timedOut':
        return 'Transcription timed out. Check your internet connection and try again.';
      case 'transport':
        return 'Could not reach Deepgram. Check your internet connection.';
      case 'badRequest':
        // The provider's message is already bounded and has the key redacted.
        return error.message;
      case 'serverError':
        return 'Deepgram is having trouble right now. Try again shortly.';
      case 'malformedResponse':
      case 'cancelled':
        return error.message;
    }
  }
  return `Transcription failed: ${describe(error)}`;
}

function describe(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

/** Map a provider-reported language onto one this app supports. */
export function coerceLanguage(detected: string, fallback: MemoryLanguage): MemoryLanguage {
  const normalised = detected.toLowerCase().split('-')[0] ?? '';
  const supported: MemoryLanguage[] = ['en', 'de', 'es', 'fr', 'it', 'pt', 'nl', 'ja', 'zh'];
  const match = supported.find((candidate) => candidate === normalised);
  return match ?? fallback;
}
