import {
  decideClipboardRestore,
  isProbablyVerifiable,
  type ClipboardContents,
  type PasteTarget,
  type RestoreOutcome,
} from './clipboardRestore.js';
import { pasteLandsInOwnWindow } from './pasteTarget.js';
import { CLIPBOARD_RESTORE_DELAY_MS, DELIVERY_TIMED_OUT } from './timing.js';

/**
 * One delivery, from "the text is ready" to "it is pasted or on the clipboard".
 *
 * Written against ports so the ordering rules can be tested without Electron or Windows.
 * The rule that matters most: the Ctrl+V keystroke is never sent once the signal has
 * aborted. The signal is checked after every await and again right before the keystroke,
 * so a timeout or a cancel that arrives while the sink is mid-flight cannot be followed
 * by a paste the service has already given up on.
 */

export interface PasteFlowRequest {
  text: string;
  mode: 'paste' | 'copy';
  targetApp?: string;
  /** The dictation started in one of our own windows (a note), where it may paste. */
  startedInOwnWindow?: boolean;
  signal?: AbortSignal;
}

export interface PasteFlowResult {
  delivered: boolean;
  clipboardFallback: boolean;
  cancelled?: boolean;
}

export interface PasteFlowPorts<S extends ClipboardContents> {
  writeText(text: string): void;
  snapshot(): S;
  restore(snapshot: S, dictationText: string): RestoreOutcome;
  holdsText(text: string): boolean;
  /** Which window is in front, null when it could not be read. */
  foregroundWindow(): Promise<PasteTarget | null>;
  /**
   * Send Ctrl+V. Must not send it when `signal` is already aborted, and returns false
   * for a keystroke that did not go out.
   */
  pasteKeystroke(signal?: AbortSignal): Promise<boolean>;
  /** One of our own windows has focus right now. A synchronous read. */
  ownWindowInFront(): boolean;
  delay(ms: number): Promise<void>;
  log(category: string, message: string): void;
}

export async function deliverText<S extends ClipboardContents>(
  request: PasteFlowRequest,
  ports: PasteFlowPorts<S>,
): Promise<PasteFlowResult> {
  const { text, mode, targetApp, signal } = request;
  const aborted = (): boolean => signal?.aborted === true;
  const timedOut = (): boolean => signal?.reason === DELIVERY_TIMED_OUT;

  /**
   * Stop before the keystroke. A timeout is reported by the service as "copied", so the
   * dictation has to be on the clipboard; a cancel is reported as cancelled, so the
   * person's own clipboard goes back.
   */
  const stopBeforePaste = (snapshot: S | null): PasteFlowResult => {
    if (timedOut()) {
      ports.writeText(text);
      return { delivered: false, clipboardFallback: true };
    }
    if (snapshot) ports.restore(snapshot, text);
    return { delivered: false, clipboardFallback: false, cancelled: true };
  };

  if (aborted()) return stopBeforePaste(null);

  if (mode === 'copy') {
    // Nothing is pasted, so there is nothing to confirm and nothing to restore: the
    // dictation simply becomes the clipboard.
    ports.writeText(text);
    return { delivered: true, clipboardFallback: false };
  }

  if (pasteLandsInOwnWindow(request.startedInOwnWindow === true, ports.ownWindowInFront())) {
    // The user stopped from the dock, so Useful Voice is in front: a paste would land
    // nowhere useful. Leave it on the clipboard. Any other window gets the paste.
    ports.log('delivery', 'Useful Voice is in front; copied instead of pasting');
    ports.writeText(text);
    return { delivered: false, clipboardFallback: true };
  }

  const target = await ports.foregroundWindow();
  if (aborted()) return stopBeforePaste(null);

  const snapshot = ports.snapshot();
  ports.writeText(text);

  // The last point at which a cancel or a timeout can still stop the paste. The port
  // checks the signal again at the moment it writes the keystroke.
  if (aborted()) return stopBeforePaste(snapshot);

  const pasteSent = await ports.pasteKeystroke(signal);
  if (!pasteSent && aborted()) return stopBeforePaste(snapshot);

  // The restore needs proof that the paste can be attributed: focus must have stayed on
  // the target, and the clipboard must still hold our text so a newer copy by the person
  // is never overwritten. Ctrl+V does not clear the clipboard, so these reads say nothing
  // about whether the paste landed: they only gate the restore. Both are skipped when
  // they could not allow one — an unverifiable target, or a paste that never ran.
  let focusAfter: PasteTarget | null = null;
  let holdsOurText = false;
  if (pasteSent && isProbablyVerifiable(target)) {
    // The target needs a moment to handle the keystroke; restoring sooner would hand it
    // the previous clipboard instead of the dictation.
    await ports.delay(CLIPBOARD_RESTORE_DELAY_MS);
    // Aborted after the keystroke went out: leave the dictation on the clipboard and
    // skip the restore, so a service that already said "copied" is still right.
    if (aborted()) return { delivered: true, clipboardFallback: false };
    focusAfter = await ports.foregroundWindow();
    if (aborted()) return { delivered: true, clipboardFallback: false };
    holdsOurText = ports.holdsText(text);
  }

  const decision = decideClipboardRestore({
    clipboard: snapshot,
    target,
    pasteSent,
    focusAfter,
    clipboardHoldsOurText: holdsOurText,
  });

  if (decision.restore) {
    const outcome = ports.restore(snapshot, text);
    if (outcome === 'failed-kept-dictation') {
      ports.log('clipboard', 'restore did not verify; dictation put back on the clipboard');
    } else if (outcome === 'failed-lost') {
      ports.log('clipboard', 'restore did not verify and the dictation could not be put back');
    }
  } else if (decision.reason === 'snapshot-incomplete') {
    ports.log('clipboard', 'not restoring: original could not be captured fully');
  } else if (decision.reason === 'clipboard-changed') {
    ports.log('clipboard', 'not restoring: the clipboard changed while pasting');
  } else if (decision.reason === 'unverifiable-target') {
    const name = target?.processName ?? targetApp ?? 'the target app';
    ports.log('delivery', `unverifiable target (${name}); left on clipboard`);
  }

  return { delivered: decision.delivered, clipboardFallback: !decision.delivered };
}
