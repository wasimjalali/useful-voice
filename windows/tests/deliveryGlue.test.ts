import { describe, expect, it } from 'vitest';
import { DELIVERY_TIMEOUT } from '../src/core/delivery/deliveryFlow.js';
import type { DeliveryTarget } from '../src/core/delivery/deliveryTarget.js';
import type { ForegroundWindowInfo } from '../src/core/delivery/foregroundLine.js';
import {
  DELIVERY_ADDRESS_MS,
  PendingAddress,
  focusReader,
  forgetPageDetails,
  killOnTimeout,
  type AddressRead,
} from '../src/main/deliveryGlue.js';

/**
 * The main process's delivery glue, piece by piece.
 *
 * Ways it could fail, each pinned below: a cancel killing a paste that already started
 * (only a timeout may); reading another window's address and comparing it with the
 * target's page; a delivery waiting the full capture-time budget for the address bar;
 * waiting again after a reactivation for a read that already timed out; a page address
 * or title outliving its dictation; a capture-time read that finishes late landing on
 * a dictation that is over, or on the next one's target.
 */

const edgeFront: ForegroundWindowInfo = { handle: 0x500, title: 'Mail - Edge', processName: 'msedge.exe', processId: 50 };
const otherEdge: ForegroundWindowInfo = { handle: 0x600, title: 'News - Edge', processName: 'msedge.exe', processId: 50 };
const target: DeliveryTarget = { appId: 'msedge', processId: 50, windowHandle: 0x500, browserUrl: 'https://mail.example.com/' };

function readers(fronts: Array<ForegroundWindowInfo | null>, reads: AddressRead[]) {
  const addressCalls: Array<{ handle: number; budgetMs: number }> = [];
  const logs: string[] = [];
  let front = 0;
  let read = 0;
  return {
    addressCalls,
    logs,
    fx: {
      foregroundWindow: async () => fronts[Math.min(front++, fronts.length - 1)] ?? null,
      browserAddress: async (handle: number, _appId: string | undefined, budgetMs: number) => {
        addressCalls.push({ handle, budgetMs });
        return reads[Math.min(read++, reads.length - 1)]!;
      },
      log: (_category: string, message: string) => logs.push(message),
    },
  };
}

describe('killOnTimeout', () => {
  it('fires when the service gave up, never on a cancel', () => {
    const timedOut = new AbortController();
    const kill = killOnTimeout(timedOut.signal)!;
    timedOut.abort(DELIVERY_TIMEOUT);
    expect(kill.aborted).toBe(true);

    const cancelled = new AbortController();
    const spared = killOnTimeout(cancelled.signal)!;
    cancelled.abort();
    expect(spared.aborted).toBe(false);
  });

  it('is already fired for a delivery that had timed out, and absent without a signal', () => {
    const controller = new AbortController();
    controller.abort(DELIVERY_TIMEOUT);
    expect(killOnTimeout(controller.signal)!.aborted).toBe(true);
    expect(killOnTimeout(undefined)).toBeUndefined();
  });
});

describe('focusReader', () => {
  it("reads the address only from the target's own window", async () => {
    const r = readers([otherEdge], [{ address: 'https://news.example.com/', timedOut: false }]);
    const focus = await focusReader(target, r.fx)(5000, true);
    expect(focus).toMatchObject({ windowHandle: 0x600, appId: 'msedge' });
    expect(focus?.browserUrl).toBeUndefined();
    expect(r.addressCalls).toEqual([]);
  });

  it('reads it from the target window, for no longer than a delivery waits', async () => {
    const r = readers([edgeFront], [{ address: 'https://mail.example.com/', timedOut: false }]);
    const focus = await focusReader(target, r.fx)(5000, true);
    expect(focus?.browserUrl).toBe('https://mail.example.com/');
    expect(r.addressCalls).toEqual([{ handle: 0x500, budgetMs: DELIVERY_ADDRESS_MS }]);
    expect(DELIVERY_ADDRESS_MS).toBeLessThanOrEqual(800);
  });

  it('gives the read less than the cap when less is left', async () => {
    const r = readers([edgeFront], [{ address: null, timedOut: false }]);
    await focusReader(target, r.fx)(300, true);
    expect(r.addressCalls[0]!.budgetMs).toBe(300);
  });

  it('reads no address when not asked, or when nothing is in front', async () => {
    const r = readers([edgeFront, null], [{ address: 'https://mail.example.com/', timedOut: false }]);
    const read = focusReader(target, r.fx);
    expect((await read(5000, false))?.browserUrl).toBeUndefined();
    expect(await read(5000, true)).toBeNull();
    expect(r.addressCalls).toEqual([]);
  });

  it('skips the second read after a reactivation when the first timed out, and says so once', async () => {
    const r = readers([edgeFront], [{ address: null, timedOut: true }, { address: 'https://mail.example.com/', timedOut: false }]);
    const read = focusReader(target, r.fx);
    expect((await read(5000, true))?.browserUrl).toBeUndefined();
    const second = await read(5000, true);
    expect(second).toMatchObject({ windowHandle: 0x500 });
    expect(second?.browserUrl).toBeUndefined();
    expect(r.addressCalls).toHaveLength(1);
    expect(r.logs).toEqual(['address bar read timed out; the page is not compared']);
  });

  it('reads again after a read that only found nothing', async () => {
    const r = readers([edgeFront], [{ address: null, timedOut: false }, { address: 'https://mail.example.com/', timedOut: false }]);
    const read = focusReader(target, r.fx);
    await read(5000, true);
    expect((await read(5000, true))?.browserUrl).toBe('https://mail.example.com/');
    expect(r.addressCalls).toHaveLength(2);
  });

  it('a new delivery reads the address again after an earlier one timed out', async () => {
    const r = readers([edgeFront], [{ address: null, timedOut: true }, { address: 'https://mail.example.com/', timedOut: false }]);
    await focusReader(target, r.fx)(5000, true);
    expect((await focusReader(target, r.fx)(5000, true))?.browserUrl).toBe('https://mail.example.com/');
  });
});

describe('forgetPageDetails', () => {
  it('drops the page address and the title, and keeps what identifies the target', () => {
    const held: DeliveryTarget = { ...target, windowTitle: 'Mail - Edge', focusHandle: 0x501 };
    forgetPageDetails(held);
    expect(held).toEqual({ appId: 'msedge', processId: 50, windowHandle: 0x500, focusHandle: 0x501 });
    expect(() => forgetPageDetails(undefined)).not.toThrow();
  });
});

describe('PendingAddress', () => {
  function deferred() {
    let resolve!: (value: string | null) => void;
    const promise = new Promise<string | null>((done) => (resolve = done));
    return { promise, resolve };
  }

  it('lands the capture-time address while the dictation is still going', async () => {
    const pending = new PendingAddress();
    const held: DeliveryTarget = { appId: 'msedge', windowHandle: 0x500 };
    const read = deferred();
    const done = pending.start(held, () => read.promise);
    read.resolve('https://mail.example.com/');
    await done;
    expect(held.browserUrl).toBe('https://mail.example.com/');
  });

  it('drops a read that finishes after the dictation settled', async () => {
    const pending = new PendingAddress();
    const held: DeliveryTarget = { appId: 'msedge', windowHandle: 0x500 };
    const read = deferred();
    const done = pending.start(held, () => read.promise);
    pending.settle(held);
    read.resolve('https://mail.example.com/');
    await done;
    expect(held.browserUrl).toBeUndefined();
  });

  it("drops a read that finishes after the next press, and a settle of another target doesn't clear it", async () => {
    const pending = new PendingAddress();
    const first: DeliveryTarget = { appId: 'msedge', windowHandle: 0x500 };
    const second: DeliveryTarget = { appId: 'msedge', windowHandle: 0x600 };
    const slow = deferred();
    const fast = deferred();
    const firstDone = pending.start(first, () => slow.promise);
    const secondDone = pending.start(second, () => fast.promise);
    pending.settle(first);
    fast.resolve('https://news.example.com/');
    slow.resolve('https://mail.example.com/');
    await Promise.all([firstDone, secondDone]);
    expect(first.browserUrl).toBeUndefined();
    expect(second.browserUrl).toBe('https://news.example.com/');
  });
});
