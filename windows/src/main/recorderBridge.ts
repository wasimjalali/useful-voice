import { randomUUID } from 'node:crypto';
import type { CapturedAudio, RecorderPort } from './dictationService.js';

/**
 * The main-process end of the hidden recorder window.
 *
 * Recording happens in a renderer, so every step is a message and every answer can be
 * late, wrong or missing. This class turns that into the three calls the dictation
 * service expects, and makes each one honest:
 *
 *  - `start()` resolves only once the renderer says the microphone is open, so a
 *    blocked microphone fails the start (and becomes `micUnavailable`) instead of
 *    surfacing, much later, as an empty recording.
 *  - Every capture carries a token. A late capture or error from an earlier recording
 *    carries an old token and is ignored, so it can never resolve or kill the next one.
 *  - `cancel()` tells the renderer to discard. It no longer encodes and sends audio that
 *    nobody wants.
 *  - An error nobody is waiting for (the device dies mid-recording) is handed to
 *    `onUnclaimedError`.
 */

export interface RecorderBridgeOptions {
  send: (channel: 'audio:start' | 'audio:stop', payload: { token: string; discard?: boolean }) => void;
  /** An error for the current recording that no start or stop is waiting on. */
  onUnclaimedError: (error: Error) => void;
  newToken?: () => string;
  /** How long the renderer may take to open the microphone. */
  startTimeoutMs?: number;
  /** How long the renderer may take to hand back the finished audio. */
  stopTimeoutMs?: number;
}

export const DEFAULT_START_TIMEOUT_MS = 10_000;
export const DEFAULT_STOP_TIMEOUT_MS = 4_000;

interface Pending<T> {
  token: string;
  resolve: (value: T) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

export class RecorderBridge implements RecorderPort {
  /** The recording this bridge is currently responsible for. */
  private current: string | null = null;
  private pendingStart: Pending<void> | null = null;
  private pendingStop: Pending<CapturedAudio> | null = null;

  constructor(private readonly options: RecorderBridgeOptions) {}

  start(): Promise<void> {
    // A recording that was never stopped or cancelled must not linger under the new one.
    if (this.current !== null) this.discard(this.current);
    const token = (this.options.newToken ?? randomUUID)();
    this.current = token;
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingStart = null;
        if (this.current === token) this.current = null;
        this.options.send('audio:stop', { token, discard: true });
        reject(new Error('The microphone did not respond.'));
      }, this.options.startTimeoutMs ?? DEFAULT_START_TIMEOUT_MS);
      timer.unref?.();
      this.pendingStart = {
        token,
        timer,
        resolve: () => {
          clearTimeout(timer);
          this.pendingStart = null;
          resolve();
        },
        reject: (error) => {
          clearTimeout(timer);
          this.pendingStart = null;
          if (this.current === token) this.current = null;
          reject(error);
        },
      };
      this.options.send('audio:start', { token });
    });
  }

  stop(): Promise<CapturedAudio> {
    const token = this.current;
    if (token === null) return Promise.reject(new Error('Recording is not running.'));
    return new Promise<CapturedAudio>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingStop = null;
        if (this.current === token) this.current = null;
        reject(new Error('The microphone did not return any audio.'));
      }, this.options.stopTimeoutMs ?? DEFAULT_STOP_TIMEOUT_MS);
      timer.unref?.();
      this.pendingStop = {
        token,
        timer,
        resolve: (audio) => {
          clearTimeout(timer);
          this.pendingStop = null;
          if (this.current === token) this.current = null;
          resolve(audio);
        },
        reject: (error) => {
          clearTimeout(timer);
          this.pendingStop = null;
          if (this.current === token) this.current = null;
          reject(error);
        },
      };
      this.options.send('audio:stop', { token, discard: false });
    });
  }

  async cancel(): Promise<void> {
    const token = this.current;
    if (token === null) return;
    this.current = null;
    this.options.send('audio:stop', { token, discard: true });
    const cancelled = new Error('The recording was cancelled.');
    this.pendingStart?.reject(cancelled);
    this.pendingStop?.reject(cancelled);
  }

  /** The renderer opened the microphone for `token`. */
  handleStarted(token: string): void {
    if (this.pendingStart?.token === token) this.pendingStart.resolve();
  }

  /** The renderer finished `token` and sent its audio. */
  handleCaptured(token: string, audio: CapturedAudio): void {
    if (this.pendingStop?.token === token) this.pendingStop.resolve(audio);
  }

  /** The renderer failed. `token` is absent only from an older renderer. */
  handleError(token: string | undefined, message: string): void {
    const error = new Error(message);
    if (this.pendingStart && (token === undefined || token === this.pendingStart.token)) {
      this.pendingStart.reject(error);
      return;
    }
    if (this.pendingStop && (token === undefined || token === this.pendingStop.token)) {
      this.pendingStop.reject(error);
      return;
    }
    if (this.current !== null && (token === undefined || token === this.current)) {
      this.options.onUnclaimedError(error);
    }
    // Anything else belongs to a recording that is already over.
  }

  private discard(token: string): void {
    this.current = null;
    this.options.send('audio:stop', { token, discard: true });
  }
}
