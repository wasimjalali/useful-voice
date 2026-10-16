/**
 * The small pieces of glue between the main process and `deliverToTarget`, kept free of
 * Electron so each rule is tested on its own (`tests/deliveryGlue.test.ts`): which
 * signal kills a running keystroke script, when the browser address is read during a
 * delivery and for how long, and how the capture-time address read and the page
 * details are dropped once a dictation is over.
 */
import { DELIVERY_TIMEOUT } from '../core/delivery/deliveryFlow.js';
import { appIdFor, type DeliveryTarget } from '../core/delivery/deliveryTarget.js';
import type { ForegroundWindowInfo } from '../core/delivery/foregroundLine.js';

/** The longest a delivery waits for the address bar. The capture-time read gets longer. */
export const DELIVERY_ADDRESS_MS = 800;

/** One address bar read: the address, or null, and whether it ran out of time. */
export interface AddressRead {
  address: string | null;
  timedOut: boolean;
}

/** The target lock's view of a foreground window. */
export function toDeliveryTarget(front: ForegroundWindowInfo): DeliveryTarget {
  const target: DeliveryTarget = { windowHandle: front.handle, windowTitle: front.title };
  const appId = appIdFor(front.processName);
  if (appId) target.appId = appId;
  const name = front.title || front.processName;
  if (name) target.appName = name;
  if (front.processId !== undefined) target.processId = front.processId;
  if (front.focusHandle !== undefined) target.focusHandle = front.focusHandle;
  return target;
}

/**
 * A signal that fires only when the delivery ran out of time, never on a cancel. It
 * kills a running keystroke script outright; a cancel lets a paste that already
 * started finish, as it always has.
 */
export function killOnTimeout(signal: AbortSignal | undefined): AbortSignal | undefined {
  if (!signal) return undefined;
  const kill = new AbortController();
  const onAbort = (): void => {
    if (signal.reason === DELIVERY_TIMEOUT) kill.abort();
  };
  if (signal.aborted) onAbort();
  else signal.addEventListener('abort', onAbort, { once: true });
  return kill.signal;
}

export interface FocusReaders {
  foregroundWindow(budgetMs: number): Promise<ForegroundWindowInfo | null>;
  browserAddress(handle: number, appId: string | undefined, budgetMs: number): Promise<AddressRead>;
  log(category: string, message: string): void;
}

/**
 * `readFocus` for one delivery. The address is read only from the target's own window
 * (another window's page says nothing about the target's), for at most
 * `DELIVERY_ADDRESS_MS`, and not again once a read ran out of time: the second look
 * after a reactivation would only wait as long for nothing. Without an address the page
 * is not compared, which the log says.
 */
export function focusReader(
  target: DeliveryTarget | undefined,
  readers: FocusReaders,
): (budgetMs: number, withAddress: boolean) => Promise<DeliveryTarget | null> {
  let addressTimedOut = false;
  return async (budgetMs, withAddress) => {
    const front = await readers.foregroundWindow(budgetMs);
    if (!front) return null;
    const focus = toDeliveryTarget(front);
    if (withAddress && !addressTimedOut && target?.windowHandle === front.handle) {
      const read = await readers.browserAddress(front.handle, focus.appId, Math.min(DELIVERY_ADDRESS_MS, budgetMs));
      if (read.address) focus.browserUrl = read.address;
      if (read.timedOut) {
        addressTimedOut = true;
        readers.log('delivery', 'address bar read timed out; the page is not compared');
      }
    }
    return focus;
  };
}

/** The window title and the page address were for one dictation only. */
export function forgetPageDetails(target: DeliveryTarget | undefined): void {
  if (!target) return;
  delete target.browserUrl;
  delete target.windowTitle;
}

/**
 * The capture-time address read, started at the hotkey press off the critical path.
 * Its result lands on the target only while that target is still the pending one: a
 * read that finishes after the dictation settled (or after the next press) is dropped.
 */
export class PendingAddress {
  private pending: DeliveryTarget | null = null;

  start(target: DeliveryTarget, read: () => Promise<string | null>): Promise<void> {
    this.pending = target;
    return read().then((address) => {
      if (address && this.pending === target) target.browserUrl = address;
    });
  }

  /** The dictation for `target` is over: a late read must not land on it. */
  settle(target: DeliveryTarget | undefined): void {
    if (this.pending === target) this.pending = null;
  }
}
