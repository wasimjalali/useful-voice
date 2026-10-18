import { randomUUID } from 'node:crypto';
import { StringDecoder } from 'node:string_decoder';

/**
 * One long-lived PowerShell process that runs the hotkey and delivery scripts.
 *
 * A one-shot `powershell.exe` per call costs a process start plus an `Add-Type` C#
 * compile every time (up to a second or more, cold), and the delivery path made three
 * of them. Here the process starts once at app ready, the C# types are compiled once,
 * and each call is a line over stdin.
 *
 * The protocol is one line per request: `<base64 script>|<id>`. The bootstrap below
 * decodes it, runs it, and prints `UVEND:<id>` when done, so output is cut at a
 * sentinel nobody else can guess. The host runs one request at a time (a queue), so a
 * paste can never overlap a window read.
 *
 * Failure handling, because a wedged host would be worse than no host:
 *  - every request has its own time limit; when the one being run exceeds it the host
 *    is killed (a script that may still be about to press Ctrl+V must not outlive its
 *    caller) and restarted in the background;
 *  - a host that dies is restarted, but a host that keeps dying is given up on, and
 *    callers fall back to a one-shot process;
 *  - the error says whether the request line was written (`sent`), because only a
 *    request that was never sent is safe to run again somewhere else.
 *
 * This file takes the process as a parameter and imports nothing from Electron, so it
 * is tested with a fake child on any platform.
 */

export type HostErrorKind =
  /** The host could not start, or has been given up on. Nothing was sent. */
  | 'unavailable'
  /** The request outlived its time limit. */
  | 'timeout'
  /** The host died while the request was running. */
  | 'exited'
  /** The caller's signal aborted before the request was written. */
  | 'aborted'
  /** The script itself threw. */
  | 'script';

export class PowerShellHostError extends Error {
  constructor(
    readonly kind: HostErrorKind,
    message: string,
    /** Whether the request line reached the host, so the script may have run. */
    readonly sent: boolean,
  ) {
    super(message);
    this.name = 'PowerShellHostError';
  }
}

/** The part of a child process the host uses. Node's `ChildProcess` satisfies it. */
export interface HostChild {
  stdin: { write(data: string): unknown; on?(event: 'error', listener: (error: Error) => void): unknown } | null;
  stdout: { on(event: 'data', listener: (chunk: Buffer | string) => void): unknown } | null;
  stderr: { on(event: 'data', listener: (chunk: Buffer | string) => void): unknown } | null;
  on(event: 'exit', listener: (code: number | null) => void): unknown;
  on(event: 'error', listener: (error: Error) => void): unknown;
  kill(): unknown;
}

/**
 * Runs forever, one request per stdin line. Single quotes only and no characters that
 * need escaping, and it is sent as `-EncodedCommand`, so no quoting layer can touch it.
 */
export const HOST_BOOTSTRAP = [
  "$ErrorActionPreference = 'Stop'",
  '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)',
  'while ($true) {',
  '  $line = [Console]::In.ReadLine()',
  '  if ($null -eq $line) { break }',
  "  $parts = $line.Split('|')",
  '  try { Invoke-Expression ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[0]))) }',
  "  catch { Write-Output ('UVERR:' + $_.Exception.Message) }",
  "  Write-Output ('UVEND:' + $parts[1])",
  '  [Console]::Out.Flush()',
  '}',
].join('\n');

/** The arguments that start the host. */
export function hostArguments(): string[] {
  return [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-EncodedCommand',
    Buffer.from(HOST_BOOTSTRAP, 'utf16le').toString('base64'),
  ];
}

export interface PowerShellHostOptions {
  spawn: () => HostChild;
  /** Runs once after every (re)start: type definitions, COM objects. */
  setupScript: string;
  /** Default per-request limit, from enqueue to the sentinel. */
  requestTimeoutMs?: number;
  /** How long a request's `prepare` may take before the request is refused (unsent). */
  prepareTimeoutMs?: number;
  /** How long the setup script may take on a cold start. */
  startupTimeoutMs?: number;
  /** Unexpected deaths allowed within `restartWindowMs` before the host is given up on. */
  maxRestarts?: number;
  restartWindowMs?: number;
  now?: () => number;
  newId?: () => string;
  log?: (message: string) => void;
}

export interface RunOptions {
  /** The limit on the run itself: its clock starts when the request is written to the host. */
  timeoutMs?: number;
  /**
   * Checked when the request reaches the front of the queue, just before it is written.
   * Aborting while it still waits rejects it at once.
   */
  signal?: AbortSignal;
  /**
   * Called when the request reaches the front of the queue, right before it is written, and
   * returns the script to send, or false to refuse. It may be asynchronous: the queue holds
   * still while it runs, so nothing else is written meanwhile. A refusal rejects the request
   * as `aborted` without writing it: the world changed while it waited. A throw is a refusal.
   */
  prepare?: () => string | false | Promise<string | false>;
}

interface Pending {
  id: string;
  script: string;
  resolve: (output: string) => void;
  reject: (error: PowerShellHostError) => void;
  signal?: AbortSignal;
  prepare?: () => string | false | Promise<string | false>;
  /** Limit on the run, counted from the moment the request is written. */
  timeoutMs: number;
  /** Removes the abort listener a queued request holds. */
  detach: (() => void) | null;
  timer: NodeJS.Timeout | null;
  written: boolean;
  lines: string[];
  /** The startup script: not counted as a caller request. */
  internal: boolean;
}

export class PowerShellHost {
  private readonly requestTimeoutMs: number;
  private readonly startupTimeoutMs: number;
  private readonly prepareTimeoutMs: number;
  private readonly maxRestarts: number;
  private readonly restartWindowMs: number;
  private readonly now: () => number;
  private readonly newId: () => string;

  private state: 'stopped' | 'starting' | 'ready' | 'disabled' | 'disposed' = 'stopped';
  private child: HostChild | null = null;
  /** Bumped on every teardown, so events from a dead process are ignored. */
  private generation = 0;
  private decoder = new StringDecoder('utf8');
  private partialLine = '';
  private current: Pending | null = null;
  private readonly queue: Pending[] = [];
  private starting: Promise<boolean> | null = null;
  /** True from the moment a launch begins, including its synchronous first part. */
  private launching = false;
  /** A request's `prepare` is running: nothing else may be written until it answers. */
  private preparing = false;
  /** Ends the wait for the `prepare` that is running: set while one runs. */
  private releasePrepare: (() => void) | null = null;
  private deaths: number[] = [];

  constructor(private readonly options: PowerShellHostOptions) {
    this.requestTimeoutMs = options.requestTimeoutMs ?? 5000;
    this.startupTimeoutMs = options.startupTimeoutMs ?? 20_000;
    this.prepareTimeoutMs = options.prepareTimeoutMs ?? 1000;
    this.maxRestarts = options.maxRestarts ?? 3;
    this.restartWindowMs = options.restartWindowMs ?? 60_000;
    this.now = options.now ?? (() => Date.now());
    this.newId = options.newId ?? (() => randomUUID());
  }

  get isReady(): boolean {
    return this.state === 'ready';
  }

  /** The host has been given up on (or disposed): callers should use a one-shot process. */
  get isUnavailable(): boolean {
    return this.state === 'disabled' || this.state === 'disposed';
  }

  /** Start the process and run the setup script. Resolves false when it could not. */
  start(): Promise<boolean> {
    if (this.state === 'ready') return Promise.resolve(true);
    if (this.state === 'disabled' || this.state === 'disposed') return Promise.resolve(false);
    if (this.starting) return this.starting;
    this.launching = true;
    this.starting = this.launch()
      .then((ok) => {
        // Callers waiting on a host that did not come up fall back at once, rather than
        // sitting out their time limit. The next call tries the host again.
        if (!ok) {
          this.failAll(new PowerShellHostError('unavailable', 'the PowerShell host did not start', false));
        }
        return ok;
      })
      .finally(() => {
        this.starting = null;
        this.launching = false;
      });
    return this.starting;
  }

  /**
   * Run a script and return what it printed before the sentinel.
   *
   * Rejects with a `PowerShellHostError`; `sent` says whether the script may have run.
   */
  async run(script: string, options: RunOptions = {}): Promise<string> {
    const timeoutMs = options.timeoutMs ?? this.requestTimeoutMs;
    if (this.isUnavailable) {
      throw new PowerShellHostError('unavailable', 'the PowerShell host is not available', false);
    }
    if (options.signal?.aborted) throw new PowerShellHostError('aborted', 'aborted before it was sent', false);

    return new Promise<string>((resolve, reject) => {
      const pending: Pending = {
        id: this.newId(),
        script,
        resolve,
        reject,
        signal: options.signal,
        prepare: options.prepare,
        timeoutMs,
        detach: null,
        timer: null,
        written: false,
        lines: [],
        internal: false,
      };
      // The limit counts the run, not the wait behind other requests: a queue behind a
      // slow one must not time out requests that never got their turn. The caller's
      // signal bounds the wait instead, rejecting a queued request the moment it aborts.
      if (options.signal) {
        const onAbort = (): void => {
          const index = this.queue.indexOf(pending);
          if (index < 0) return;
          this.queue.splice(index, 1);
          this.settle(pending);
          reject(new PowerShellHostError('aborted', 'aborted before it was sent', false));
        };
        options.signal.addEventListener('abort', onAbort, { once: true });
        pending.detach = () => options.signal?.removeEventListener('abort', onAbort);
      }
      this.queue.push(pending);
      if (this.state === 'ready') {
        this.pump();
      } else {
        // Not started yet, or restarting: the queue is flushed once it is ready.
        void this.start();
      }
    });
  }

  /** Stop the process. Pending requests are rejected. */
  dispose(): void {
    if (this.state === 'disposed') return;
    this.state = 'disposed';
    // A request whose prepare is running is rejected too, not left waiting for it.
    this.releasePrepare?.();
    this.teardownProcess();
    this.failAll(new PowerShellHostError('unavailable', 'the PowerShell host was stopped', false));
  }

  // ---- startup -----------------------------------------------------------

  private async launch(): Promise<boolean> {
    this.state = 'starting';
    this.resetStream();
    let child: HostChild;
    try {
      child = this.options.spawn();
    } catch (error) {
      this.options.log?.(`could not start the PowerShell host: ${(error as Error).message}`);
      this.state = 'stopped';
      this.recordDeath();
      return false;
    }
    if (!child.stdin || !child.stdout) {
      try {
        child.kill();
      } catch {
        // Already gone.
      }
      this.options.log?.('the PowerShell host has no stdio');
      this.state = 'stopped';
      this.recordDeath();
      return false;
    }
    this.child = child;
    const generation = ++this.generation;
    child.stdout.on('data', (chunk) => this.onData(generation, chunk));
    child.stderr?.on('data', () => undefined);
    // A write to a dead pipe (EPIPE) is reported here; unhandled it would throw in main.
    child.stdin.on?.('error', (error) => this.onProcessGone(generation, `stdin error: ${error.message}`));
    child.on('error', (error) => this.onProcessGone(generation, `error: ${error.message}`));
    child.on('exit', (code) => this.onProcessGone(generation, `exit ${String(code)}`));

    try {
      await new Promise<string>((resolve, reject) => {
        const setup: Pending = {
          id: this.newId(),
          script: this.options.setupScript,
          resolve,
          reject,
          timeoutMs: this.startupTimeoutMs,
          detach: null,
          timer: null,
          written: false,
          lines: [],
          internal: true,
        };
        this.write(setup);
      });
    } catch (error) {
      // A timeout or an exit has already torn the process down and counted the death.
      // A setup script that threw leaves a live process with no types: end it here.
      if (generation === this.generation) {
        this.current = null;
        this.teardownProcess();
        this.recordDeath();
      }
      this.options.log?.(`the PowerShell host did not start: ${(error as Error).message}`);
      return false;
    }
    if (generation !== this.generation) return false;
    this.state = 'ready';
    this.pump();
    return true;
  }

  // ---- the queue ---------------------------------------------------------

  private pump(): void {
    if (this.state !== 'ready' || this.current || this.preparing) return;
    while (this.queue.length > 0) {
      const next = this.queue.shift() as Pending;
      if (next.signal?.aborted) {
        this.refuse(next);
        continue;
      }
      if (next.prepare) {
        let prepared: string | false | Promise<string | false>;
        try {
          prepared = next.prepare();
        } catch {
          prepared = false;
        }
        if (typeof prepared !== 'string' && prepared !== false) {
          this.preparing = true;
          void this.finishPrepare(next, prepared, this.generation);
          return;
        }
        if (prepared === false) {
          this.refuse(next);
          continue;
        }
        next.script = prepared;
      }
      this.write(next);
      return;
    }
  }

  /**
   * The asynchronous half of `pump`: wait for `prepare`, then write, refuse or wait for a
   * restart. The wait is bounded and can be cut short: a `prepare` that takes longer than
   * `prepareTimeoutMs` refuses the request (unsent) so the queue moves on, an abort of the
   * request releases it at once, and `dispose` rejects it.
   */
  private async finishPrepare(next: Pending, answer: Promise<string | false>, generation: number): Promise<void> {
    let timer: NodeJS.Timeout | null = null;
    let onAbort: (() => void) | null = null;
    const released = new Promise<false>((resolve) => {
      this.releasePrepare = () => resolve(false);
      timer = setTimeout(() => resolve(false), this.prepareTimeoutMs);
      timer.unref?.();
      onAbort = () => resolve(false);
      next.signal?.addEventListener('abort', onAbort, { once: true });
    });
    let prepared: string | false;
    try {
      prepared = await Promise.race([answer, released]);
    } catch {
      prepared = false;
    }
    if (timer) clearTimeout(timer);
    if (onAbort) next.signal?.removeEventListener('abort', onAbort);
    this.releasePrepare = null;
    this.preparing = false;
    if (this.state === 'disabled' || this.state === 'disposed') {
      this.settle(next);
      next.reject(new PowerShellHostError('unavailable', 'the PowerShell host is not available', false));
      return;
    }
    if (next.signal?.aborted || prepared === false) {
      this.refuse(next);
      this.pump();
      return;
    }
    if (generation !== this.generation || this.state !== 'ready' || this.current) {
      // The host died during the check (even if a new process is already up). It keeps its
      // place and is prepared again on the new process: what it learned may be stale. If no
      // process is coming up, start one now, so it does not sit there until its caller
      // gives up; if that fails, the queue is rejected as unavailable and the caller falls
      // back to a one-shot process at once.
      this.queue.unshift(next);
      if (this.state === 'ready') this.pump();
      else void this.start();
      return;
    }
    next.script = prepared;
    this.write(next);
  }

  private refuse(pending: Pending): void {
    this.settle(pending);
    pending.reject(new PowerShellHostError('aborted', 'aborted before it was sent', false));
  }

  private write(pending: Pending): void {
    this.current = pending;
    pending.written = true;
    // The clock starts now: only the time the host spends on this request counts.
    pending.detach?.();
    pending.detach = null;
    pending.timer = setTimeout(() => this.onRequestTimeout(pending), pending.timeoutMs);
    pending.timer.unref?.();
    const line = `${Buffer.from(pending.script, 'utf8').toString('base64')}|${pending.id}\n`;
    try {
      (this.child?.stdin as { write(data: string): unknown }).write(line);
    } catch (error) {
      this.onProcessGone(this.generation, `write failed: ${(error as Error).message}`);
    }
  }

  private onData(generation: number, chunk: Buffer | string): void {
    if (generation !== this.generation) return;
    const text = typeof chunk === 'string' ? chunk : this.decoder.write(chunk);
    this.partialLine += text;
    let newline = this.partialLine.indexOf('\n');
    while (newline >= 0) {
      const line = this.partialLine.slice(0, newline).replace(/\r$/, '');
      this.partialLine = this.partialLine.slice(newline + 1);
      this.onLine(line);
      newline = this.partialLine.indexOf('\n');
    }
  }

  private onLine(line: string): void {
    const pending = this.current;
    if (!pending) return;
    if (line === `UVEND:${pending.id}`) {
      this.current = null;
      this.settle(pending);
      const failure = pending.lines.findIndex((entry) => entry.startsWith('UVERR:'));
      if (failure >= 0) {
        const message = [pending.lines[failure]?.slice('UVERR:'.length) ?? '', ...pending.lines.slice(failure + 1)]
          .join('\n')
          .trim();
        pending.reject(new PowerShellHostError('script', message, true));
      } else {
        pending.resolve(pending.lines.join('\n'));
      }
      this.pump();
      return;
    }
    pending.lines.push(line);
  }

  // ---- failure -----------------------------------------------------------

  private onRequestTimeout(pending: Pending): void {
    pending.timer = null;
    if (this.current !== pending) return;
    // Running: the script may still do its thing, so the process dies with it.
    this.options.log?.('a PowerShell host request timed out; restarting the host');
    this.current = null;
    pending.reject(new PowerShellHostError('timeout', 'the PowerShell host request timed out', pending.written));
    this.teardownProcess();
    this.afterDeath();
  }

  private onProcessGone(generation: number, why: string): void {
    if (generation !== this.generation) return;
    this.options.log?.(`the PowerShell host stopped (${why})`);
    const pending = this.current;
    this.current = null;
    this.teardownProcess();
    if (pending) {
      this.settle(pending);
      pending.reject(new PowerShellHostError('exited', `the PowerShell host stopped (${why})`, pending.written));
    }
    this.afterDeath();
  }

  /** Count a death, then either restart in the background or give up. */
  private afterDeath(): void {
    if (this.state === 'disposed') return;
    this.recordDeath();
    if (this.state === 'disabled') return;
    this.state = 'stopped';
    // A launch in progress reports its own failure; otherwise bring the host back now,
    // so the next call finds it warm.
    if (!this.launching) void this.start();
  }

  private recordDeath(): void {
    const at = this.now();
    this.deaths = this.deaths.filter((time) => at - time < this.restartWindowMs);
    this.deaths.push(at);
    if (this.deaths.length > this.maxRestarts) {
      this.state = 'disabled';
      this.options.log?.('the PowerShell host keeps stopping; using one-shot processes instead');
      this.failAll(new PowerShellHostError('unavailable', 'the PowerShell host keeps stopping', false));
    }
  }

  private teardownProcess(): void {
    this.generation += 1;
    const child = this.child;
    this.child = null;
    if (this.state !== 'disabled' && this.state !== 'disposed') this.state = 'stopped';
    this.resetStream();
    if (child) {
      try {
        child.kill();
      } catch {
        // Already gone.
      }
    }
  }

  private resetStream(): void {
    this.decoder = new StringDecoder('utf8');
    this.partialLine = '';
  }

  private settle(pending: Pending): void {
    pending.detach?.();
    pending.detach = null;
    if (pending.timer) {
      clearTimeout(pending.timer);
      pending.timer = null;
    }
  }

  private failAll(error: PowerShellHostError): void {
    const waiting = this.queue.splice(0);
    const running = this.current;
    this.current = null;
    for (const pending of waiting) {
      this.settle(pending);
      pending.reject(error);
    }
    if (running) {
      this.settle(running);
      running.reject(new PowerShellHostError(error.kind, error.message, running.written));
    }
  }
}
