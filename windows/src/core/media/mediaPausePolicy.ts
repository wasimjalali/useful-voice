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
 *  - Holding is not proof. A resume plays a held session only if our pause CONFIRMED it
 *    (Windows answered true for it) and it is still Paused and untouched since (its timeline
 *    has not moved past `TOUCH_TOLERANCE_MS` from what the pause reported: scrubbed, or
 *    played and paused again). A refused pause, or a session the answer leaves out (the
 *    person paused it first), is dropped and logged, never played.
 *  - If the pause answer was lost, nothing was confirmed. Such a session is played only when
 *    its own timeline shows our pause: its last update is at or after the moment we asked
 *    and within `TOUCH_TOLERANCE_MS` of it. Otherwise it is left paused and logged, because
 *    it may be one the person paused themselves.
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

/** A session this policy paused, or asked to. */
export interface HeldSession {
  id: string;
  /** When we asked for the pause, in milliseconds since 1970 (same clock as `MediaSession.updated`). */
  requestedAt: number;
  /** Windows answered true to our pause of it. False while the answer is lost or not yet in. */
  confirmed: boolean;
  /** Its timeline right after the pause, when the pause read it. */
  settled?: { position: number; updated: number };
}

export interface PauseResult {
  /** Sessions Windows paused, with their timeline after the pause. */
  confirmed: MediaSession[];
  /** Sessions Windows refused to pause. */
  refused: string[];
  /**
   * Sessions whose pause the script could not finish (a WinRT call outran its cap, or threw):
   * they may or may not have paused, so they stay held, unconfirmed.
   */
  skipped: string[];
}

export interface ResumeResult {
  /** Sessions Windows refused to play. */
  refused: string[];
  /** Left paused: the person moved them after our pause. */
  touched: string[];
  /** Left paused: our pause of them was never confirmed. */
  unconfirmed: string[];
  /** The script could not finish with them (a call outran its cap or threw): they may still be paused. */
  skipped: string[];
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

/** What a resume does with one session that is Paused. The resume script applies the same rule. */
export function resumeVerdict(
  held: HeldSession,
  now: { position: number; updated: number },
): 'play' | 'touched' | 'unconfirmed' {
  if (held.confirmed) return held.settled && touchedSince(held.settled, now) ? 'touched' : 'play';
  const sinceRequest = now.updated - held.requestedAt;
  return sinceRequest >= 0 && sinceRequest <= TOUCH_TOLERANCE_MS ? 'play' : 'unconfirmed';
}

export interface MediaEffects {
  /** The sessions that are Playing right now. Changes nothing. */
  listPlaying(): Promise<MediaSession[]>;
  /** Pause these sessions where they are still Playing; say which paused and which Windows refused. */
  pause(ids: string[]): Promise<PauseResult>;
  /** Play each of these that is still Paused and passes `resumeVerdict`. */
  resume(sessions: HeldSession[]): Promise<ResumeResult>;
  /** The app is quitting: cut waits short (no settle, a tighter cap). Optional. */
  beginQuit?(): void;
}

export interface MediaPauseDeps {
  effects: MediaEffects;
  /** The `pauseMediaWhileDictating` setting, read when a recording starts. */
  enabled: () => boolean;
  /** Receives lines like `could not pause: <reason>`; the caller files them under "media". */
  log: (message: string) => void;
  /** How long a resume waits for a back-to-back dictation. 400 ms, as on macOS. */
  graceMs?: number;
  /** Milliseconds since 1970; the moment a pause is requested is recorded with it. */
  now?: () => number;
}

export class MediaPausePolicy {
  /** Sessions this policy paused (or asked to) and has not yet played again. */
  private readonly held = new Map<string, HeldSession>();
  private recording = false;
  private closed = false;
  /** Quit has begun: no new grace, no new pause. The quit's own resume is the only one left. */
  private shuttingDown = false;
  /** Effects run through this chain, so they never overlap and keep their order. */
  private chain: Promise<void> = Promise.resolve();
  /** The wait before a resume, while one is pending. */
  private grace: { timer: NodeJS.Timeout; done: Promise<void>; finish: () => void } | null = null;
  private readonly graceMs: number;
  private readonly now: () => number;
  private shutdownDone: Promise<boolean> | null = null;

  constructor(private readonly deps: MediaPauseDeps) {
    this.graceMs = deps.graceMs ?? 400;
    this.now = deps.now ?? (() => Date.now());
  }

  /** A recording is starting (or has just been asked to). */
  recordingStarted(): void {
    if (this.closed || this.shuttingDown) return;
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
      // Not confirmed until Windows says so.
      const requestedAt = this.now();
      for (const session of fresh) this.held.set(session.id, { id: session.id, requestedAt, confirmed: false });
      let result: PauseResult;
      try {
        result = await this.deps.effects.pause(fresh.map((session) => session.id));
      } catch (error) {
        // Kept held, unconfirmed: the resume plays one only if its timeline shows our pause.
        this.fail('could not pause', error);
        return;
      }
      for (const after of result.confirmed) {
        const entry = this.held.get(after.id);
        if (entry) {
          entry.confirmed = true;
          entry.settled = { position: after.position, updated: after.updated };
        }
      }
      for (const id of result.refused) {
        this.held.delete(id);
        this.note(`Could not pause ${id}: Windows refused the request`);
      }
      // A skipped session may have paused after all: kept held, unconfirmed, so the timeline
      // check at resume decides.
      for (const id of result.skipped) this.note(`Could not confirm the pause of ${id}: it will be checked when playing again`);
      // Asked for but neither confirmed, refused nor skipped: no longer playing when the pause
      // ran, so it is not ours to start again.
      for (const session of fresh) {
        const entry = this.held.get(session.id);
        if (entry && !entry.confirmed && !result.skipped.includes(session.id)) {
          this.held.delete(session.id);
          this.note(`Left ${session.id} alone: its pause was not confirmed`);
        }
      }
    });
  }

  /** The recording is over, for any reason. Safe to call more than once. */
  recordingEnded(): void {
    this.recording = false;
    // Once quit has begun the shutdown owns the resume. A grace here would only eat its budget
    // (the quit's own service cancel ends the recording after the shutdown has started).
    if (this.closed || this.shuttingDown) return;
    // Even with nothing held yet: a pause still in flight may be about to hold something,
    // and the resume runs behind it.
    this.enqueueResumeAfterGrace();
  }

  /**
   * Quit: play what is paused now, without the grace, and ignore everything after. Resolves
   * true when that finished within `budgetMs` and nothing is left held.
   */
  shutdown(budgetMs = 2500): Promise<boolean> {
    // Once: the app's own quit, an OS-initiated quit and a second Quit all arrive here.
    this.shutdownDone ??= this.runShutdown(budgetMs);
    return this.shutdownDone;
  }

  private async runShutdown(budgetMs: number): Promise<boolean> {
    this.shuttingDown = true;
    this.recording = false;
    this.cancelGrace();
    try {
      this.deps.effects.beginQuit?.();
    } catch (error) {
      this.fail('could not hurry the media effects', error);
    }
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
      const result = await this.deps.effects.resume(sessions);
      for (const id of result.refused) this.note(`Could not resume ${id}: Windows refused the request`);
      for (const id of result.touched) this.note(`Left ${id} paused: it was moved after the pause`);
      for (const id of result.unconfirmed) this.note(`Left ${id} paused: its pause was never confirmed`);
      for (const id of result.skipped) this.note(`Could not resume ${id}: the request did not finish`);
      // A skipped session may still be paused: on quit it stays held, so the caller is told.
      for (const session of sessions) {
        if (keepOnFailure && result.skipped.includes(session.id)) continue;
        this.held.delete(session.id);
      }
    } catch (error) {
      this.fail('could not resume', error);
      if (!keepOnFailure) for (const session of sessions) this.held.delete(session.id);
    }
  }

  private enqueue(work: () => Promise<void>): void {
    this.chain = this.chain.then(work).catch((error: unknown) => this.fail('unexpected failure', error));
  }

  private note(message: string): void {
    try {
      this.deps.log(message);
    } catch {
      // The log itself must never be the reason a dictation fails.
    }
  }

  private fail(what: string, error: unknown): void {
    try {
      this.deps.log(`${what}: ${error instanceof Error ? error.message : String(error)}`);
    } catch {
      // The log itself must never be the reason a dictation fails.
    }
  }
}
