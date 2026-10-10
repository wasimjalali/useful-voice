import type {
  AppSettings,
  DictationDelivery,
  DictationError,
  DictationOutcomeEvent,
  DictationSource,
  DictationTelemetry,
  LanguageMemorySnapshot,
  MemoryLanguage,
} from '../core/models.js';
import { applyMemory } from '../core/memory/memoryPostProcessor.js';
import { selectKeyterms } from '../core/memory/biasBuilder.js';
import { RecordingClock, SilenceWatchdog } from '../core/audio/silenceWatchdog.js';
import { LEVEL_METER_GAIN, MINIMUM_AUDIO_BYTES } from '../core/audio/wav.js';
import { ProviderError, type Transcript } from '../core/transcription/deepgramProvider.js';
import { detectionStayedOnNova3, resolveDetectedLanguage } from '../core/transcription/languages.js';

export type DictationState = 'idle' | 'recording' | 'transcribing' | 'delivering' | 'error';

export interface DictationStatus {
  state: DictationState;
  message?: string;
  targetApp?: string;
  elapsedSeconds?: number;
  /** Set on an error status that has a kind, never otherwise. `message` repeats `error.message`. */
  error?: DictationError;
  /** How the text reaches the user, while a dictation is in flight: pasted, or only saved and copied. */
  delivery?: 'paste' | 'copy';
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
  /** Deepgram "Dictation": spoken punctuation commands become characters. */
  spokenPunctuation: boolean;
}

export interface TranscriberPort {
  transcribe(request: TranscriptionRequest, signal?: AbortSignal): Promise<Transcript>;
}

export interface DeliveryRequest {
  text: string;
  /**
   * `paste`: type it into `targetApp`, restoring the previous clipboard once the paste
   * is proven. `copy`: only put it on the clipboard. Nothing is pasted, nothing is
   * restored, so a later paste of the user's own cannot be disturbed.
   */
  mode: 'paste' | 'copy';
  /** Which app was focused when a hotkey dictation started. Absent in copy mode. */
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
  /**
   * Called once per dictation that was delivered or cancelled, BEFORE the idle
   * status that ends it, so a window can show its done line before it resets.
   */
  onOutcome?: (outcome: DictationOutcomeEvent) => void;
  /** Called at most ~30 times a second, and only while recording. */
  onTelemetry?: (telemetry: DictationTelemetry) => void;
  onCompleted?: (result: DictationOutcome) => void;
  /**
   * Records a diagnostic worth keeping. Never pass transcript text or the API
   * key here — the bounded log is something the user can share.
   */
  onDiagnostic?: (category: string, message: string) => void;
  /** Optional post-transcription formatting (the formatter). */
  formatter?: FormatterPort;
  idFactory?: () => string;
  now?: () => number;
  /** Bounded wait for delivery, so a lost callback cannot wedge the app. */
  deliveryTimeoutMs?: number;
  /** How often the silence and max-length limits are checked. */
  tickMs?: number;
}

export interface StartOptions {
  /** Where the dictation started. Fixed for the whole dictation. */
  source: DictationSource;
  rawMode?: boolean;
  /** The app that was frontmost. Only a hotkey dictation uses it. */
  targetApp?: string;
}

export interface DictationOutcome {
  id: string;
  text: string;
  rawText: string;
  intermediateText: string;
  /**
   * Raw detected code as reported by the provider, or the requested pin when
   * detection is absent — not validated, so never sendable as `language=`
   * without going through `resolveDetectedLanguage`/`normaliseLanguageCode`.
   */
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

/** How often the silence and max-length limits are checked, independent of audio frames. */
export const DEFAULT_TICK_MS = 250;

/** Input level updates to the window and HUD are spaced at least this far apart (~30 Hz). */
export const TELEMETRY_MIN_INTERVAL_MS = 33;

/** A countdown is shown only for this many seconds before an auto-stop. */
export const COUNTDOWN_SECONDS = 5;

/**
 * One dictation, from the moment recording starts until it is delivered, fails or is
 * cancelled. Everything that can arrive late (a stop, an upload, a delivery) checks it
 * is still the current session before it acts, which is what makes a cancel final.
 */
interface Session {
  /** Where it started. Never changes. */
  readonly source: DictationSource;
  readonly targetApp?: string;
  readonly rawMode: boolean;
  /** A stop is under way (or done), so no other stop may begin. */
  stopping: boolean;
  /** Its outcome has been sent, so none can be sent again. */
  settled: boolean;
}

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
  private lastFailed: { audio: CapturedAudio; language: MemoryLanguage } | null = null;
  private lastOutcome: DictationOutcome | null = null;
  /** The dictation in flight. Null between dictations and after a cancel. */
  private session: Session | null = null;
  /** True while `recorder.start()` is pending, so a second press cannot start another. */
  private starting = false;
  private watchdog: SilenceWatchdog | null = null;
  private ticker: NodeJS.Timeout | null = null;
  private lastLevel = 0;
  private lastTelemetryAt: number | null = null;

  constructor(private readonly deps: DictationServiceDeps) {
    this.clock = new RecordingClock(deps.settings().maxRecordingSeconds, this.nowFn());
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
   * recording mid-paste. When it stops a recording the `source` is ignored: the
   * dictation keeps the source it started with.
   */
  async toggle(options: StartOptions): Promise<void> {
    if (this.state === 'idle' || this.state === 'error') {
      await this.startRecording(options);
      return;
    }
    if (this.state === 'recording') {
      await this.stopAndProcess();
    }
  }

  async startRecording(options: StartOptions): Promise<void> {
    if (this.isBusy || this.session !== null || this.starting) {
      return;
    }
    const settings = this.deps.settings();
    this.clock = new RecordingClock(settings.maxRecordingSeconds, this.nowFn());
    const session: Session = {
      source: options.source,
      // A window dictation never pastes, so it has no target to record.
      targetApp: options.source === 'hotkey' ? options.targetApp : undefined,
      rawMode: options.rawMode === true,
      stopping: false,
      settled: false,
    };

    this.starting = true;
    try {
      await this.deps.recorder.start();
    } catch (error) {
      // A missing/blocked microphone must produce an actionable message, not a
      // bare "error 4" the way the unlocalized Swift enum did.
      this.setState('error', classifyRecordingFailure(error));
      return;
    } finally {
      this.starting = false;
    }

    this.session = session;
    this.clock.start();
    this.startMonitoring(settings.silenceTimeoutSeconds);
    this.setState('recording', undefined, session.targetApp);
  }

  async stopAndProcess(): Promise<void> {
    await this.stopRecording((error) => `Recording could not be saved: ${describe(error)}`, false);
  }

  /** Force-stop even if the recorder is wedged. Used by the max-duration guard. */
  async forceStop(reason: string): Promise<void> {
    await this.stopRecording(() => reason, true);
  }

  /**
   * Stop the recorder and process what it captured.
   *
   * Entered from a manual stop, the silence guard and the max-length guard, so it is
   * the one place that decides a stop is already under way: a second caller returns
   * at once instead of stopping the recorder again and uploading twice.
   */
  private async stopRecording(failureMessage: (error: unknown) => string, cancelRecorderOnFailure: boolean): Promise<void> {
    const session = this.session;
    if (this.state !== 'recording' || !session || session.stopping) return;
    session.stopping = true;
    this.stopMonitoring();

    let captured: CapturedAudio;
    try {
      captured = await this.deps.recorder.stop();
    } catch (error) {
      if (this.session !== session) return;
      this.clock.stop();
      if (cancelRecorderOnFailure) {
        await this.deps.recorder.cancel().catch(() => undefined);
        if (this.session !== session) return;
      }
      this.fail(session, { kind: 'stopFailed', message: failureMessage(error) });
      return;
    }
    // Cancelled while the recorder was still stopping: the audio is dropped.
    if (this.session !== session) return;
    this.clock.stop();

    await this.process(session, captured, this.deps.settings().languagePin);
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
    const session = this.session;
    // No session outside the error state means a cancel is already in flight.
    if (this.state !== 'error' && !session) return;

    const wasRecording = this.state === 'recording';
    this.session = null;
    this.stopMonitoring();
    this.abortController?.abort();
    this.abortController = null;
    this.clearDeliveryTimer();
    if (wasRecording) {
      this.clock.stop();
      await this.deps.recorder.cancel().catch(() => undefined);
    }
    if (session) this.emitOutcome(session, { kind: 'cancelled' });
    this.setState('idle');
  }

  /** Retry the last failure, re-uploading the retained audio. The result is copied, never pasted. */
  async retryLast(): Promise<void> {
    const failed = this.lastFailed;
    if (!failed) return;
    if (this.isBusy || this.session !== null || this.starting) return;
    this.lastFailed = null;
    // The window it came from may be long gone, so a retry always saves and copies.
    const session: Session = { source: 'window', rawMode: false, stopping: true, settled: false };
    this.session = session;
    await this.process(session, failed.audio, failed.language);
  }

  /**
   * Feed one input level sample (the 0 to 1 meter level) while recording.
   *
   * Updates what the silence watchdog has heard and forwards the level to the window
   * and HUD at no more than ~30 Hz. Ignored unless a recording is running.
   */
  reportLevel(level: number): void {
    if (!this.isRecordingLive() || !this.watchdog || !Number.isFinite(level)) return;
    this.lastLevel = Math.max(0, Math.min(1, level));
    this.watchdog.observe(this.lastLevel / LEVEL_METER_GAIN, this.clock.elapsedSeconds());
    this.emitTelemetry();
  }

  private isRecordingLive(): boolean {
    return this.state === 'recording' && this.session !== null && !this.session.stopping;
  }

  private startMonitoring(silenceTimeoutSeconds: number): void {
    this.stopMonitoring();
    this.watchdog = new SilenceWatchdog({ timeoutSeconds: silenceTimeoutSeconds });
    this.lastLevel = 0;
    this.lastTelemetryAt = null;
    this.ticker = setInterval(() => this.tick(), this.deps.tickMs ?? DEFAULT_TICK_MS);
    this.ticker.unref?.();
  }

  private stopMonitoring(): void {
    if (this.ticker) clearInterval(this.ticker);
    this.ticker = null;
    this.watchdog = null;
  }

  /**
   * Enforce the two limits from the clock, not from audio frames: a device that stops
   * delivering buffers must still hit the silence limit and the hard cap.
   */
  private tick(): void {
    if (!this.isRecordingLive() || !this.watchdog) return;
    if (this.clock.isOverLimit()) {
      void this.forceStop('The recording limit was reached and the recording could not be saved.').catch((error) =>
        this.deps.onDiagnostic?.('dictation', `max-length stop failed: ${describe(error)}`),
      );
      return;
    }
    if (this.watchdog.isExpired(this.clock.elapsedSeconds())) {
      void this.stopAndProcess().catch((error) =>
        this.deps.onDiagnostic?.('dictation', `silence stop failed: ${describe(error)}`),
      );
      return;
    }
    this.emitTelemetry();
  }

  private emitTelemetry(): void {
    if (!this.deps.onTelemetry || !this.watchdog) return;
    const now = this.nowFn()();
    if (this.lastTelemetryAt !== null && now - this.lastTelemetryAt < TELEMETRY_MIN_INTERVAL_MS) return;
    this.lastTelemetryAt = now;

    const elapsed = this.clock.elapsedSeconds();
    const telemetry: DictationTelemetry = { level: this.lastLevel, elapsedSeconds: elapsed };

    // Silence counts down only once it has actually started, so a short limit does
    // not show a countdown to someone who is speaking.
    const untilSilenceStop = this.watchdog.secondsUntilStop(elapsed);
    if (
      untilSilenceStop !== null &&
      untilSilenceStop <= COUNTDOWN_SECONDS &&
      this.watchdog.silenceSeconds(elapsed) >= 1
    ) {
      telemetry.silenceRemaining = untilSilenceStop;
    }
    const untilMaxStop = Math.ceil(this.clock.remainingSeconds());
    if (untilMaxStop <= COUNTDOWN_SECONDS) telemetry.maxRemaining = untilMaxStop;

    this.deps.onTelemetry(telemetry);
  }

  private async process(session: Session, captured: CapturedAudio, language: MemoryLanguage): Promise<void> {
    // The raw-mode flag belongs to the session, so it cannot outlive its dictation.
    // The macOS version cleared a shared flag only on the success path, so every
    // early return (too short, no provider, empty transcript) left it set and the
    // NEXT dictation silently skipped formatting with no explanation.
    const rawMode = session.rawMode;
    const current = (): boolean => this.session === session;

    const settings = this.deps.settings();

    if (captured.wav.byteLength < MINIMUM_AUDIO_BYTES) {
      this.fail(session, { kind: 'tooShort', message: 'Recording was too short. Hold the hotkey a moment longer.' });
      return;
    }
    // A silent clip can make a speech model echo its prompt bias back as a fake
    // transcript, so it is rejected before any upload.
    if (!captured.hadSpeech) {
      this.fail(session, { kind: 'noSpeech', message: 'No speech detected. Check your microphone level and try again.' });
      return;
    }

    const apiKey = await this.deps.apiKey();
    if (!current()) return;
    if (!apiKey) {
      this.retain(captured, language);
      this.fail(session, {
        kind: 'noProvider',
        message: 'No Deepgram API key is set. Add one in Settings to start dictating.',
        fix: 'openEngineSettings',
      });
      return;
    }

    const snapshot = this.deps.memory();
    const selection = selectKeyterms({
      terms: snapshot.terms,
      replacements: snapshot.replacements,
      snippets: snapshot.snippets,
      language,
      budget: settings.dictionaryBiasBudget,
    });

    this.abortController = new AbortController();
    this.setState('transcribing', undefined, session.targetApp);

    let transcript: Transcript;
    try {
      transcript = await this.deps.transcriber.transcribe(
        {
          audio: captured.wav,
          language,
          keyterms: selection.terms,
          smartFormat: settings.formattingEnabled,
          spokenPunctuation: settings.spokenPunctuationEnabled,
        },
        this.abortController.signal,
      );
    } catch (error) {
      // A cancelled upload ends here without a word: the cancel already reported it.
      if (!current()) return;
      // Keep the audio so Retry does not make the user dictate again.
      this.retain(captured, language);
      this.fail(session, classifyTranscriptionFailure(error));
      return;
    }
    if (!current()) return;

    const rawText = transcript.text.trim();
    if (rawText.length === 0) {
      this.fail(session, { kind: 'noSpeech', message: 'No speech was recognised in that recording.' });
      return;
    }

    // What Deepgram detected decides the processing language — validated through
    // the catalogue so a returned `de-CH` keeps its region while `de-DE` scopes
    // as `de`. History stores the raw code, trimmed and stripped to tag
    // characters so a hostile or malformed value cannot forge a shareable log
    // line or a strange history row: an unknown detection is processed as
    // `auto` (permissive rather than wrong-language) but recorded as reported,
    // and is never sent back to the provider.
    const rawDetected =
      transcript.detectedLanguage
        ?.trim()
        .replace(/[^A-Za-z-]/g, '')
        .slice(0, 35) || null;
    const effectiveLanguage = rawDetected ? resolveDetectedLanguage(rawDetected) : language;
    const storedLanguage = rawDetected ?? language;

    // A detected code Nova-3 does not speak natively means the provider fell
    // back down the model chain, which silently drops `keyterm` — and the
    // symptom (the user's own terminology misspelled) reads as a dictionary
    // fault, so it is worth a log line. Only the code is recorded, never
    // transcript text or the key.
    if (rawDetected && !detectionStayedOnNova3(rawDetected)) {
      this.deps.onDiagnostic?.(
        'dictation',
        `detected language '${rawDetected}' is outside Nova-3, so the provider may have fallen back to a lower model and keyterms may have been dropped`,
      );
    }

    // Deterministic memory pass: never skipped, even in raw mode. Raw mode means
    // "do not run the formatter", not "do not apply the user's dictionary".
    const memoryResult = applyMemory(rawText, snapshot, effectiveLanguage);

    let finalText = memoryResult.text;
    let mode: 'raw' | 'formatted' = 'raw';
    if (!rawMode && settings.formattingEnabled && this.deps.formatter) {
      try {
        const formatted = await this.deps.formatter(memoryResult.text, effectiveLanguage);
        if (formatted.trim().length > 0) {
          const reApplied = applyMemory(formatted, snapshot, effectiveLanguage);
          finalText = reApplied.text;
          mode = 'formatted';
        }
      } catch {
        // A formatter failure must never lose the dictation: fall back to the
        // unformatted text, which is already correct.
        mode = 'raw';
      }
      if (!current()) return;
    }

    if (finalText.trim().length === 0) {
      this.fail(session, { kind: 'noSpeech', message: 'The transcript came back empty.' });
      return;
    }

    // A hotkey dictation is pasted into the app it started in. Everything else (a
    // window dictation, any retry) is saved and copied only.
    const deliveryMode = session.source === 'hotkey' ? 'paste' : 'copy';
    this.setState('delivering', undefined, session.targetApp);
    const delivered = await this.deliver(finalText, deliveryMode, session.targetApp);
    // Cancelled while delivering: the dictation was abandoned, so it is not recorded.
    if (!current()) return;

    const outcome: DictationOutcome = {
      id: (this.deps.idFactory ?? defaultId)(),
      text: finalText,
      rawText,
      intermediateText: memoryResult.text,
      language: storedLanguage,
      appName: deliveryMode === 'paste' ? (session.targetApp ?? 'Unknown') : '',
      durationSeconds: transcript.durationSeconds ?? captured.durationSeconds,
      mode,
      createdAt: new Date(this.nowFn()()).toISOString(),
      replacementRuleIds: memoryResult.appliedRuleIds,
      memoryHitIds: memoryResult.memoryHitIds,
      snippetIds: memoryResult.appliedSnippetIds,
    };
    this.lastOutcome = outcome;
    this.lastFailed = null;
    this.abortController = null;
    this.deps.onCompleted?.(outcome);

    if (deliveryMode === 'copy') {
      if (!delivered.delivered) {
        // The text is safe in history, but it did not reach the clipboard, and saying
        // "Saved and copied" would be a lie.
        this.fail(session, 'Your dictation is saved in your history, but copying it to the clipboard failed.');
        return;
      }
      this.finish(session, finalText, 'copied');
      return;
    }
    if (delivered.delivered) {
      this.finish(session, finalText, 'pasted', session.targetApp);
      return;
    }
    if (delivered.clipboardFallback) {
      this.finish(session, finalText, 'copiedNotPasted', session.targetApp, 'Copied to your clipboard. Press Ctrl+V to paste it.');
      return;
    }
    // Neither pasted nor on the clipboard: only a broken sink reports this.
    this.fail(session, 'Your dictation is saved in your history, but it could not be delivered.');
  }

  /** End a dictation that was delivered: outcome first, then idle. */
  private finish(
    session: Session,
    text: string,
    result: DictationDelivery,
    appName?: string,
    idleMessage?: string,
  ): void {
    const event: DictationOutcomeEvent = { kind: 'delivered', words: countWords(text), result };
    if (appName !== undefined) event.appName = appName;
    this.emitOutcome(session, event);
    this.session = null;
    this.setState('idle', idleMessage);
  }

  /**
   * End a dictation with an error. A typed error also reaches the UI as `status.error`;
   * a bare message (a broken sink, which only a bug can cause) has no kind to offer.
   * Callers have already checked the session is still current.
   */
  private fail(session: Session, error: DictationError | string): void {
    if (this.session !== session) return;
    this.stopMonitoring();
    this.abortController = null;
    this.session = null;
    this.setState('error', error);
  }

  private emitOutcome(session: Session, event: DictationOutcomeEvent): void {
    if (session.settled) return;
    session.settled = true;
    this.deps.onOutcome?.(event);
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
  private async deliver(text: string, mode: 'paste' | 'copy', targetApp?: string): Promise<DeliveryResult> {
    const timeoutMs = this.deps.deliveryTimeoutMs ?? DEFAULT_DELIVERY_TIMEOUT_MS;
    let timer: NodeJS.Timeout | null = null;
    try {
      const request: DeliveryRequest = mode === 'paste' ? { text, mode, targetApp } : { text, mode };
      const result = await Promise.race([
        this.deps.sink.deliver(request),
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

  private retain(captured: CapturedAudio, language: MemoryLanguage): void {
    this.lastFailed = { audio: captured, language };
  }

  private setState(state: DictationState, error?: DictationError | string, targetApp?: string): void {
    this.state = state;
    const status: DictationStatus = { state };
    if (typeof error === 'string') {
      status.message = error;
    } else if (error !== undefined) {
      status.message = error.message;
      status.error = error;
    }
    if (targetApp !== undefined) status.targetApp = targetApp;
    if (this.session) status.delivery = this.session.source === 'hotkey' ? 'paste' : 'copy';
    if (state === 'recording') status.elapsedSeconds = this.clock.elapsedSeconds();
    this.deps.onStatus(status);
  }

  private clearDeliveryTimer(): void {
    if (this.deliveryTimer) {
      clearTimeout(this.deliveryTimer);
      this.deliveryTimer = null;
    }
  }

  private nowFn(): () => number {
    return this.deps.now ?? (() => Date.now());
  }
}

/** Whitespace-separated tokens, which is what "24 words" means in the done line. */
export function countWords(text: string): number {
  return text.split(/\s+/).filter((token) => token.length > 0).length;
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
export function classifyRecordingFailure(error: unknown): DictationError {
  // Every way the microphone can fail to start is fixed in the same place.
  return { kind: 'micUnavailable', message: describeRecordingFailure(error), fix: 'openMicrophoneSettings' };
}

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

/** Turn a transcription failure into a typed error with the fix the UI should offer. */
export function classifyTranscriptionFailure(error: unknown): DictationError {
  const message = transcriptionFailureMessage(error);
  if (error instanceof ProviderError) {
    switch (error.kind) {
      case 'unauthorized':
        return { kind: 'keyRejected', message, fix: 'openEngineSettings' };
      case 'outOfCredits':
        return { kind: 'outOfCredits', message, fix: 'openEngineSettings' };
      case 'transport':
        return { kind: 'offline', message, fix: 'retry' };
      case 'timedOut':
        return { kind: 'timedOut', message, fix: 'retry' };
      // A request the provider rejected fails identically forever, so it gets no retry.
      case 'badRequest':
        return { kind: 'providerFailed', message };
      case 'rateLimited':
      case 'serverError':
      case 'malformedResponse':
      case 'cancelled':
        return { kind: 'providerFailed', message, fix: 'retry' };
    }
  }
  return { kind: 'providerFailed', message, fix: 'retry' };
}

/** Turn a transcription failure into something the user can act on. */
export function describeTranscriptionFailure(error: unknown): string {
  return transcriptionFailureMessage(error);
}

function transcriptionFailureMessage(error: unknown): string {
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
