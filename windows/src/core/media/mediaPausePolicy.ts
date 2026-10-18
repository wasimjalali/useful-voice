/**
 * Pause media while dictating: pause what is playing when a recording starts, play the
 * same sessions again when it ends.
 *
 * Pure policy with injected effects, so every end reason and the back-to-back case are
 * tested without a desktop. The effects are the only place that knows about Windows.
 *
 * Rules:
 *  - The pause is two calls. `listPlaying` is fast and changes nothing; the sessions it
 *    names are recorded as held BEFORE `pause` is sent, so a pause that lands but whose
 *    answer is lost (a host timeout, a slow await) can still be undone.
 *  - If the recording already ended when `listPlaying` returns, nothing is paused: that
 *    would only stutter the media.
 *  - A resume plays the held sessions that are still Paused. A session whose pause failed
 *    is still Playing and is left alone. A session the person touched after our pause
 *    (scrubbed, or played and paused again) is left alone too: its timeline moved on from
 *    what `pause` reported.
 *  - A resume waits a short grace (a dictation that starts inside it keeps the media paused,
 *    and nothing is paused twice) and checks again right before it is sent.
 *  - Effects run one at a time, in order. `recordingStarted` and `recordingEnded` return at
 *    once. Nothing here can delay a recording or surface as a dictation error: failures go
 *    to `log` and stop there.
 */

/** A media session at one moment: its id and where its timeline was. */
export interface MediaSession {
  id: string;
  /** Timeline position in milliseconds (0 when the app reports none). */
  position: number;
  /** When the app last updated its timeline, in milliseconds since 1970 (may be meaningless). */
  updated: number;
}

/** A session this policy paused. `settled` is its timeline right after the pause, when known. */
export interface HeldSession {
  id: string;
  settled?: { position: number; updated: number };
}

/**
 * How far a timeline may drift from what `pause` reported before the session counts as
 * touched. Apps publish their timeline a little after a pause lands, and positions are
 * rounded, so a tight comparison would call our own pause a touch. The resume script
 * applies the same number.
 */
export const TOUCH_TOLERANCE_MS = 1500;

/** Whether the person moved this session after our pause. Shared by the fakes and the script's rule. */
export function touchedSince(
  settled: { position: number; updated: number } | undefined,
  now: { position: number; updated: number },
): boolean {
  // No reading from the pause (its answer was lost): nothing to compare, so do not guess.
  if (!settled) return false;
  return Math.abs(now.position - settled.position) > TOUCH_TOLERANCE_MS || now.updated - settled.updated > TOUCH_TOLERANCE_MS;
}

export interface MediaEffects {
  /** The sessions that are Playing right now. Changes nothing. */
  listPlaying(): Promise<MediaSession[]>;
  /** Pause these sessions where they are still Playing; return the timeline of each that paused. */
  pause(ids: string[]): Promise<MediaSession[]>;
  /** Play each of these that is still Paused and untouched since `settled`. */
  resume(sessions: HeldSession[]): Promise<void>;
}

export interface MediaPauseDeps {
  effects: MediaEffects;
  /** The `pauseMediaWhileDictating` setting, read when a recording starts. */
  enabled: () => boolean;
  /** Receives lines like `could not pause: <reason>`; the caller files them under "media". */
  log: (message: string) => void;
  /** How long a resume waits for a back-to-back dictation. 400 ms, as on macOS. */
  graceMs?: number;
}

export class MediaPausePolicy {
  /** Sessions this policy paused (or asked to) and has not yet played again. */
  private readonly held = new Map<string, HeldSession>();
  private recording = false;
  private closed = false;
  /** Effects run through this chain, so they never overlap and keep their order. */
  private chain: Promise<void> = Promise.resolve();
  /** The wait before a resume, while one is pending. */
  private grace: { timer: NodeJS.Timeout; done: Promise<void>; finish: () => void } | null = null;
  private readonly graceMs: number;

  constructor(private readonly deps: MediaPauseDeps) {
    this.graceMs = deps.graceMs ?? 400;
  }

  /** A recording is starting (or has just been asked to). */
  recordingStarted(): void {
    if (this.closed) return;
    this.recording = true;
    // A dictation inside the grace keeps what is paused, paused.
    this.cancelGrace();
    this.enqueue(async () => {
      // Ended or cancelled before this got its turn: pause nothing.
      if (!this.recording || this.closed) return;
      let on: boolean;
      try {
        on = this.deps.enabled();
      } catch (error) {
        this.fail('could not read the setting', error);
        return;
      }
      if (!on) return;
      let listed: MediaSession[];
      try {
        listed = await this.deps.effects.listPlaying();
      } catch (error) {
        this.fail('could not list the playing media', error);
        return;
      }
      // The recording ended while the list was coming back: pausing now would only stutter it.
      if (!this.recording || this.closed) return;
      const fresh = listed.filter((session) => !this.held.has(session.id));
      if (fresh.length === 0) return;
      // Held before the pause is sent: if its answer is lost, the pause may still have landed.
      for (const session of fresh) this.held.set(session.id, { id: session.id });
      try {
        for (const after of await this.deps.effects.pause(fresh.map((session) => session.id))) {
          const entry = this.held.get(after.id);
          if (entry) entry.settled = { position: after.position, updated: after.updated };
        }
      } catch (error) {
        // Kept held anyway; a session that did not pause is still Playing and the resume skips it.
        this.fail('could not pause', error);
      }
    });
  }

  /** The recording is over, for any reason. Safe to call more than once. */
  recordingEnded(): void {
    this.recording = false;
    if (this.closed) return;
    // Even with nothing held yet: a pause still in flight may be about to hold something,
    // and the resume runs behind it.
    this.enqueueResumeAfterGrace();
  }

  /**
   * Quit: play what is paused now, without the grace, and ignore everything after. Resolves
   * true when that finished within `budgetMs` and nothing is left held.
   */
  async shutdown(budgetMs = 2500): Promise<boolean> {
    this.recording = false;
    this.cancelGrace();
    this.enqueue(() => this.resumeHeld(true));
    let timer: NodeJS.Timeout | undefined;
    const finished = await Promise.race([
      this.settled().then(() => true),
      new Promise<boolean>((resolve) => {
        timer = setTimeout(() => resolve(false), budgetMs);
      }),
    ]);
    if (timer) clearTimeout(timer);
    this.closed = true;
    return finished && this.held.size === 0;
  }

  /** Resolves once every effect asked for so far, and any resume waiting out its grace, has finished. */
  async settled(): Promise<void> {
    for (;;) {
      if (this.grace) {
        await this.grace.done;
        continue;
      }
      const seen = this.chain;
      await seen;
      if (seen === this.chain && !this.grace) return;
    }
  }

  private enqueueResumeAfterGrace(): void {
    this.cancelGrace();
    let finish!: () => void;
    const done = new Promise<void>((resolve) => {
      finish = resolve;
    });
    const timer = setTimeout(() => {
      this.grace = null;
      this.enqueue(() => this.resumeHeld(false));
      finish();
    }, this.graceMs);
    timer.unref?.();
    this.grace = { timer, done, finish };
  }

  private cancelGrace(): void {
    const grace = this.grace;
    if (!grace) return;
    clearTimeout(grace.timer);
    this.grace = null;
    grace.finish();
  }

  /**
   * `keepOnFailure` is for quit: what could not be played stays held, so the caller can tell
   * that something may stay paused. In normal use it is dropped: a session that will not play
   * is the person's to press, and a late retry could play something they paused themselves.
   */
  private async resumeHeld(keepOnFailure: boolean): Promise<void> {
    // Checked as late as possible: a new dictation began, so the media stays paused for it.
    if (this.recording || this.held.size === 0) return;
    const sessions = [...this.held.values()].map((entry) => ({ ...entry }));
    try {
      await this.deps.effects.resume(sessions);
      for (const session of sessions) this.held.delete(session.id);
    } catch (error) {
      this.fail('could not resume', error);
      if (!keepOnFailure) for (const session of sessions) this.held.delete(session.id);
    }
  }

  private enqueue(work: () => Promise<void>): void {
    this.chain = this.chain.then(work).catch((error: unknown) => this.fail('unexpected failure', error));
  }

  private fail(what: string, error: unknown): void {
    try {
      this.deps.log(`${what}: ${error instanceof Error ? error.message : String(error)}`);
    } catch {
      // The log itself must never be the reason a dictation fails.
    }
  }
}
