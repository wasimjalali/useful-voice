/**
 * Pause media while dictating: pause what is playing when a recording starts, play the
 * same sessions again when it ends.
 *
 * Pure policy with injected effects, so every end reason and the back-to-back case are
 * tested without a desktop. The effects are the only place that knows about Windows.
 *
 * Rules:
 *  - Only sessions that were Playing are paused, and only those are remembered.
 *  - A resume plays just those sessions, and the effect skips any that is no longer Paused
 *    (the person already pressed play, or closed it). Nothing is ever started that was not
 *    playing before the dictation.
 *  - Effects run one at a time, in the order they were asked, and each checks at the moment
 *    it runs whether a recording is on. A dictation that starts while a resume is waiting
 *    therefore keeps the media paused, and never pauses it twice.
 *  - `recordingStarted` and `recordingEnded` return at once. Nothing here can delay a
 *    recording or surface as a dictation error: failures go to `log` and stop there.
 */

export interface MediaEffects {
  /** Pause every session that is Playing and return the ids of the ones it paused. */
  pausePlaying(): Promise<string[]>;
  /** Play each of these sessions that is still Paused. */
  resume(ids: string[]): Promise<void>;
}

export interface MediaPauseDeps {
  effects: MediaEffects;
  /** The `pauseMediaWhileDictating` setting, read when a recording starts. */
  enabled: () => boolean;
  /** Receives lines like `could not pause: <reason>`; the caller files them under "media". */
  log: (message: string) => void;
}

export class MediaPausePolicy {
  /** Sessions this policy paused and has not yet played again. */
  private readonly held = new Set<string>();
  private recording = false;
  private closed = false;
  /** Effects run through this chain, so they never overlap and keep their order. */
  private chain: Promise<void> = Promise.resolve();

  constructor(private readonly deps: MediaPauseDeps) {}

  /** A recording is starting (or has just been asked to). */
  recordingStarted(): void {
    if (this.closed) return;
    this.recording = true;
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
      try {
        for (const id of await this.deps.effects.pausePlaying()) this.held.add(id);
      } catch (error) {
        this.fail('could not pause', error);
      }
    });
  }

  /** The recording is over, for any reason. Safe to call more than once. */
  recordingEnded(): void {
    this.recording = false;
    this.enqueue(() => this.resumeHeld());
  }

  /** Quit: play what is paused, and ignore everything after. Resolves when that is done. */
  async shutdown(): Promise<void> {
    this.recording = false;
    this.enqueue(() => this.resumeHeld());
    await this.settled();
    this.closed = true;
  }

  /** Resolves once every effect asked for so far has finished. */
  async settled(): Promise<void> {
    let seen: Promise<void>;
    do {
      seen = this.chain;
      await seen;
    } while (seen !== this.chain);
  }

  private async resumeHeld(): Promise<void> {
    // A new dictation began while this waited: the media stays paused for it.
    if (this.recording || this.held.size === 0) return;
    const ids = [...this.held];
    this.held.clear();
    try {
      await this.deps.effects.resume(ids);
    } catch (error) {
      // Not retried: a session that will not play is the person's to press.
      this.fail('could not resume', error);
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
