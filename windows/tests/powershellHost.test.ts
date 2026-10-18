import { EventEmitter } from 'node:events';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  HOST_BOOTSTRAP,
  PowerShellHost,
  PowerShellHostError,
  hostArguments,
  type HostChild,
} from '../src/main/powershellHost.js';

/**
 * The long-lived PowerShell host, against a fake child process.
 *
 * Failure cases first (each is a way the delivery path breaks in the field):
 *  1. a request that hangs blocks every later one, and the script may still press
 *     Ctrl+V after its caller gave up
 *  2. the process dies mid-request and every later call hangs
 *  3. the process dies again and again, and each call pays for a doomed restart
 *  4. output of one request is read as the answer to the next (no sentinel match)
 *  5. two requests run at once and a paste overlaps a window read
 *  6. an aborted request is still written to the host
 *  7. output split across chunks, or a multi-byte character split across them, is mangled
 */

class FakeChild extends EventEmitter implements HostChild {
  readonly stdout = new EventEmitter() as EventEmitter & HostChild['stdout'];
  readonly stderr = new EventEmitter() as EventEmitter & HostChild['stderr'];
  readonly written: Array<{ script: string; id: string }> = [];
  killed = false;
  /** Called for each request line; the test decides what the "script" prints. */
  onRequest: (request: { script: string; id: string }, child: FakeChild) => void = () => undefined;

  readonly stdin = Object.assign(new EventEmitter(), {
    write: (data: string): void => {
      const [encoded, id] = data.trimEnd().split('|') as [string, string];
      const request = { script: Buffer.from(encoded, 'base64').toString('utf8'), id: id };
      this.written.push(request);
      this.onRequest(request, this);
    },
  });

  /** Print lines then the sentinel, as the bootstrap does. */
  reply(id: string, ...lines: string[]): void {
    this.stdout.emit('data', Buffer.from([...lines, `UVEND:${id}`].map((line) => `${line}\r\n`).join('')));
  }

  kill(): void {
    this.killed = true;
  }

  die(code = 1): void {
    this.emit('exit', code);
  }
}

const SETUP = 'Add-Type -TypeDefinition "class Setup {}"';

function makeHost(overrides: Partial<ConstructorParameters<typeof PowerShellHost>[0]> = {}) {
  const children: FakeChild[] = [];
  let counter = 0;
  const logs: string[] = [];
  const configure = (child: FakeChild): void => {
    // By default the setup script succeeds at once and every other script echoes itself.
    child.onRequest = (request, self) => {
      if (request.script === SETUP) self.reply(request.id);
      else self.reply(request.id, `ran:${request.script}`);
    };
  };
  const host = new PowerShellHost({
    spawn: () => {
      const child = new FakeChild();
      configure(child);
      children.push(child);
      return child;
    },
    setupScript: SETUP,
    requestTimeoutMs: 1000,
    startupTimeoutMs: 5000,
    newId: () => `id${counter++}`,
    log: (message) => logs.push(message),
    ...overrides,
  });
  return { host, children, logs };
}

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

describe('PowerShellHost', () => {
  it('compiles the setup script once and runs requests without it', async () => {
    const { host, children } = makeHost();
    expect(await host.start()).toBe(true);
    expect(await host.run('one')).toBe('ran:one');
    expect(await host.run('two')).toBe('ran:two');
    expect(children).toHaveLength(1);
    expect(children[0]?.written.map((entry) => entry.script)).toEqual([SETUP, 'one', 'two']);
  });

  it('starts the host on the first call when nobody started it', async () => {
    const { host, children } = makeHost();
    expect(await host.run('first')).toBe('ran:first');
    expect(children).toHaveLength(1);
  });

  it('uses an encoded command, so no quoting layer touches the bootstrap', () => {
    const args = hostArguments();
    const encoded = args[args.indexOf('-EncodedCommand') + 1] as string;
    expect(Buffer.from(encoded, 'base64').toString('utf16le')).toBe(HOST_BOOTSTRAP);
    expect(HOST_BOOTSTRAP).not.toContain('"');
  });

  it('runs one request at a time, in order', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined; // hold every reply
    const first = host.run('first');
    const second = host.run('second');
    await vi.advanceTimersByTimeAsync(10);
    // The paste must never overlap the window read: only the first is written.
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP, 'first']);
    child.reply(child.written[1]?.id as string, 'answer one');
    expect(await first).toBe('answer one');
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP, 'first', 'second']);
    child.reply(child.written[2]?.id as string, 'answer two');
    expect(await second).toBe('answer two');
  });

  it('ignores output that does not carry the current sentinel', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const pending = host.run('first');
    await vi.advanceTimersByTimeAsync(0);
    child.stdout.emit('data', Buffer.from('UVEND:somebody-elses-id\r\nreal answer\r\n'));
    child.reply(child.written[1]?.id as string);
    // The foreign sentinel is just a line of output; the answer is everything before ours.
    expect(await pending).toBe('UVEND:somebody-elses-id\nreal answer');
  });

  it('reassembles output split across chunks and a character split across bytes', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const pending = host.run('first');
    await vi.advanceTimersByTimeAsync(0);
    const id = child.written[1]?.id as string;
    const bytes = Buffer.from(`café\r\nUVEND:${id}\r\n`, 'utf8');
    // Cut in the middle of the two-byte e-acute.
    child.stdout.emit('data', bytes.subarray(0, 5));
    child.stdout.emit('data', bytes.subarray(5));
    expect(await pending).toBe('café');
  });

  it('rejects a script error as a script failure that was sent', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = (request, self) => self.reply(request.id, 'UVERR:boom', 'at line 2');
    const error = await host.run('bad').catch((e: unknown) => e);
    expect(error).toBeInstanceOf(PowerShellHostError);
    expect(error).toMatchObject({ kind: 'script', sent: true, message: 'boom\nat line 2' });
    // The host is still usable afterwards.
    child.onRequest = (request, self) => self.reply(request.id, 'fine');
    expect(await host.run('good')).toBe('fine');
  });

  it('kills a request that outlives its limit and restarts, so a late keystroke cannot happen', async () => {
    const { host, children } = makeHost();
    await host.start();
    const first = children[0] as FakeChild;
    first.onRequest = () => undefined; // hangs
    const hung = host.run('paste', { timeoutMs: 500 }).catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(600);
    const error = (await hung) as PowerShellHostError;
    expect(error.kind).toBe('timeout');
    expect(error.sent).toBe(true);
    expect(first.killed).toBe(true);
    // A new process is up and answers; output from the dead one is ignored.
    await vi.advanceTimersByTimeAsync(10);
    expect(children).toHaveLength(2);
    first.reply(first.written[1]?.id as string, 'stale');
    expect(await host.run('next')).toBe('ran:next');
  });

  it('starts a request\'s clock when it is written, not when it is queued', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const slow = host.run('slow', { timeoutMs: 5000 });
    // Waits 800 ms behind the slow one with a 500 ms limit: only its own run counts.
    const queued = host.run('queued', { timeoutMs: 500 });
    await vi.advanceTimersByTimeAsync(800);
    child.reply(child.written[1]?.id as string, 'done');
    await slow;
    await vi.advanceTimersByTimeAsync(0);
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP, 'slow', 'queued']);
    child.reply(child.written[2]?.id as string, 'queued answer');
    expect(await queued).toBe('queued answer');
    expect(child.killed).toBe(false);
  });

  it('still kills the host when a written request outlives its own limit', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const slow = host.run('slow', { timeoutMs: 5000 });
    const queued = host.run('queued', { timeoutMs: 300 }).catch((e: unknown) => e);
    child.reply(child.written[1]?.id as string, 'done');
    await slow;
    await vi.advanceTimersByTimeAsync(400);
    expect(((await queued) as PowerShellHostError).kind).toBe('timeout');
    expect(child.killed).toBe(true);
  });

  it('rejects an aborted request at once, without waiting behind a hung one', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const controller = new AbortController();
    void host.run('hung', { timeoutMs: 60_000 }).catch(() => undefined);
    const paste = host.run('paste', { signal: controller.signal }).catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(0);
    controller.abort();
    expect(await paste).toMatchObject({ kind: 'aborted', sent: false });
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP, 'hung']);
  });

  it('does not write a request whose prepare step refuses', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    let allowed = true;
    const slow = host.run('slow');
    const paste = host.run('paste', { prepare: () => (allowed ? 'paste' : false) }).catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(0);
    allowed = false;
    child.reply(child.written[1]?.id as string, 'done');
    await slow;
    expect(await paste).toMatchObject({ kind: 'aborted', sent: false });
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP, 'slow']);
  });

  it('writes the script that prepare returns, not the one it was given', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    const answer = await host.run('original', { prepare: () => 'prepared' });
    expect(answer).toBe('ran:prepared');
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP, 'prepared']);
  });

  it('holds the queue still while an asynchronous prepare runs', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    let release: (script: string | false) => void = () => undefined;
    const first = host.run('first', {
      prepare: () => new Promise<string | false>((resolve) => (release = resolve)),
    });
    const second = host.run('second');
    await vi.advanceTimersByTimeAsync(50);
    // Nothing is written while the first request is still being checked.
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP]);
    release('first, checked');
    expect(await first).toBe('ran:first, checked');
    expect(await second).toBe('ran:second');
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP, 'first, checked', 'second']);
  });

  it('refuses after an asynchronous prepare says no, and carries on with the queue', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    const first = host.run('first', { prepare: async () => false as const }).catch((e: unknown) => e);
    const second = host.run('second');
    expect(await first).toMatchObject({ kind: 'aborted', sent: false });
    expect(await second).toBe('ran:second');
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP, 'second']);
  });

  it('treats a prepare that throws as a refusal', async () => {
    const { host, children } = makeHost();
    await host.start();
    const sync = await host
      .run('a', {
        prepare: () => {
          throw new Error('boom');
        },
      })
      .catch((e: unknown) => e);
    const later = await host.run('b', { prepare: () => Promise.reject(new Error('boom')) }).catch((e: unknown) => e);
    expect(sync).toMatchObject({ kind: 'aborted', sent: false });
    expect(later).toMatchObject({ kind: 'aborted', sent: false });
    expect(children[0]?.written).toHaveLength(1);
  });

  it('does not write a request that was aborted while its prepare ran', async () => {
    const { host, children } = makeHost();
    await host.start();
    const controller = new AbortController();
    let release: (script: string | false) => void = () => undefined;
    const pending = host
      .run('paste', {
        signal: controller.signal,
        prepare: () => new Promise<string | false>((resolve) => (release = resolve)),
      })
      .catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(0);
    controller.abort();
    release('paste');
    expect(await pending).toMatchObject({ kind: 'aborted', sent: false });
    expect(children[0]?.written).toHaveLength(1);
  });

  it('prepares a request again on the new process when the host died during its prepare', async () => {
    const { host, children } = makeHost();
    await host.start();
    let prepares = 0;
    let release: (script: string | false) => void = () => undefined;
    const pending = host.run('paste', {
      prepare: () => {
        prepares += 1;
        if (prepares === 1) return new Promise<string | false>((resolve) => (release = resolve));
        return 'paste again';
      },
    });
    await vi.advanceTimersByTimeAsync(0);
    (children[0] as FakeChild).emit('exit', 1);
    await vi.advanceTimersByTimeAsync(10);
    release('stale');
    expect(await pending).toBe('ran:paste again');
    expect(prepares).toBe(2);
    expect(children).toHaveLength(2);
    expect(children[1]?.written.map((entry) => entry.script)).toEqual([SETUP, 'paste again']);
  });

  it('treats a broken stdin pipe as a death: fails the request and restarts', async () => {
    const { host, children } = makeHost();
    await host.start();
    const first = children[0] as FakeChild;
    first.onRequest = () => undefined;
    const running = host.run('running').catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(0);
    // EPIPE arrives as an event on stdin; unhandled it would throw in the main process.
    first.stdin.emit('error', new Error('write EPIPE'));
    expect(await running).toMatchObject({ kind: 'exited', sent: true });
    expect(first.killed).toBe(true);
    await vi.advanceTimersByTimeAsync(10);
    expect(children).toHaveLength(2);
    expect(await host.run('next')).toBe('ran:next');
  });

  it('ignores a stdin error from a process that was already replaced', async () => {
    const { host, children } = makeHost();
    await host.start();
    const first = children[0] as FakeChild;
    first.onRequest = () => undefined;
    const hung = host.run('paste', { timeoutMs: 100 }).catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(200);
    await hung;
    await vi.advanceTimersByTimeAsync(10);
    expect(children).toHaveLength(2);
    first.stdin.emit('error', new Error('write EPIPE'));
    await vi.advanceTimersByTimeAsync(10);
    // The new process is untouched.
    expect(children).toHaveLength(2);
    expect(children[1]?.killed).toBe(false);
    expect(await host.run('next')).toBe('ran:next');
  });

  it('never writes a request whose signal aborted while it waited', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const controller = new AbortController();
    const slow = host.run('slow');
    const paste = host.run('paste', { signal: controller.signal }).catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(0);
    controller.abort();
    child.reply(child.written[1]?.id as string, 'done');
    await slow;
    const error = (await paste) as PowerShellHostError;
    expect(error).toMatchObject({ kind: 'aborted', sent: false });
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP, 'slow']);
  });

  it('refuses a request whose signal is already aborted', async () => {
    const { host, children } = makeHost();
    await host.start();
    const error = await host.run('paste', { signal: AbortSignal.abort() }).catch((e: unknown) => e);
    expect(error).toMatchObject({ kind: 'aborted', sent: false });
    expect(children[0]?.written).toHaveLength(1);
  });

  it('rejects the running request when the process dies, then restarts and serves the queue', async () => {
    const { host, children } = makeHost();
    await host.start();
    const first = children[0] as FakeChild;
    first.onRequest = () => undefined;
    const running = host.run('running').catch((e: unknown) => e);
    const waiting = host.run('waiting');
    await vi.advanceTimersByTimeAsync(0);
    first.die();
    const error = (await running) as PowerShellHostError;
    expect(error).toMatchObject({ kind: 'exited', sent: true });
    // The queued request had not been sent, so it runs on the new process.
    expect(await waiting).toBe('ran:waiting');
    expect(children).toHaveLength(2);
    expect(children[1]?.written.map((entry) => entry.script)).toEqual([SETUP, 'waiting']);
  });

  it('is unavailable when the process cannot be spawned, with nothing sent', async () => {
    const { host, logs } = makeHost({
      spawn: () => {
        throw new Error('ENOENT');
      },
    });
    const error = await host.run('anything').catch((e: unknown) => e);
    expect(error).toMatchObject({ kind: 'unavailable', sent: false });
    expect(logs.join('\n')).toContain('ENOENT');
  });

  it('is unavailable when the setup script fails, and kills that process', async () => {
    const children: FakeChild[] = [];
    const { host } = makeHost({
      spawn: () => {
        const child = new FakeChild();
        child.onRequest = (request, self) => self.reply(request.id, 'UVERR:Add-Type failed');
        children.push(child);
        return child;
      },
    });
    const error = await host.run('anything').catch((e: unknown) => e);
    expect(error).toMatchObject({ kind: 'unavailable', sent: false });
    expect(children[0]?.killed).toBe(true);
  });

  it('gives up after repeated deaths and stops restarting', async () => {
    const children: FakeChild[] = [];
    const { host } = makeHost({
      maxRestarts: 2,
      spawn: () => {
        const child = new FakeChild();
        // Dies as soon as it is asked to do anything.
        child.onRequest = (_request, self) => queueMicrotask(() => self.die());
        children.push(child);
        return child;
      },
    });
    expect(await host.start()).toBe(false);
    expect(await host.start()).toBe(false);
    expect(await host.start()).toBe(false);
    expect(host.isUnavailable).toBe(true);
    const spawned = children.length;
    const error = await host.run('anything').catch((e: unknown) => e);
    expect(error).toMatchObject({ kind: 'unavailable', sent: false });
    expect(children).toHaveLength(spawned);
  });

  it('rejects everything pending when it is disposed', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const running = host.run('running').catch((e: unknown) => e);
    const waiting = host.run('waiting').catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(0);
    host.dispose();
    expect((await running) as PowerShellHostError).toMatchObject({ kind: 'unavailable', sent: true });
    expect((await waiting) as PowerShellHostError).toMatchObject({ kind: 'unavailable', sent: false });
    expect(child.killed).toBe(true);
    expect(await host.start()).toBe(false);
  });
});
