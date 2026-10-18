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
 *  - The port re-checks everything at the moment it writes (and the script re-checks the
 *    foreground process and the clipboard hash just before SendKeys), because the world
 *    changes while a request waits.
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
}

/**
 * What the keystroke port knows:
 *  - `sent`: the script reported that it sent the key.
 *  - `indeterminate`: the request was written or a process was started, and it ended some
 *    other way (abort, timeout, script error, process exit). The key may have gone out.
 *  - `failed`: it never started (no PowerShell at all). Proven unsent.
 *  - `blocked`: the signal aborted or `canSend` refused while it still waited. Proven unsent.
 *  - `blocked-own` / `blocked-clipboard`: the script itself refused just before SendKeys
 *    because our own window was in front, or the clipboard no longer held the dictation.
 *    Proven unsent.
 */
export type KeystrokeResult = 'sent' | 'indeterminate' | 'failed' | 'blocked' | 'blocked-own' | 'blocked-clipboard';

export interface KeystrokeRequest {
  text: string;
  signal?: AbortSignal;
  /** Asked at the moment the request is written; false means nothing may be sent. */
  canSend: () => boolean;
  /** The dictation started in our window, so the script lets it paste into our own process. */
  allowOwnWindow: boolean;
}

export interface PasteFlowPorts<S extends ClipboardContents> {
  writeText(text: string): void;
  snapshot(): S;
  restore(snapshot: S, dictationText: string): RestoreOutcome;
  holdsText(text: string): boolean;
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

  /**
   * Stop before the keystroke (proven unsent). A timeout is reported by the service as
   * "copied", so the dictation has to be on the clipboard; a cancel is reported as
   * cancelled, so the person's own clipboard goes back, but only when that is safe: it
   * still holds exactly our text (a newer copy is theirs) and the snapshot is complete
   * and worth restoring.
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

  const copyBecauseOwnWindow = (why: string): PasteFlowResult => {
    // One of our windows is in front and a paste would land nowhere useful (the person
    // stopped from the dock, or no text field has focus). Leave it on the clipboard.
    ports.log('delivery', `${why}; copied instead of pasting`);
    ports.writeText(text);
    return { delivered: false, clipboardFallback: true };
  };

  // Our own window in front. A dictation started elsewhere is copied. One that started in
  // our window pastes only into a focused text field; a button, the page, a password box
  // or the language picker would swallow the keystroke.
  let ownFieldChecked = false;
  if (ports.ownWindowInFront()) {
    if (!startedInOwnWindow) return copyBecauseOwnWindow('Useful Voice is in front');
    ownFieldChecked = await ports.ownFieldAcceptsPaste();
    if (aborted()) return stopBeforePaste(null);
    if (!ownFieldChecked) return copyBecauseOwnWindow('no text field of Useful Voice has focus');
  }

  const snapshot = ports.snapshot();
  ports.writeText(text);

  if (aborted()) return stopBeforePaste(snapshot);

  // Why the port was last refused, so a `blocked` answer can be told apart.
  const refusal: { reason: 'own' | 'clipboard' | null } = { reason: null };
  const canSend = (): boolean => {
    if (ports.ownWindowInFront() && !(startedInOwnWindow && ownFieldChecked)) {
      refusal.reason = 'own';
      return false;
    }
    if (!ports.holdsText(text)) {
      refusal.reason = 'clipboard';
      return false;
    }
    return true;
  };

  const keystroke = await ports.pasteKeystroke({ text, signal, canSend, allowOwnWindow: startedInOwnWindow });

  if (keystroke === 'sent' || keystroke === 'indeterminate') {
    // The key may have gone out, so this is delivered whatever the signal says now: no
    // cancel, no "Press Ctrl+V", no restore. The dictation stays on the clipboard.
    return { delivered: true, clipboardFallback: false };
  }
  if (keystroke === 'failed') return { delivered: false, clipboardFallback: true };

  // Blocked, so nothing was sent. A cancel or timeout wins over the reason it was blocked.
  if (aborted()) return stopBeforePaste(snapshot);
  if (keystroke === 'blocked-clipboard' || (keystroke === 'blocked' && refusal.reason === 'clipboard')) {
    // The person (or another app) copied something after the dictation was written. Their
    // newer copy is left alone and nothing is claimed: the caller reports an error.
    ports.log('delivery', 'not pasted: the clipboard changed while waiting');
    return { delivered: false, clipboardFallback: false, clipboardChanged: true };
  }
  return copyBecauseOwnWindow('Useful Voice came to the front');
}
