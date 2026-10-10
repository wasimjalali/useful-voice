/**
 * What the HUD shows, and for how long.
 *
 * Pure: no Electron, Node or DOM import, so the rules live in one place and run the same
 * everywhere. The main process feeds it the dictation status, outcome and telemetry and
 * forwards whatever view it emits to the HUD window, which only draws it. Keeping the
 * timing here (and not in the window) is what lets a persistent error be replaced by the
 * next dictation, and lets the same view changes be announced to a screen reader.
 */

import type { DictationError, DictationOutcomeEvent, DictationTelemetry } from './models.js';
import { MULTILINGUAL_CODE_SWITCHING, findLanguage } from './transcription/languages.js';

/** Done, language switch and cancelled disappear on their own. */
export const HUD_DONE_MS = 1200;
export const HUD_LANGUAGE_MS = 1000;
export const HUD_CANCELLED_MS = 1500;
/** Errors and "Copied. Press Ctrl+V to paste" stay until the next dictation, a button, the x or this long. */
export const HUD_PERSISTENT_MS = 8000;
/** The exit animation (sink 6 px, 160 ms). The window is hidden after it has played. */
export const HUD_EXIT_MS = 160;

export type HudView =
  | { kind: 'recording'; elapsedSeconds: number; stopsIn?: number }
  | { kind: 'transcribing' }
  | { kind: 'inserting' }
  /** A window or retry dictation: nothing is pasted, the text is saved and copied. */
  | { kind: 'saving' }
  /** `saved`: the text was saved and copied (window or retry dictation), not inserted. */
  | { kind: 'done'; words: number; saved: boolean }
  | { kind: 'copied' }
  | { kind: 'cancelled' }
  | { kind: 'error'; error: DictationError }
  | { kind: 'language'; name: string };

/** A view plus the counter that tells the window whether it is a new one or an update of the same. */
export type HudFrame = HudView & { seq: number };

export interface HudStatusInput {
  state: 'idle' | 'recording' | 'transcribing' | 'delivering' | 'error';
  message?: string;
  error?: DictationError;
  elapsedSeconds?: number;
  /** How the text will reach the user: pasted into the app in front, or only copied. */
  delivery?: 'paste' | 'copy';
}

export interface HudClock {
  setTimeout(callback: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

const REAL_CLOCK: HudClock = {
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

/** The kinds that mean a dictation is still in flight, so an idle status ends them. */
const IN_FLIGHT = new Set<HudView['kind']>(['recording', 'transcribing', 'inserting', 'saving', 'error']);

/** Views that wait for the user; a language confirmation must not destroy them. */
const PERSISTENT = new Set<HudView['kind']>(['error', 'copied']);

export class HudModel {
  private seq = 0;
  private current: HudFrame | null = null;
  /** The view a language confirmation is covering for a second, and when it would have timed out. */
  private covered: { frame: HudFrame; deadline: number | null } | null = null;
  /** When the current view times out (persistent and timed views), or null. */
  private deadline: number | null = null;
  private timer: unknown = null;

  constructor(
    private readonly emit: (frame: HudFrame | null) => void,
    private readonly clock: HudClock = REAL_CLOCK,
  ) {}

  get frame(): HudFrame | null {
    return this.current;
  }

  /** The dictation status. Every state replaces whatever is showing, so nothing stale survives. */
  status(status: HudStatusInput): void {
    switch (status.state) {
      case 'recording':
        this.show({ kind: 'recording', elapsedSeconds: status.elapsedSeconds ?? 0 });
        return;
      case 'transcribing':
        this.show({ kind: 'transcribing' });
        return;
      case 'delivering':
        this.show({ kind: status.delivery === 'copy' ? 'saving' : 'inserting' });
        return;
      case 'error':
        this.show(
          { kind: 'error', error: status.error ?? { kind: 'providerFailed', message: status.message ?? 'Something went wrong.' } },
          HUD_PERSISTENT_MS,
        );
        return;
      case 'idle':
        // The outcome arrives before idle, so a finished dictation is already showing its
        // done line. Idle with anything still in flight on screen means it ended without one.
        if (this.current && IN_FLIGHT.has(this.current.kind)) this.hide();
        return;
    }
  }

  /** How a dictation ended. Sent once, just before the idle status. */
  outcome(event: DictationOutcomeEvent): void {
    if (event.kind === 'cancelled') {
      this.show({ kind: 'cancelled' }, HUD_CANCELLED_MS);
      return;
    }
    if (event.result === 'copiedNotPasted') {
      this.show({ kind: 'copied' }, HUD_PERSISTENT_MS);
      return;
    }
    this.show({ kind: 'done', words: event.words, saved: event.result === 'copied' }, HUD_DONE_MS);
  }

  /** Live numbers while recording. Updates the same view, so it never re-enters. */
  telemetry(telemetry: DictationTelemetry): void {
    // Whichever auto-stop comes first.
    const stopsIn =
      telemetry.silenceRemaining !== undefined && telemetry.maxRemaining !== undefined
        ? Math.min(telemetry.silenceRemaining, telemetry.maxRemaining)
        : (telemetry.silenceRemaining ?? telemetry.maxRemaining);
    const patch = (frame: HudFrame): HudFrame | null => {
      if (frame.kind !== 'recording') return null;
      if (frame.elapsedSeconds === telemetry.elapsedSeconds && frame.stopsIn === stopsIn) return null;
      const next: Extract<HudFrame, { kind: 'recording' }> = { ...frame, elapsedSeconds: telemetry.elapsedSeconds };
      if (stopsIn === undefined) delete next.stopsIn;
      else next.stopsIn = stopsIn;
      return next;
    };
    if (this.covered) {
      // Behind the language confirmation: keep it current for when it is uncovered.
      this.covered = { ...this.covered, frame: patch(this.covered.frame) ?? this.covered.frame };
      return;
    }
    if (!this.current) return;
    const next = patch(this.current);
    if (!next) return;
    this.current = next;
    this.emit(next);
  }

  /** The language was switched. While a dictation is in flight the confirmation covers it for a second. */
  language(name: string): void {
    const coverable = this.current && (IN_FLIGHT.has(this.current.kind) || PERSISTENT.has(this.current.kind));
    if (coverable && this.current && !this.covered) this.covered = { frame: this.current, deadline: this.deadline };
    this.show({ kind: 'language', name }, HUD_LANGUAGE_MS, true);
  }

  /** The x, a fix button, or anything else that ends the HUD now. */
  dismiss(): void {
    this.hide();
  }

  private show(view: HudView, autoHideMs?: number, keepCovered = false): void {
    this.clearTimer();
    if (!keepCovered) this.covered = null;
    this.seq += 1;
    const frame: HudFrame = { ...view, seq: this.seq };
    this.current = frame;
    this.deadline = autoHideMs === undefined ? null : Date.now() + autoHideMs;
    this.emit(frame);
    if (autoHideMs !== undefined) {
      const seq = this.seq;
      this.timer = this.clock.setTimeout(() => {
        // A newer view replaced this one: its own timer is the one that counts.
        if (this.current?.seq !== seq) return;
        this.timer = null;
        this.finish();
      }, autoHideMs);
    }
  }

  /** The timed view ran out: uncover what it was covering, or hide. */
  private finish(): void {
    if (this.covered) {
      const { frame, deadline } = this.covered;
      this.covered = null;
      // A persistent view keeps what was left of its own time, so it still ends on schedule.
      const remaining = deadline === null ? null : deadline - Date.now();
      if (remaining !== null && remaining <= 0) {
        this.hide();
        return;
      }
      this.seq += 1;
      this.current = { ...frame, seq: this.seq };
      this.deadline = deadline;
      this.emit(this.current);
      if (remaining !== null) {
        const seq = this.seq;
        this.timer = this.clock.setTimeout(() => {
          if (this.current?.seq !== seq) return;
          this.timer = null;
          this.finish();
        }, remaining);
      }
      return;
    }
    this.hide();
  }

  private hide(): void {
    this.clearTimer();
    this.covered = null;
    this.deadline = null;
    if (!this.current) return;
    this.current = null;
    this.emit(null);
  }

  private clearTimer(): void {
    if (this.timer !== null) {
      this.clock.clearTimeout(this.timer);
      this.timer = null;
    }
  }
}

// ---------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------

/** "0:12" */
export function formatClock(seconds: number): string {
  const whole = Math.max(0, Math.floor(seconds));
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
}

/** "24 words", German-region grouping above 999 ("1.240 words"). */
export function formatWords(words: number): string {
  const grouped = String(words).replace(/\B(?=(\d{3})+(?!\d))/g, '.');
  return `${grouped} ${words === 1 ? 'word' : 'words'}`;
}

/** One line for the capsule. The full message goes to the log, the tooltip and the screen reader. */
export function errorTitle(error: DictationError): string {
  switch (error.kind) {
    case 'micUnavailable':
      return 'Microphone access is off';
    case 'stopFailed':
      return 'Recording failed';
    case 'noSpeech':
      return 'No speech heard';
    case 'tooShort':
      return 'Recording was too short';
    case 'noProvider':
      return 'Add your Deepgram key';
    case 'keyRejected':
      return 'Deepgram key rejected';
    case 'outOfCredits':
      return 'Deepgram credit is used up';
    case 'offline':
      return 'No connection';
    case 'timedOut':
      return 'Deepgram took too long';
    case 'providerFailed':
      return 'Transcription failed';
    case 'deliveryFailed':
      return 'Could not deliver the text';
  }
}

/** The fix button's text, or null when there is nothing to offer. */
export function fixLabel(error: DictationError): string | null {
  switch (error.fix) {
    case 'retry':
      return 'Retry last recording';
    case 'openMicrophoneSettings':
    case 'openEngineSettings':
      return 'Open settings';
    default:
      return null;
  }
}

/** What the capsule says for a view, for the accessible label and the announcement. */
export function hudLabel(view: HudView): string {
  switch (view.kind) {
    case 'recording':
      return `Recording, ${formatClock(view.elapsedSeconds)}`;
    case 'transcribing':
      return 'Transcribing';
    case 'inserting':
      return 'Inserting';
    case 'saving':
      return 'Saving';
    case 'done':
      return `${view.saved ? 'Saved and copied' : 'Inserted'}, ${formatWords(view.words)}`;
    case 'copied':
      return 'Copied. Press Ctrl+V to paste';
    case 'cancelled':
      return 'Cancelled';
    case 'error':
      return errorTitle(view.error);
    case 'language':
      return `Language: ${view.name}`;
  }
}

/** The name shown for a stored language value: the language's own name, or the mode's. */
export function languageLabel(value: string): string {
  if (value === 'auto') return 'Auto-detect';
  if (value === MULTILINGUAL_CODE_SWITCHING.code) return 'Multiple languages';
  return findLanguage(value)?.nativeName ?? 'Auto-detect';
}
