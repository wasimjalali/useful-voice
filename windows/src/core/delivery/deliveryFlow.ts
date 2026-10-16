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
 * out of time never sends a keystroke afterwards. A paste's script gets an earlier
 * deadline than the delivery: `PROOF_READ_MS` and the settle wait are kept back for
 * the proof, so a slow paste still leaves time to read the foreground afterwards.
 *
 * Once a keystroke went out, the notice is never "Press Ctrl+V": following it would
 * put the text in twice. A sent paste that can't be proven is reported as inserted and
 * the dictation stays on the clipboard, the same as the macOS AX-blind case.
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
  targetMatches,
  typeOutChunks,
  type DeliveryTarget,
  type InsertionMethod,
  type TargetCheck,
  type TargetLossReason,
} from './deliveryTarget.js';
import type { AutoSendKey } from '../apps/appCategory.js';

/** The abort reason the dictation service uses when a delivery runs out of time. */
export const DELIVERY_TIMEOUT = 'delivery-timeout';

/** Kept back from a paste's deadline, with the settle wait, for the foreground read after it. */
export const PROOF_READ_MS = 500;

/**
 * How long a pasted dictation is given to land before the send key goes out. Ctrl+V and
 * the key arrive in the same input queue in order, but an Electron app reads the clipboard
 * on its own time, and Return before the text is in sends an empty message.
 */
export const AUTO_SEND_SETTLE_MS = 300;

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
  /** The auto-send key (Return, Shift+Return or Ctrl+Return), guarded by the target window being in front. */
  sendKey(target: DeliveryTarget, key: AutoSendKey, deadline: number): Promise<InsertAttempt>;
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
  /**
   * The key to press once the text has landed, `off` (the default) for none. It goes out
   * only after a keystroke delivery (pasted or typed to the end) and only while the
   * window and page captured at the press are still in front. Never after a copy-only
   * delivery, partly typed text, a line-break copy or any failure.
   */
  autoSend?: AutoSendKey;
}

/** Why the text did or did not go in, for tests and the diagnostics log. */
export type DeliveryReason = TargetLossReason | InsertResult | RestoreReason | 'cancelled' | 'lineBreaks';

export interface PasteDeliveryResult {
  /**
   * The keystroke went out to the target (pasted, or typed to the end), so the user is
   * told it was inserted. Proven unless `unproven` is set.
   */
  delivered: boolean;
  /**
   * Sent, but the proof could not confirm it (a window whose text can't be checked,
   * focus unreadable or moved, the clipboard untouched). Still reported as inserted,
   * never restored: the dictation stays on the clipboard.
   */
  unproven?: boolean;
  /** The dictation is on the clipboard as the fallback. */
  clipboardFallback: boolean;
  /** Cancelled before anything was sent. Nothing went in. */
  cancelled?: boolean;
  /** Type-out stopped part way: some of the text went in, all of it is on the clipboard. */
  partlyTyped?: boolean;
  /** An app that types, and the text has a line break: copied only, nothing sent. */
  lineBreaks?: boolean;
  /**
   * The paste script itself failed (Windows refused the keystroke, the usual case being
   * a target that runs as administrator). Never set for a lock failure or a copy.
   */
  pasteFailed?: boolean;
  /** The method chosen, once the target lock passed. */
  method?: InsertionMethod;
  /** The auto-send key went out after the text landed. */
  autoSent?: boolean;
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

  // The method, chosen before the lock: text with a line break for an app that types is
  // only copied, so the target is never read or brought back just to copy.
  const method = insertionMethodFor(target?.appId, input.typeOutApps, text);
  if (method === 'copyOnly') {
    fx.writeClipboard(text);
    fx.log('delivery', 'text has a line break and this app types; copied instead');
    return { delivered: false, clipboardFallback: true, lineBreaks: true, method, reason: 'lineBreaks' };
  }

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
      : await fx.paste(target, input.deadline - input.settleMs - PROOF_READ_MS);
  if (attempt.result !== 'sent') {
    const result: PasteDeliveryResult = { delivered: false, clipboardFallback: true, reason: attempt.result, method };
    if (method === 'typeOut' && attempt.typedUnits !== 0) result.partlyTyped = true;
    if (method === 'paste' && attempt.result === 'failed') result.pasteFailed = true;
    fx.log(
      'delivery',
      attempt.result === 'secure'
        ? 'a password field has focus; left on clipboard'
        : `${method === 'typeOut' ? 'typing' : 'paste'} stopped (${attempt.result}); left on clipboard`,
    );
    return result;
  }

  // The proof, which only decides the restore. A typed delivery needs none: its script
  // looked at the foreground before every batch. A paste into a window whose text
  // can't be checked is never claimed as proven; otherwise the clipboard must have been
  // consumed by the window it was aimed at. The read always gets its reserved time.
  const aimed = toPasteTarget(target);
  let focusAfter: DeliveryTarget | null = null;
  let stillOurs = false;
  if (method === 'paste' && isProbablyVerifiable(aimed)) {
    await fx.wait(input.settleMs);
    focusAfter = await fx.readFocus(Math.max(PROOF_READ_MS, remaining()), false);
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
  }
  if (!decision.delivered) {
    // Sent but not proven: "Press Ctrl+V" would paste it a second time.
    fx.log('delivery', `paste sent but not proven (${decision.reason}, ${target.appId ?? 'unknown app'}); left on clipboard`);
    return autoSend({ delivered: true, unproven: true, clipboardFallback: false, reason: decision.reason, method });
  }
  return autoSend({ delivered: true, clipboardFallback: false, reason: decision.reason, method });

  /**
   * The send key, after a delivery whose keystroke went out (the script checked the target
   * was in front when it sent it). It waits for a pasted text to land, then looks at the
   * foreground once more: only the window and page captured at the press get the key. Any
   * doubt (cancelled, out of time, focus moved, the key failing) sends nothing, and the
   * delivery stays as it was: delivered, with the text on the clipboard or in the field.
   */
  async function autoSend(result: PasteDeliveryResult): Promise<PasteDeliveryResult> {
    const key = input.autoSend ?? 'off';
    if (key === 'off' || !target || (method !== 'paste' && method !== 'typeOut')) return result;
    const skip = (why: string): PasteDeliveryResult => {
      fx.log('delivery', `send key not pressed: ${why}`);
      return result;
    };
    if (method === 'paste') await fx.wait(AUTO_SEND_SETTLE_MS);
    if (stop()) return skip('cancelled or out of time');
    const focus = await fx.readFocus(remaining(), withAddress);
    if (stop()) return skip('cancelled or out of time');
    if (!focus || !targetMatches(target, focus)) return skip('the target is no longer in front');
    const attempt = await fx.sendKey(target, key, input.deadline);
    if (attempt.result !== 'sent') return skip(`the key script stopped (${attempt.result})`);
    return { ...result, autoSent: true };
  }
}
