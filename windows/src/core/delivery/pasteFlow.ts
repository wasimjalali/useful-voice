import { mayRestoreAfterCancel, type ClipboardContents, type RestoreOutcome } from './clipboardRestore.js';
import { DELIVERY_TIMED_OUT } from './timing.js';

/**
 * One delivery, from "the text is ready" to "it is pasted or on the clipboard".
 *
 * Written against ports so the ordering rules can be tested without Electron or Windows.
 * The rules that matter most:
 *
 *  - PROVEN UNSENT versus MAY HAVE GONE OUT. The keystroke request can be dropped at any
 *    time while it is still queued, and it is refused outright when one of our own windows
 *    is in front or the clipboard no longer holds the dictation. Those outcomes are
 *    proven unsent and may be cancelled, copied or reported as an error. Once the request
 *    is written, or a one-shot process has been started, the keystroke may have gone out,
 *    and neither an abort, a timeout nor a script error can prove otherwise. From there
 *    the dictation counts as delivered: never cancelled, never "Press Ctrl+V".
 *  - After that point the previous clipboard is never put back: nothing proves the target
 *    consumed Ctrl+V, and one that stalls would paste the old clipboard instead of the
 *    dictation. The dictation stays on the clipboard.
 *  - Once the dictation has been written, no path writes it again without first checking
 *    that the clipboard still holds it: a newer copy by the person is never overwritten.
 *    If it is gone the delivery ends as "not pasted" and the newer copy stays.
 *  - Permission is just-in-time. Everything that decides whether the key may go (the
 *    clipboard, which window is in front, whether a text field of ours has focus) is asked
 *    again by `authorize` when the request reaches the front of the queue, and the script
 *    asks the clipboard and the foreground process once more right before SendKeys.
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
  /** Nothing was sent because the clipboard no longer held the dictation. */
  clipboardChanged?: boolean;
  /** Nothing was sent because the clipboard could not be read (another app holds it). */
  clipboardUnreadable?: boolean;
}

/**
 * What the keystroke port knows:
 *  - `sent`: the script reported that it sent the key.
 *  - `indeterminate`: the request was written or a process was started, and it ended some
 *    other way (abort, timeout, script error, process exit). The key may have gone out.
 *  - `failed`: it never started (no PowerShell at all). Proven unsent.
 *  - `blocked`: the signal aborted or `authorize` refused while it still waited. Proven unsent.
 *  - `blocked-own` / `blocked-clipboard` / `blocked-unreadable`: the script itself refused
 *    just before SendKeys. Proven unsent.
 */
export type KeystrokeResult =
  | 'sent'
  | 'indeterminate'
  | 'failed'
  | 'blocked'
  | 'blocked-own'
  | 'blocked-clipboard'
  | 'blocked-unreadable';

/**
 * `false` refuses. Otherwise whether the script may skip its own-process guard, and when
 * the text-field check that justifies it was made (`Date.now()`): a permission to paste into
 * our own window goes stale quickly, so the sender drops it if it is older than a moment.
 */
export type Authorization = false | { allowOwnWindow: boolean; checkedAt?: number };

export interface KeystrokeRequest {
  text: string;
  signal?: AbortSignal;
  /**
   * Asked when the request reaches the front of the queue, immediately before it is
   * written. The script is built from the answer, so the own-process guard is lifted only
   * for a check that has just passed.
   */
  authorize: () => Authorization | Promise<Authorization>;
}

export type ClipboardState = 'holds' | 'changed' | 'unreadable';

export interface PasteFlowPorts<S extends ClipboardContents> {
  writeText(text: string): void;
  snapshot(): S;
  restore(snapshot: S, dictationText: string): RestoreOutcome;
  /** Whether the clipboard still holds exactly this text. A read that fails is `unreadable`. */
  clipboardState(text: string): ClipboardState;
  pasteKeystroke(request: KeystrokeRequest): Promise<KeystrokeResult>;
  /** One of our own windows has focus right now. A synchronous read. */
  ownWindowInFront(): boolean;
  /**
   * A text field of ours has focus (not a password box, not read-only), so a paste has
   * somewhere to land. Bounded and false on any failure.
   */
  ownFieldAcceptsPaste(): Promise<boolean>;
  log(category: string, message: string): void;
}

export async function deliverText<S extends ClipboardContents>(
  request: PasteFlowRequest,
  ports: PasteFlowPorts<S>,
): Promise<PasteFlowResult> {
  const { text, mode, signal } = request;
  const startedInOwnWindow = request.startedInOwnWindow === true;
  const aborted = (): boolean => signal?.aborted === true;
  const timedOut = (): boolean => signal?.reason === DELIVERY_TIMED_OUT;
  /** The dictation has been written to the clipboard by this delivery. */
  let written = false;

  const notPasted = (state: 'changed' | 'unreadable'): PasteFlowResult => {
    ports.log('delivery', state === 'changed' ? 'not pasted: the clipboard changed' : 'not pasted: the clipboard is in use');
    return state === 'changed'
      ? { delivered: false, clipboardFallback: false, clipboardChanged: true }
      : { delivered: false, clipboardFallback: false, clipboardUnreadable: true };
  };

  /**
   * Leave the dictation on the clipboard and say it is copied. Before the dictation was
   * written that means writing it. After, it means checking that it is still there: if
   * the clipboard changed, the newer copy stays and nothing is claimed.
   */
  const leaveOnClipboard = (): PasteFlowResult => {
    if (written) {
      const state = ports.clipboardState(text);
      if (state !== 'holds') return notPasted(state);
    } else {
      ports.writeText(text);
      written = true;
    }
    return { delivered: false, clipboardFallback: true };
  };

  /**
   * Stop before the keystroke (proven unsent). A timeout is reported by the service as
   * "copied", so the dictation has to be on the clipboard; a cancel is reported as
   * cancelled, so the person's own clipboard goes back, but only when that is safe: it
   * still holds exactly our text (a newer copy is theirs) and the snapshot is complete
   * and worth restoring.
   */
  const stopBeforePaste = (snapshot: S | null): PasteFlowResult => {
    if (timedOut()) return leaveOnClipboard();
    if (snapshot && mayRestoreAfterCancel(snapshot, ports.clipboardState(text) === 'holds')) {
      ports.restore(snapshot, text);
    }
    return { delivered: false, clipboardFallback: false, cancelled: true };
  };

  if (aborted()) return stopBeforePaste(null);

  if (mode === 'copy') {
    // Nothing is pasted, so there is nothing to confirm and nothing to restore: the
    // dictation simply becomes the clipboard.
    ports.writeText(text);
    return { delivered: true, clipboardFallback: false };
  }

  const copyBecauseOwnWindow = (why: string): PasteFlowResult => {
    // One of our windows is in front and a paste would land nowhere useful (the person
    // stopped from the dock, or no text field has focus).
    ports.log('delivery', `${why}; copied instead of pasting`);
    return leaveOnClipboard();
  };

  // A dictation that began elsewhere is copied as soon as one of our windows is in front.
  if (!startedInOwnWindow && ports.ownWindowInFront()) return copyBecauseOwnWindow('Useful Voice is in front');

  const snapshot = ports.snapshot();
  ports.writeText(text);
  written = true;

  if (aborted()) return stopBeforePaste(snapshot);

  // Why the port was last refused, so a `blocked` answer can be told apart.
  const refusal: { reason: 'own' | 'clipboard' | 'unreadable' | null } = { reason: null };
  const authorize = async (): Promise<Authorization> => {
    // The clipboard first: if the person's newer copy is there, nothing else matters.
    const state = ports.clipboardState(text);
    if (state !== 'holds') {
      refusal.reason = state === 'changed' ? 'clipboard' : 'unreadable';
      return false;
    }
    if (!ports.ownWindowInFront()) return { allowOwnWindow: false };
    // One of our windows is in front. Only a dictation that began in our window may paste
    // there, and only into a text field that has focus right now.
    if (!startedInOwnWindow || !(await ports.ownFieldAcceptsPaste())) {
      refusal.reason = 'own';
      return false;
    }
    // The check took time: the clipboard and the window may have moved again.
    const after = ports.clipboardState(text);
    if (after !== 'holds') {
      refusal.reason = after === 'changed' ? 'clipboard' : 'unreadable';
      return false;
    }
    return { allowOwnWindow: ports.ownWindowInFront(), checkedAt: Date.now() };
  };

  const keystroke = await ports.pasteKeystroke({ text, signal, authorize });

  if (keystroke === 'sent' || keystroke === 'indeterminate') {
    // The key may have gone out, so this is delivered whatever the signal says now: no
    // cancel, no "Press Ctrl+V", no restore. The dictation stays on the clipboard.
    return { delivered: true, clipboardFallback: false };
  }

  // Everything else is proven unsent. A cancel or timeout wins over the reason.
  if (aborted()) return stopBeforePaste(snapshot);
  if (keystroke === 'failed') return leaveOnClipboard();
  if (keystroke === 'blocked-clipboard' || (keystroke === 'blocked' && refusal.reason === 'clipboard')) {
    return notPasted('changed');
  }
  if (keystroke === 'blocked-unreadable' || (keystroke === 'blocked' && refusal.reason === 'unreadable')) {
    return notPasted('unreadable');
  }
  if (refusal.reason === 'own') return copyBecauseOwnWindow('Useful Voice came to the front');
  // Blocked with no reason of ours: the last-moment check did not finish in time (or threw).
  ports.log('delivery', 'the paste check did not finish; copied instead of pasting');
  return leaveOnClipboard();
}
