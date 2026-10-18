import { mayRestoreAfterCancel, type ClipboardContents, type RestoreOutcome } from './clipboardRestore.js';
import { pasteLandsInOwnWindow } from './pasteTarget.js';
import { DELIVERY_TIMED_OUT } from './timing.js';

/**
 * One delivery, from "the text is ready" to "it is pasted or on the clipboard".
 *
 * Written against ports so the ordering rules can be tested without Electron or Windows.
 * The rules that matter most:
 *
 *  - The Ctrl+V keystroke is never sent once the signal has aborted, nor once one of our
 *    own windows has come to the front. Both are checked by the keystroke port itself at
 *    the moment it writes, after any wait in the queue, not only at the start here.
 *  - After a sent keystroke the previous clipboard is never put back: nothing proves the
 *    target consumed Ctrl+V, and one that stalls would paste the old clipboard instead of
 *    the dictation. The dictation stays on the clipboard.
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

/**
 * What the keystroke port did: `sent` (the key went out), `failed` (it could not be sent),
 * `blocked` (the signal aborted or `canSend` said no, so nothing was written).
 */
export type KeystrokeResult = 'sent' | 'failed' | 'blocked';

export interface PasteFlowPorts<S extends ClipboardContents> {
  writeText(text: string): void;
  snapshot(): S;
  restore(snapshot: S, dictationText: string): RestoreOutcome;
  holdsText(text: string): boolean;
  /**
   * Send Ctrl+V. Must check `signal` and `canSend()` at the moment it writes the keystroke
   * (after any queueing) and return `blocked` without sending when either refuses.
   */
  pasteKeystroke(signal: AbortSignal | undefined, canSend: () => boolean): Promise<KeystrokeResult>;
  /** One of our own windows has focus right now. A synchronous read. */
  ownWindowInFront(): boolean;
  log(category: string, message: string): void;
}

export async function deliverText<S extends ClipboardContents>(
  request: PasteFlowRequest,
  ports: PasteFlowPorts<S>,
): Promise<PasteFlowResult> {
  const { text, mode, signal } = request;
  const aborted = (): boolean => signal?.aborted === true;
  const timedOut = (): boolean => signal?.reason === DELIVERY_TIMED_OUT;
  const ownWindowInFront = (): boolean =>
    pasteLandsInOwnWindow(request.startedInOwnWindow === true, ports.ownWindowInFront());

  /**
   * Stop before the keystroke. A timeout is reported by the service as "copied", so the
   * dictation has to be on the clipboard; a cancel is reported as cancelled, so the
   * person's own clipboard goes back, but only when that is safe: it still holds exactly
   * our text (a newer copy is theirs) and the snapshot is complete and worth restoring.
   */
  const stopBeforePaste = (snapshot: S | null): PasteFlowResult => {
    if (timedOut()) {
      ports.writeText(text);
      return { delivered: false, clipboardFallback: true };
    }
    if (snapshot && mayRestoreAfterCancel(snapshot, ports.holdsText(text))) ports.restore(snapshot, text);
    return { delivered: false, clipboardFallback: false, cancelled: true };
  };

  if (aborted()) return stopBeforePaste(null);

  if (mode === 'copy') {
    // Nothing is pasted, so there is nothing to confirm and nothing to restore: the
    // dictation simply becomes the clipboard.
    ports.writeText(text);
    return { delivered: true, clipboardFallback: false };
  }

  const copyBecauseOwnWindow = (): PasteFlowResult => {
    // The user stopped from the dock, so Useful Voice is in front: a paste would land
    // nowhere useful. Leave it on the clipboard. Any other window gets the paste.
    ports.log('delivery', 'Useful Voice is in front; copied instead of pasting');
    ports.writeText(text);
    return { delivered: false, clipboardFallback: true };
  };

  if (ownWindowInFront()) return copyBecauseOwnWindow();

  const snapshot = ports.snapshot();
  ports.writeText(text);

  if (aborted()) return stopBeforePaste(snapshot);

  const keystroke = await ports.pasteKeystroke(signal, () => !ownWindowInFront());
  if (keystroke === 'sent') {
    // Delivered. The dictation stays on the clipboard: see the rules above.
    return { delivered: true, clipboardFallback: false };
  }
  if (aborted()) return stopBeforePaste(snapshot);
  if (keystroke === 'blocked') return copyBecauseOwnWindow();
  return { delivered: false, clipboardFallback: true };
}
