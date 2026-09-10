/**
 * Silence detection for auto-stop, and the recording-length cap.
 *
 * Pure logic: the caller supplies elapsed time and the current level, so this is
 * testable without any audio hardware.
 */

export interface SilenceWatchdogOptions {
  /**
   * Seconds of continuous silence after which recording stops automatically.
   * Zero or negative disables auto-stop.
   */
  timeoutSeconds: number;
  /**
   * RMS below which a frame counts as silence. ~0.01 sits above typical room tone
   * from a laptop microphone and below quiet speech.
   */
  silenceThreshold?: number;
}

export const DEFAULT_SILENCE_THRESHOLD = 0.01;

export class SilenceWatchdog {
  private readonly timeoutSeconds: number;
  private readonly silenceThreshold: number;
  private lastLoudAt: number | null = null;

  constructor(options: SilenceWatchdogOptions) {
    this.timeoutSeconds = options.timeoutSeconds;
    this.silenceThreshold = options.silenceThreshold ?? DEFAULT_SILENCE_THRESHOLD;
  }

  /**
   * Feed one frame.
   *
   * @param level RMS level of the frame.
   * @param elapsedSeconds Seconds since recording started.
   * @returns true when the recording should stop now.
   */
  observe(level: number, elapsedSeconds: number): boolean {
    if (this.timeoutSeconds <= 0) return false;

    if (level >= this.silenceThreshold) {
      this.lastLoudAt = elapsedSeconds;
      return false;
    }

    // Before the first loud frame, measure silence from the start of the
    // recording: otherwise a user who never speaks leaves it recording forever,
    // because `lastLoudAt` is still null.
    const reference = this.lastLoudAt ?? 0;
    return elapsedSeconds - reference >= this.timeoutSeconds;
  }

  /** Seconds of silence observed so far, for a countdown in the UI. */
  silenceSeconds(elapsedSeconds: number): number {
    return Math.max(0, elapsedSeconds - (this.lastLoudAt ?? 0));
  }

  reset(): void {
    this.lastLoudAt = null;
  }
}

/**
 * Tracks elapsed recording time against the hard cap.
 *
 * The cap is enforced outside the audio callback as well as inside it. Both the
 * watchdog and the cap used to be evaluated only inside the buffer callback, so
 * losing buffers (an input device unplugged or switched mid-recording) meant
 * neither ever fired and the app stayed in the recording state forever.
 */
export class RecordingClock {
  constructor(
    private readonly maxSeconds: number,
    private readonly now: () => number = () => Date.now(),
  ) {}

  private startedAt: number | null = null;

  start(): void {
    this.startedAt = this.now();
  }

  stop(): void {
    this.startedAt = null;
  }

  get isRunning(): boolean {
    return this.startedAt !== null;
  }

  elapsedSeconds(): number {
    if (this.startedAt === null) return 0;
    return Math.max(0, (this.now() - this.startedAt) / 1000);
  }

  /** Whether the hard cap has been reached. */
  isOverLimit(): boolean {
    if (this.startedAt === null) return false;
    return this.elapsedSeconds() >= this.maxSeconds;
  }

  /** Seconds left before the cap, for the HUD. */
  remainingSeconds(): number {
    return Math.max(0, this.maxSeconds - this.elapsedSeconds());
  }
}

/**
 * Whether a recorded payload is worth uploading.
 *
 * Below this the request can only return an empty transcript, so it would cost
 * the user time and money for nothing.
 */
export function isTooShortToTranscribe(audioBytes: number, minimumBytes: number): boolean {
  return audioBytes < minimumBytes;
}
