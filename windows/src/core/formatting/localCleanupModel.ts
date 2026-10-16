import type { CleanupModel, CleanupTextGenerator } from './cleanupModel.js';
import { DEFAULT_CLEANUP_IDLE_UNLOAD_MS } from './cleanupModelPolicy.js';
import { s1MiniPromptParts } from './s1MiniModel.js';

/** What the model needs from the outside world, so a test can run a minute in no time. */
export interface CleanupClock {
  now(): number;
  setTimer(callback: () => void, ms: number): () => void;
}

export const REAL_CLEANUP_CLOCK: CleanupClock = {
  now: () => performance.now(),
  setTimer: (callback, ms) => {
    const handle = setTimeout(callback, ms);
    handle.unref();
    return () => clearTimeout(handle);
  },
};

export interface LocalCleanupModelOptions {
  modelPath: string;
  generator: CleanupTextGenerator;
  idleUnloadMs?: number;
  clock?: CleanupClock;
  /** Where a load or run error goes. Never thrown to the caller. */
  warn?: (message: string) => void;
}

/**
 * Runs the cleanup model on demand and keeps it in memory only while it is being used.
 * Mirrors `LocalCleanupModel.swift`.
 *
 * - `begin()` is called when a dictation starts: it loads the weights while the person is
 *   still talking and cancels any pending unload. Dictations in progress are counted, so a
 *   second `begin` before the first `end` keeps the weights loaded until both have ended.
 * - `end()` is called when the dictation ends or is cancelled: when no dictation is left in
 *   progress it starts the idle timer.
 * - `clean` loads on demand if `begin` was not called or the weights were unloaded, runs the
 *   model, and starts the idle timer again. Nothing here ever rejects: a load or run error
 *   is reported to `warn` and `clean` returns null, so the pipeline keeps the rules text.
 * - After `idleUnloadMs` (60 s by default) with no `begin` or `clean`, the weights are
 *   freed. A dictation that is still in progress is never unloaded under: the timer only runs
 *   while the count of dictations in progress is zero.
 * - `dispose()` ends the model for good, at once, without queueing behind a load.
 *
 * Load, run and unload are queued one after another, so they never overlap.
 */
export class LocalCleanupModel implements CleanupModel {
  private readonly modelPath: string;
  private readonly generator: CleanupTextGenerator;
  private readonly idleUnloadMs: number;
  private readonly clock: CleanupClock;
  private readonly warn: (message: string) => void;
  private loaded = false;
  private disposed = false;
  private inProgress = 0;
  private cancelIdle: (() => void) | null = null;
  private idleGeneration = 0;
  private tail: Promise<unknown> = Promise.resolve();

  constructor(options: LocalCleanupModelOptions) {
    this.modelPath = options.modelPath;
    this.generator = options.generator;
    this.idleUnloadMs = options.idleUnloadMs ?? DEFAULT_CLEANUP_IDLE_UNLOAD_MS;
    this.clock = options.clock ?? REAL_CLEANUP_CLOCK;
    this.warn = options.warn ?? (() => undefined);
  }

  get isLoaded(): boolean {
    return this.loaded;
  }

  /** A dictation started: load now and hold the weights until `end`. */
  begin(): Promise<void> {
    this.inProgress += 1;
    this.cancelIdleTimer();
    return this.enqueue(async () => {
      await this.ensureLoaded();
    });
  }

  /** The dictation ended or was cancelled: start the idle timer. */
  end(): void {
    this.inProgress = Math.max(0, this.inProgress - 1);
    if (this.inProgress === 0) this.armIdleTimer();
  }

  /** Ends the model now and for good: the worker is killed even in the middle of a load. */
  async dispose(): Promise<void> {
    this.disposed = true;
    this.cancelIdleTimer();
    this.loaded = false;
    if (this.generator.kill) this.generator.kill();
    else await this.generator.unload().catch(() => undefined);
  }

  unload(): Promise<void> {
    this.cancelIdleTimer();
    return this.enqueue(() => this.unloadNow());
  }

  async clean(text: string, controlLine: string, deadline: number): Promise<string | null> {
    this.cancelIdleTimer();
    try {
      return await this.enqueue(async () => {
        if (this.clock.now() >= deadline) return null;
        if (!(await this.ensureLoaded())) return null;
        try {
          return await this.generator.generate(s1MiniPromptParts(controlLine, text), deadline);
        } catch (error) {
          this.warn(`cleanup model run failed: ${describe(error)}`);
          return null;
        }
      });
    } finally {
      if (this.inProgress === 0) this.armIdleTimer();
    }
  }

  private enqueue<T>(work: () => Promise<T>): Promise<T> {
    const result = this.tail.then(work, work);
    this.tail = result.catch(() => undefined);
    return result;
  }

  private async ensureLoaded(): Promise<boolean> {
    if (this.disposed) return false;
    if (this.loaded) return true;
    try {
      await this.generator.load(this.modelPath);
      this.loaded = !this.disposed;
    } catch (error) {
      this.warn(`cleanup model load failed: ${describe(error)}`);
    }
    return this.loaded;
  }

  private async unloadNow(): Promise<void> {
    if (!this.loaded) return;
    this.loaded = false;
    try {
      await this.generator.unload();
    } catch (error) {
      this.warn(`cleanup model unload failed: ${describe(error)}`);
    }
  }

  private cancelIdleTimer(): void {
    this.cancelIdle?.();
    this.cancelIdle = null;
    this.idleGeneration += 1;
  }

  private armIdleTimer(): void {
    if (this.disposed) return;
    this.cancelIdle?.();
    this.idleGeneration += 1;
    const generation = this.idleGeneration;
    this.cancelIdle = this.clock.setTimer(() => {
      if (generation !== this.idleGeneration || !this.loaded) return;
      this.cancelIdle = null;
      void this.enqueue(() => (generation === this.idleGeneration ? this.unloadNow() : Promise.resolve()));
    }, this.idleUnloadMs);
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
