/**
 * One hotkey dictation's delivery, start to finish, as an injectable function: the
 * order of the checks, the choice of method, the last look before the keystroke, the
 * proof and the clipboard restore. Mirrors the Swift core's `InsertionFlow`
 * (`Sources/UsefulVoiceCore/Delivery/InsertionFlow.swift`).
 *
 * The main process supplies the effects (read the foreground, bring a window back,
 * paste, type, the clipboard); this decides. Every rule here serves the contract:
 * the text lands in the window captured at the hotkey press or nowhere, exactly one
 * way in (pasted or typed, never both), and the dictation is on the clipboard
 * whenever it is not proven delivered.
 *
 * Time: the delivery has a deadline. Every await is followed by a look at the signal
 * and the clock, and the platform scripts get the deadline too, so a delivery that ran
 * out of time never sends a keystroke afterwards.
 */
import {
  decideClipboardRestore,
  isProbablyVerifiable,
  type ClipboardContents,
  type PasteTarget,
  type RestoreReason,
} from './clipboardRestore.js';
import {
  checkTarget,
  insertionMethodFor,
  recheckTarget,
  typeOutChunks,
  type DeliveryTarget,
  type InsertionMethod,
  type TargetCheck,
  type TargetLossReason,
} from './deliveryTarget.js';

/** The abort reason the dictation service uses when a delivery runs out of time. */
export const DELIVERY_TIMEOUT = 'delivery-timeout';

/** How one paste or type-out attempt ended, as the platform script reports it. */
export type InsertResult = 'sent' | 'moved' | 'secure' | 'failed' | 'timeout';

export interface InsertAttempt {
  result: InsertResult;
  /**
   * UTF-16 units that went in before it stopped (type-out only). Undefined when the
   * script died without saying, so any number may have gone in.
   */
  typedUnits?: number;
}

/** What the flow needs from the platform. */
export interface DeliveryEffects<Snapshot extends ClipboardContents> {
  /** Milliseconds, on the same clock as the input's `deadline`. */
  now(): number;
  /**
   * What has focus now, null when it can't be read. `withAddress`: also read the
   * browser address, asked only when the target recorded one.
   */
  readFocus(budgetMs: number, withAddress: boolean): Promise<DeliveryTarget | null>;
  /** One attempt to bring the target window (and its focused child) back. */
  reactivate(target: DeliveryTarget, budgetMs: number): Promise<'ok' | 'gone' | 'refused'>;
  snapshotClipboard(): Snapshot;
  writeClipboard(text: string): void;
  restoreClipboard(snapshot: Snapshot): void;
  clipboardHoldsText(text: string): boolean;
  /** Ctrl+V, guarded by the target window still being in front, before `deadline`. */
  paste(target: DeliveryTarget, deadline: number): Promise<InsertAttempt>;
  /** Unicode keystrokes, batch by batch, each guarded the same way. */
  typeOut(target: DeliveryTarget, batches: number[][], deadline: number): Promise<InsertAttempt>;
  wait(ms: number): Promise<void>;
  log(category: string, message: string): void;
}

export interface PasteDeliveryInput {
  text: string;
  /** Captured at the hotkey press. */
  target: DeliveryTarget | undefined;
  typeOutApps: readonly string[];
  restorePreviousClipboard: boolean;
  /** Aborted on cancel, or with `DELIVERY_TIMEOUT` when the service gave up waiting. */
  signal?: AbortSignal;
  /** When the delivery must be over, on the effects' clock. */
  deadline: number;
  /** How long a paste is given to land before the proof is read. */
  settleMs: number;
}

/** Why the text did or did not go in, for tests and the diagnostics log. */
export type DeliveryReason = TargetLossReason | InsertResult | RestoreReason | 'cancelled';

export interface PasteDeliveryResult {
  /** The text provably reached the target. */
  delivered: boolean;
  /** The dictation is on the clipboard as the fallback. */
  clipboardFallback: boolean;
  /** Cancelled before anything was sent. Nothing went in. */
  cancelled?: boolean;
  /** Type-out stopped part way: some of the text went in, all of it is on the clipboard. */
  partlyTyped?: boolean;
  /** The method chosen, once the target lock passed. */
  method?: InsertionMethod;
  reason: DeliveryReason;
}

function toPasteTarget(target: DeliveryTarget): PasteTarget {
  return { processName: target.appId ?? '', handle: target.windowHandle ?? 0 };
}

export async function deliverToTarget<Snapshot extends ClipboardContents>(
  input: PasteDeliveryInput,
  fx: DeliveryEffects<Snapshot>,
): Promise<PasteDeliveryResult> {
  const { text, target, signal } = input;
  const remaining = (): number => Math.max(0, input.deadline - fx.now());
  /** Cancelled, out of time, or free to go on. */
  const stop = (): 'cancelled' | 'timeout' | null => {
    if (signal?.aborted) return signal.reason === DELIVERY_TIMEOUT ? 'timeout' : 'cancelled';
    return remaining() <= 0 ? 'timeout' : null;
  };
  const cancelled: PasteDeliveryResult = { delivered: false, clipboardFallback: false, cancelled: true, reason: 'cancelled' };
  const copyOnly = (reason: DeliveryReason, method?: InsertionMethod): PasteDeliveryResult => {
    fx.writeClipboard(text);
    fx.log('delivery', `target not reachable (${reason}); copied instead of pasting`);
    const result: PasteDeliveryResult = { delivered: false, clipboardFallback: true, reason };
    if (method) result.method = method;
    return result;
  };
  const halted = (): PasteDeliveryResult | null => {
    const why = stop();
    if (why === 'cancelled') return cancelled;
    if (why === 'timeout') return copyOnly('timeout');
    return null;
  };

  let early = halted();
  if (early) return early;

  // The target lock: only the window captured at the hotkey press. If focus moved, it
  // is brought back once; if that fails, the target is gone or shows another page, copy.
  const withAddress = target?.browserUrl !== undefined;
  let focus = await fx.readFocus(remaining(), withAddress);
  if ((early = halted())) return early;
  let lock: TargetCheck = checkTarget(target, focus, true);
  if (lock.kind === 'reactivate') {
    if (!target || target.windowHandle === undefined) {
      lock = { kind: 'copyOnly', reason: 'notRestored' };
    } else {
      const outcome = await fx.reactivate(target, remaining());
      if ((early = halted())) return early;
      if (outcome === 'gone') {
        lock = { kind: 'copyOnly', reason: 'targetGone' };
      } else {
        focus = await fx.readFocus(remaining(), withAddress);
        if ((early = halted())) return early;
        lock = recheckTarget(target, focus, outcome === 'ok');
      }
    }
  }
  if (lock.kind !== 'insert' || !target) {
    return copyOnly(lock.kind === 'copyOnly' ? lock.reason : 'notRestored');
  }

  const method = insertionMethodFor(target.appId, input.typeOutApps, text);
  const snapshot = fx.snapshotClipboard();
  // The dictation goes on the clipboard first in both modes: the safety net.
  fx.writeClipboard(text);

  // The last point at which a cancel can still stop it. After this the keystroke goes
  // out and the dictation is delivered whatever the user does next.
  const last = stop();
  if (last === 'cancelled') {
    fx.restoreClipboard(snapshot);
    return cancelled;
  }
  if (last === 'timeout') return copyOnly('timeout', method);

  // Exactly one way in. Both scripts look at the foreground (and the clock) right before
  // each keystroke and send nothing when the target is no longer in front.
  const attempt =
    method === 'typeOut'
      ? await fx.typeOut(target, typeOutChunks(text), input.deadline)
      : await fx.paste(target, input.deadline);
  if (attempt.result !== 'sent') {
    const result: PasteDeliveryResult = { delivered: false, clipboardFallback: true, reason: attempt.result, method };
    if (method === 'typeOut' && attempt.typedUnits !== 0) result.partlyTyped = true;
    fx.log(
      'delivery',
      attempt.result === 'secure'
        ? 'a password field has focus; left on clipboard'
        : `${method === 'typeOut' ? 'typing' : 'paste'} stopped (${attempt.result}); left on clipboard`,
    );
    return result;
  }

  // The proof. A typed delivery only needs focus to have stayed; a paste into a window
  // whose text can't be checked is never claimed; otherwise the clipboard must have
  // been consumed by the window it was aimed at.
  const aimed = toPasteTarget(target);
  let focusAfter: DeliveryTarget | null = null;
  let stillOurs = false;
  if (method === 'typeOut') {
    focusAfter = await fx.readFocus(remaining(), false);
  } else if (isProbablyVerifiable(aimed)) {
    await fx.wait(input.settleMs);
    focusAfter = await fx.readFocus(remaining(), false);
    stillOurs = fx.clipboardHoldsText(text);
  }
  const decision = decideClipboardRestore({
    clipboard: snapshot,
    target: aimed,
    pasteSent: true,
    focusAfter: focusAfter ? toPasteTarget(focusAfter) : null,
    clipboardStillHoldsText: stillOurs,
    restorePreviousClipboard: input.restorePreviousClipboard,
    method,
  });
  if (decision.restore) {
    fx.restoreClipboard(snapshot);
  } else if (decision.reason === 'snapshot-incomplete') {
    fx.log('clipboard', 'not restoring: original could not be captured fully');
  } else if (decision.reason === 'unverifiable-target') {
    fx.log('delivery', `unverifiable target (${target.appId ?? 'unknown app'}); left on clipboard`);
  }
  return { delivered: decision.delivered, clipboardFallback: !decision.delivered, reason: decision.reason, method };
}
