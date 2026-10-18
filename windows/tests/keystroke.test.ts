import { EventEmitter } from 'node:events';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  clipboardHash,
  OWN_FIELD_FRESH_MS,
  parsePasteOutput,
  pasteScriptBody,
  readTimeouts,
  sendPasteKeystroke,
  type OneShotRunner,
  type SendRequest,
} from '../src/main/keystroke.js';
import { PowerShellHost, PowerShellHostError, type HostChild } from '../src/main/powershellHost.js';

/**
 * Sending Ctrl+V across the process boundary. Failure cases first:
 *  1. the request is written, the abort arrives, and the dictation is reported cancelled
 *     or "Press Ctrl+V" although the keystroke ran
 *  2. a one-shot process is slow to start, the abort kills it, and that is read as
 *     "nothing was sent"
 *  3. the host dies after the request was written and that is read as "nothing was sent"
 *  4. the script throws and that is read as "nothing was sent"
 *  5. the foreground process or the clipboard is checked only in JavaScript, before a wait
 *     that can be long, and not in the script right before SendKeys
 *  6. the dictation text is interpolated into a script
 */

class FakeChild extends EventEmitter implements HostChild {
  readonly stdout = new EventEmitter() as EventEmitter & HostChild['stdout'];
  readonly stderr = new EventEmitter() as EventEmitter & HostChild['stderr'];
  readonly written: Array<{ script: string; id: string }> = [];
  killed = false;
  onRequest: (request: { script: string; id: string }, child: FakeChild) => void = () => undefined;

  readonly stdin = Object.assign(new EventEmitter(), {
    write: (data: string): void => {
      const [encoded, id] = data.trimEnd().split('|') as [string, string];
      const request = { script: Buffer.from(encoded, 'base64').toString('utf8'), id };
      this.written.push(request);
      this.onRequest(request, this);
    },
  });

  reply(id: string, ...lines: string[]): void {
    this.stdout.emit('data', Buffer.from([...lines, `UVEND:${id}`].map((line) => `${line}\r\n`).join('')));
  }

  kill(): void {
    this.killed = true;
  }
}

const SETUP = 'setup';

function makeHost() {
  const children: FakeChild[] = [];
  let counter = 0;
  const host = new PowerShellHost({
    spawn: () => {
      const child = new FakeChild();
      child.onRequest = (request, self) => self.reply(request.id);
      children.push(child);
      return child;
    },
    setupScript: SETUP,
    newId: () => `id${counter++}`,
  });
  return { host, children };
}

const noOneShot: OneShotRunner = async () => {
  throw new Error('a one-shot process must not be used');
};

function request(overrides: Partial<SendRequest> = {}): SendRequest {
  return { text: 'hello world', authorize: () => ({ allowOwnWindow: false }), ownPid: 4242, ...overrides };
}

function deps(host: ReturnType<typeof makeHost>['host'] | null, oneShot: OneShotRunner = noOneShot) {
  return { host, oneShot, oneShotPrelude: 'PRELUDE\n', timeouts: { hostMs: 2500, oneShotMs: 8000 } };
}

beforeEach(() => {
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

describe('the paste script', () => {
  it('carries a hash and a process id, never the dictation', () => {
    const body = pasteScriptBody({ ownPid: 4242, allowOwnWindow: false, clipboardHash: clipboardHash('secret dictation') });
    expect(body).not.toContain('secret dictation');
    expect(body).toContain('$uvOwnPid = 4242');
    expect(body).toContain('$uvAllowOwn = $false');
    expect(body).toContain(clipboardHash('secret dictation'));
  });

  it('checks the foreground process and the clipboard before SendKeys', () => {
    const body = pasteScriptBody({ ownPid: 1, allowOwnWindow: false, clipboardHash: clipboardHash('x') });
    expect(body.indexOf('GetWindowThreadProcessId')).toBeLessThan(body.indexOf('SendKeys'));
    expect(body.indexOf('Get-Clipboard')).toBeLessThan(body.indexOf('SendKeys'));
    expect(body.indexOf('UVBLOCKED:own')).toBeLessThan(body.indexOf('SendKeys'));
    expect(body.indexOf('UVBLOCKED:clipboard')).toBeLessThan(body.indexOf('SendKeys'));
    expect(body.indexOf('UVBLOCKED:unreadable')).toBeLessThan(body.indexOf('SendKeys'));
  });

  it('reads the foreground window after the clipboard and its hash, right before the guards', () => {
    // The slow work (clipboard read, hashing) comes first, so the pid that is checked is the
    // one that will receive the key.
    const body = pasteScriptBody({ ownPid: 1, allowOwnWindow: false, clipboardHash: clipboardHash('x') });
    const hashed = body.indexOf('ComputeHash');
    const foreground = body.indexOf('GetForegroundWindow');
    const guard = body.indexOf('UVBLOCKED:unreadable');
    expect(hashed).toBeGreaterThan(-1);
    expect(foreground).toBeGreaterThan(hashed);
    expect(guard).toBeGreaterThan(foreground);
  });

  it('checks the clipboard before the own-process guard', () => {
    const body = pasteScriptBody({ ownPid: 1, allowOwnWindow: false, clipboardHash: clipboardHash('x') });
    expect(body.indexOf("Write-Output 'UVBLOCKED:clipboard'")).toBeLessThan(body.indexOf("Write-Output 'UVBLOCKED:own'"));
    expect(body.indexOf("Write-Output 'UVBLOCKED:unreadable'")).toBeLessThan(body.indexOf("Write-Output 'UVBLOCKED:clipboard'"));
  });

  it('treats a clipboard that cannot be read as its own case, not as a mismatch', () => {
    const body = pasteScriptBody({ ownPid: 1, allowOwnWindow: false, clipboardHash: clipboardHash('x') });
    expect(body).toContain('$have = $null');
    expect(body).toContain('if ($null -eq $have)');
  });

  it('lets a dictation that started in our window skip the own-process check', () => {
    expect(pasteScriptBody({ ownPid: 1, allowOwnWindow: true, clipboardHash: clipboardHash('x') })).toContain(
      '$uvAllowOwn = $true',
    );
  });

  it('refuses anything that is not a plain integer id and a hex hash', () => {
    const hash = clipboardHash('x');
    expect(() => pasteScriptBody({ ownPid: 0, allowOwnWindow: false, clipboardHash: hash })).toThrow();
    expect(() => pasteScriptBody({ ownPid: 1.5, allowOwnWindow: false, clipboardHash: hash })).toThrow();
    expect(() => pasteScriptBody({ ownPid: NaN, allowOwnWindow: false, clipboardHash: hash })).toThrow();
    expect(() => pasteScriptBody({ ownPid: 1, allowOwnWindow: false, clipboardHash: "x'; calc; '" })).toThrow();
    expect(() => pasteScriptBody({ ownPid: 1, allowOwnWindow: false, clipboardHash: hash.toUpperCase() })).toThrow();
  });
});

describe('clipboardHash', () => {
  it('is the SHA-256 of the UTF-8 text', () => {
    expect(clipboardHash('hello')).toBe('2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
  });

  it('treats CRLF and LF alike, as Windows may add the carriage returns', () => {
    expect(clipboardHash('one\r\ntwo')).toBe(clipboardHash('one\ntwo'));
  });

  it('tells different text apart', () => {
    expect(clipboardHash('hello')).not.toBe(clipboardHash('hello '));
  });
});

describe('parsePasteOutput', () => {
  it('reads the three tokens from the last line', () => {
    expect(parsePasteOutput('UVSENT')).toBe('sent');
    expect(parsePasteOutput('noise\r\nUVBLOCKED:own\r\n')).toBe('blocked-own');
    expect(parsePasteOutput('UVBLOCKED:clipboard')).toBe('blocked-clipboard');
    expect(parsePasteOutput('UVBLOCKED:unreadable')).toBe('blocked-unreadable');
  });

  it('treats anything else as indeterminate', () => {
    expect(parsePasteOutput('')).toBe('indeterminate');
    expect(parsePasteOutput('UVSENT but not last\r\nlater')).toBe('indeterminate');
  });
});

describe('sendPasteKeystroke through the host', () => {
  it('reports what the script says', async () => {
    for (const [token, expected] of [
      ['UVSENT', 'sent'],
      ['UVBLOCKED:own', 'blocked-own'],
      ['UVBLOCKED:clipboard', 'blocked-clipboard'],
      ['UVBLOCKED:unreadable', 'blocked-unreadable'],
    ] as const) {
      const { host, children } = makeHost();
      await host.start();
      (children[0] as FakeChild).onRequest = (req, self) => self.reply(req.id, token);
      expect(await sendPasteKeystroke(deps(host), request())).toBe(expected);
    }
  });

  it('sends the pid and the hash to the host, not the text', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = (req, self) => self.reply(req.id, 'UVSENT');
    await sendPasteKeystroke(deps(host), request({ text: 'top secret words' }));
    const script = child.written[1]?.script ?? '';
    expect(script).toContain('$uvOwnPid = 4242');
    expect(script).not.toContain('top secret words');
  });

  it('stays sent when the abort arrives after the request was written', async () => {
    // The keystroke ran after the abort: the answer is still what the script said, and the
    // host was not killed over it.
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const controller = new AbortController();
    const pending = sendPasteKeystroke(deps(host), request({ signal: controller.signal }));
    await vi.advanceTimersByTimeAsync(0);
    expect(child.written).toHaveLength(2);
    controller.abort();
    child.reply(child.written[1]?.id as string, 'UVSENT');
    expect(await pending).toBe('sent');
    expect(child.killed).toBe(false);
  });

  it('is indeterminate when the request was written and the host then times out', async () => {
    const { host, children } = makeHost();
    await host.start();
    (children[0] as FakeChild).onRequest = () => undefined;
    const pending = sendPasteKeystroke(deps(host), request());
    await vi.advanceTimersByTimeAsync(3000);
    expect(await pending).toBe('indeterminate');
  });

  it('is indeterminate when the host dies after the request was written', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const pending = sendPasteKeystroke(deps(host), request());
    await vi.advanceTimersByTimeAsync(0);
    child.emit('exit', 1);
    expect(await pending).toBe('indeterminate');
  });

  it('is indeterminate when the script throws', async () => {
    const { host, children } = makeHost();
    await host.start();
    (children[0] as FakeChild).onRequest = (req, self) => self.reply(req.id, 'UVERR:SendKeys failed');
    expect(await sendPasteKeystroke(deps(host), request())).toBe('indeterminate');
  });

  it('is blocked, and never written, when the abort arrives while the request waits', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    void host.run('hung', { timeoutMs: 60_000 }).catch(() => undefined);
    const controller = new AbortController();
    const pending = sendPasteKeystroke(deps(host), request({ signal: controller.signal }));
    await vi.advanceTimersByTimeAsync(0);
    controller.abort();
    expect(await pending).toBe('blocked');
    expect(child.written.map((entry) => entry.script)).toEqual([SETUP, 'hung']);
  });

  it('is blocked, and never written, when canSend turns false while the request waits', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const slow = host.run('slow').catch(() => undefined);
    let allowed = true;
    const pending = sendPasteKeystroke(deps(host), request({ authorize: () => (allowed ? { allowOwnWindow: false } : false) }));
    await vi.advanceTimersByTimeAsync(0);
    allowed = false;
    child.reply(child.written[1]?.id as string, 'fine');
    await slow;
    expect(await pending).toBe('blocked');
    expect(child.written).toHaveLength(2);
  });

  it('is blocked without touching the host when already aborted or refused', async () => {
    const { host, children } = makeHost();
    await host.start();
    expect(await sendPasteKeystroke(deps(host), request({ signal: AbortSignal.abort() }))).toBe('blocked');
    expect(await sendPasteKeystroke(deps(host), request({ authorize: () => false }))).toBe('blocked');
    expect(children[0]?.written).toHaveLength(1);
  });

  it('lifts the own-process guard only for an authorisation that just passed, decided at write time', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    let granted = false;
    const slow = host.run('slow').catch(() => undefined);
    const pending = sendPasteKeystroke(
      deps(host),
      request({ authorize: () => ({ allowOwnWindow: granted, checkedAt: Date.now() }) }),
    );
    await vi.advanceTimersByTimeAsync(0);
    // The answer changes while the request waits: the script is built from the later one.
    granted = true;
    child.reply(child.written[1]?.id as string, 'done');
    await slow;
    await vi.advanceTimersByTimeAsync(0);
    expect(child.written[2]?.script).toContain('$uvAllowOwn = $true');
    child.reply(child.written[2]?.id as string, 'UVSENT');
    expect(await pending).toBe('sent');
  });

  it('waits for an asynchronous authorisation before writing, and holds the queue meanwhile', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = (req, self) => self.reply(req.id, 'UVSENT');
    let release: (value: { allowOwnWindow: boolean; checkedAt?: number }) => void = () => undefined;
    const pending = sendPasteKeystroke(
      deps(host),
      request({ authorize: () => new Promise((resolve) => (release = resolve)) }),
    );
    await vi.advanceTimersByTimeAsync(50);
    expect(child.written).toHaveLength(1);
    release({ allowOwnWindow: true, checkedAt: Date.now() });
    expect(await pending).toBe('sent');
    expect(child.written[1]?.script).toContain('$uvAllowOwn = $true');
  });
});

describe('how fresh an own-field check must be', () => {
  async function scriptFor(authorization: { allowOwnWindow: boolean; checkedAt?: number }, waitMs = 0): Promise<string> {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = (req, self) => self.reply(req.id, 'UVSENT');
    await vi.advanceTimersByTimeAsync(waitMs);
    await sendPasteKeystroke(deps(host), request({ authorize: () => authorization }));
    return child.written[1]?.script ?? '';
  }

  it('lifts the guard for a check made just now', async () => {
    expect(await scriptFor({ allowOwnWindow: true, checkedAt: Date.now() })).toContain('$uvAllowOwn = $true');
  });

  it('keeps the guard when the check is older than the limit', async () => {
    const checkedAt = Date.now();
    vi.setSystemTime(checkedAt + OWN_FIELD_FRESH_MS + 1);
    expect(await scriptFor({ allowOwnWindow: true, checkedAt })).toContain('$uvAllowOwn = $false');
  });

  it('keeps the guard when no check time is given at all', async () => {
    expect(await scriptFor({ allowOwnWindow: true })).toContain('$uvAllowOwn = $false');
  });

  it('keeps the guard when the answer was no', async () => {
    expect(await scriptFor({ allowOwnWindow: false, checkedAt: Date.now() })).toContain('$uvAllowOwn = $false');
  });
});

describe('readTimeouts', () => {
  it('gives a read the same limit in the host and in a one-shot process', () => {
    // The long one-shot budget is for the paste keystroke only.
    expect(readTimeouts(2500)).toEqual({ hostMs: 2500, oneShotMs: 2500 });
  });
});

describe('sendPasteKeystroke through a one-shot process', () => {
  const noHost = null;

  it('runs the prelude and the body, and reports the script token', async () => {
    const seen: string[] = [];
    const oneShot: OneShotRunner = async (script) => {
      seen.push(script);
      return 'UVSENT\r\n';
    };
    expect(await sendPasteKeystroke(deps(noHost, oneShot), request())).toBe('sent');
    expect(seen[0]?.startsWith('PRELUDE\n')).toBe(true);
    expect(seen[0]).toContain('SendKeys');
  });

  it('is indeterminate when a slow-starting process is killed by the abort', async () => {
    // The process takes a second to come up; the abort kills it midway. Nothing proves the
    // key was not sent, so this must not read as "blocked".
    const controller = new AbortController();
    const oneShot: OneShotRunner = (_script, _timeout, signal) =>
      new Promise((_resolve, reject) => {
        signal?.addEventListener('abort', () => reject(Object.assign(new Error('The operation was aborted'), { name: 'AbortError' })));
        setTimeout(() => undefined, 1000);
      });
    const pending = sendPasteKeystroke(deps(noHost, oneShot), request({ signal: controller.signal }));
    await vi.advanceTimersByTimeAsync(500);
    controller.abort();
    expect(await pending).toBe('indeterminate');
  });

  it('is indeterminate when the process times out', async () => {
    const oneShot: OneShotRunner = async () => {
      throw Object.assign(new Error('Command failed'), { killed: true, signal: 'SIGTERM' });
    };
    expect(await sendPasteKeystroke(deps(noHost, oneShot), request())).toBe('indeterminate');
  });

  it('is failed, and proven unsent, when no process could be started', async () => {
    const oneShot: OneShotRunner = async () => {
      throw new PowerShellHostError('unavailable', 'powershell.exe was not found', false);
    };
    expect(await sendPasteKeystroke(deps(noHost, oneShot), request())).toBe('failed');
  });

  it('never starts a process when authorisation refuses', async () => {
    const oneShot = vi.fn<OneShotRunner>();
    expect(await sendPasteKeystroke(deps(noHost, oneShot), request({ authorize: () => false }))).toBe('blocked');
    expect(oneShot).not.toHaveBeenCalled();
  });

  it('never starts a process when the signal aborts while authorisation runs', async () => {
    const oneShot = vi.fn<OneShotRunner>();
    const controller = new AbortController();
    let release: (value: { allowOwnWindow: boolean; checkedAt?: number }) => void = () => undefined;
    const pending = sendPasteKeystroke(
      deps(noHost, oneShot),
      request({ signal: controller.signal, authorize: () => new Promise((resolve) => (release = resolve)) }),
    );
    await vi.advanceTimersByTimeAsync(0);
    controller.abort();
    release({ allowOwnWindow: false });
    expect(await pending).toBe('blocked');
    expect(oneShot).not.toHaveBeenCalled();
  });

  it('gives a cold one-shot process its own, longer budget than the warm host', async () => {
    const budgets: number[] = [];
    const oneShot: OneShotRunner = async (_script, timeoutMs) => {
      budgets.push(timeoutMs);
      return 'UVSENT';
    };
    await sendPasteKeystroke(deps(noHost, oneShot), request());
    expect(budgets).toEqual([8000]);
  });

  it('never lifts the own-process guard in a one-shot process, however fresh the check', async () => {
    const seen: string[] = [];
    const oneShot: OneShotRunner = async (script) => {
      seen.push(script);
      return 'UVSENT';
    };
    await sendPasteKeystroke(deps(noHost, oneShot), request({ authorize: () => ({ allowOwnWindow: true, checkedAt: Date.now() }) }));
    // A cold process takes far longer than a check stays fresh: the guard stays on.
    expect(seen[0]).toContain('$uvAllowOwn = $false');
  });

  it('falls back to a one-shot process only for a request the host never wrote', async () => {
    // A host that cannot start: unsent, so the fallback is allowed.
    const broken = new PowerShellHost({
      spawn: () => {
        throw new Error('ENOENT');
      },
      setupScript: SETUP,
    });
    const oneShot = vi.fn<OneShotRunner>(async () => 'UVSENT');
    expect(await sendPasteKeystroke(deps(broken, oneShot), request())).toBe('sent');
    expect(oneShot).toHaveBeenCalledTimes(1);
  });

  it('does not rerun a request the host wrote and lost', async () => {
    const { host, children } = makeHost();
    await host.start();
    const child = children[0] as FakeChild;
    child.onRequest = () => undefined;
    const oneShot = vi.fn<OneShotRunner>(async () => 'UVSENT');
    const pending = sendPasteKeystroke(deps(host, oneShot), request());
    await vi.advanceTimersByTimeAsync(0);
    child.emit('exit', 1);
    expect(await pending).toBe('indeterminate');
    expect(oneShot).not.toHaveBeenCalled();
  });
});
