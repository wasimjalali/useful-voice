import { fork, type ChildProcess } from 'node:child_process';
import type { CleanupTextGenerator, GeneratorPrompt } from '../../core/formatting/cleanupModel.js';
import { s1MiniPromptPrefix } from '../../core/formatting/s1MiniModel.js';

/**
 * Runs S1-mini through node-llama-cpp in a child process (`cleanupWorker.js`). The Windows
 * counterpart of macOS `LlamaCleanupGenerator`.
 *
 * Why a child process: unloading is `kill`, which gives every byte back to the system at
 * once, a stuck or crashing run cannot take the dictation app with it, and the native
 * addon never loads into the Electron main process at all unless the hidden flag is on.
 * The child is the app's own executable run as plain Node (`ELECTRON_RUN_AS_NODE`).
 *
 * `LocalCleanupModel` queues calls, so at most one `load`, `generate` or `unload` runs at a
 * time. A `generate` past its deadline tells the worker to stop and rejects at once; if the
 * worker does not confirm in `abortGraceMs` (3 s: a kill costs a full reload, and a busy machine
 * can take a moment to notice the abort) it is killed, and the next call starts a new one.
 */
export interface LlamaGeneratorOptions {
  /** Absolute path of the compiled `cleanupWorker.js`. */
  workerScript: string;
  warn?: (message: string) => void;
  /** Cold start of the weights from a slow disk can take a while; the deadline still rules. */
  loadTimeoutMs?: number;
  abortGraceMs?: number;
  exitGraceMs?: number;
  /** The clock deadlines are on. Tests pass their own. */
  now?: () => number;
  /** Replaces `child_process.fork`. Tests pass a fake. */
  spawn?: (script: string) => ChildProcess;
}

type WorkerMessage =
  | { type: 'ready' }
  | { type: 'loaded'; loadMs: number }
  | { type: 'result'; id: number; text: string; ms: number }
  | { type: 'error'; id?: number; message: string };

export class LlamaCleanupGenerator implements CleanupTextGenerator {
  private readonly options: Required<Omit<LlamaGeneratorOptions, 'spawn'>> & Pick<LlamaGeneratorOptions, 'spawn'>;
  private child: ChildProcess | null = null;
  private modelPath: string | null = null;
  private nextId = 1;
  /** Who is waiting on which child, so a killed worker's exit never answers a new worker's call. */
  private channels = new Map<ChildProcess, Channel>();
  private stderrTail = '';
  /** Settles when the worker has stopped a run that timed out, or been killed. */
  private aborting: Promise<void> = Promise.resolve();

  constructor(options: LlamaGeneratorOptions) {
    this.options = {
      warn: () => undefined,
      loadTimeoutMs: 120_000,
      abortGraceMs: 3000,
      exitGraceMs: 3000,
      now: () => performance.now(),
      ...options,
    };
  }

  get isRunning(): boolean {
    return this.child !== null;
  }

  async load(modelPath: string): Promise<void> {
    this.modelPath = modelPath;
    if (this.child) return;
    const child = this.start();
    try {
      await this.waitFor(
        child,
        (message) => message.type === 'loaded' || (message.type === 'error' && message.id === undefined),
        this.options.loadTimeoutMs,
        'loading the model',
        () => post(child, { type: 'load', path: modelPath, prefix: s1MiniPromptPrefix() }),
      );
    } catch (error) {
      this.kill();
      throw error;
    }
  }

  async generate(prompt: GeneratorPrompt, deadline: number): Promise<string> {
    await this.aborting;
    const { now } = this.options;
    if (now() >= deadline) throw new Error('deadline');
    if (!this.child) {
      if (!this.modelPath) throw new Error('the model is not loaded');
      await this.load(this.modelPath);
      // The load may have used the whole budget; the weights stay loaded for the next call.
      if (now() >= deadline) throw new Error('deadline');
    }
    const child = this.child;
    if (!child) throw new Error('the worker is not running');
    const id = this.nextId++;
    const reply = await this.waitFor(
      child,
      (message) => (message.type === 'result' || message.type === 'error') && message.id === id,
      Math.max(0, deadline - now()),
      'the model run',
      () => post(child, { type: 'generate', id, head: prompt.head, user: prompt.user, tail: prompt.tail }),
      () => this.abortRun(child, id),
    );
    return (reply as { text: string }).text;
  }

  async unload(): Promise<void> {
    const child = this.child;
    if (!child) return;
    this.child = null;
    const exited = new Promise<void>((resolve) => child.once('exit', () => resolve()));
    try {
      post(child, { type: 'dispose' });
    } catch {
      // The channel is already closed; the kill below finishes the job.
    }
    const timer = setTimeout(() => child.kill(), this.options.exitGraceMs);
    await exited;
    clearTimeout(timer);
  }

  private start(): ChildProcess {
    const spawn = this.options.spawn ?? defaultSpawn;
    const child = spawn(this.options.workerScript);
    this.child = child;
    const channel: Channel = { listeners: new Set(), exitWaiters: new Set() };
    this.channels.set(child, channel);
    this.stderrTail = '';
    child.stderr?.on('data', (chunk: Buffer) => {
      this.stderrTail = (this.stderrTail + chunk.toString()).slice(-2000);
    });
    child.on('message', (message: WorkerMessage) => {
      for (const listener of [...channel.listeners]) listener(message);
    });
    child.once('exit', (code, signal) => {
      if (this.child === child) this.child = null;
      this.channels.delete(child);
      const tail = this.stderrTail.trim();
      const reason = `the model worker exited (${signal ?? code})${tail ? `: ${tail}` : ''}`;
      for (const waiter of [...channel.exitWaiters]) waiter(reason);
    });
    let spawned = false;
    child.once('spawn', () => {
      spawned = true;
    });
    // `on`, not `once`: a second error event with no listener would throw in the main process.
    child.on('error', (error) => {
      if (this.child === child) this.child = null;
      const what = spawned ? 'the model worker failed' : 'the model worker failed to start';
      for (const waiter of [...channel.exitWaiters]) waiter(`${what}: ${error.message}`);
    });
    return child;
  }

  /**
   * Sends a request and waits for the first message `match` accepts. An `error` message
   * rejects with its text; the worker exiting or the timer rejects too.
   */
  private waitFor(
    child: ChildProcess,
    match: (message: WorkerMessage) => boolean,
    ms: number,
    what: string,
    send: () => void,
    onDeadline?: () => void,
  ): Promise<WorkerMessage> {
    const channel = this.channels.get(child);
    if (!channel) return Promise.reject(new Error('the model worker has already exited'));
    return new Promise<WorkerMessage>((resolve, reject) => {
      const finish = () => {
        clearTimeout(timer);
        channel.listeners.delete(listener);
        channel.exitWaiters.delete(onExit);
      };
      const listener = (message: WorkerMessage) => {
        if (!match(message)) return;
        finish();
        if (message.type === 'error') reject(new Error(message.message));
        else resolve(message);
      };
      const onExit = (reason: string) => {
        finish();
        reject(new Error(reason));
      };
      const timer = setTimeout(() => {
        finish();
        onDeadline?.();
        reject(new Error(onDeadline ? 'deadline' : `timed out ${what}`));
      }, ms);
      channel.listeners.add(listener);
      channel.exitWaiters.add(onExit);
      try {
        send();
      } catch (error) {
        finish();
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  /** Stop a run that passed its deadline; kill the worker if it does not confirm. */
  private abortRun(child: ChildProcess, id: number): void {
    const channel = this.channels.get(child);
    if (!channel) return;
    this.aborting = new Promise<void>((resolve) => {
      const done = () => {
        clearTimeout(timer);
        channel.listeners.delete(listener);
        channel.exitWaiters.delete(done);
        resolve();
      };
      const listener = (message: WorkerMessage) => {
        if ((message.type === 'error' || message.type === 'result') && message.id === id) done();
      };
      const timer = setTimeout(() => {
        this.options.warn('the model worker did not stop at the deadline; restarting it');
        this.killChild(child);
        done();
      }, this.options.abortGraceMs);
      channel.listeners.add(listener);
      channel.exitWaiters.add(done);
      try {
        post(child, { type: 'abort', id });
      } catch {
        this.killChild(child);
        done();
      }
    });
  }

  /** Ends the worker at once, whatever it is doing; a pending call rejects. */
  kill(): void {
    if (this.child) this.killChild(this.child);
  }

  private killChild(child: ChildProcess): void {
    if (this.child === child) this.child = null;
    child.kill();
  }
}

interface Channel {
  listeners: Set<(message: WorkerMessage) => void>;
  exitWaiters: Set<(reason: string) => void>;
}

/** Sends to the worker, or throws when the channel is closed (a dead worker, a closed pipe). */
function post(child: ChildProcess, message: Record<string, unknown>): void {
  if (!child.connected) throw new Error('the model worker is not connected');
  child.send(message, (error) => {
    // A failed write comes back here, not as a throw; route it to the error handler.
    if (error) child.emit('error', error);
  });
}

function defaultSpawn(script: string): ChildProcess {
  return fork(script, [], {
    execArgv: [],
    env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
    stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
  });
}
