/**
 * How long each step of a delivery may take, and how long the whole of it may.
 *
 * The service's delivery timeout used to be 5 s while the sink spawned PowerShell three
 * times (each compiling C#), so the timeout could win while the sink was still going and
 * later send Ctrl+V: a double paste, or a paste of the wrong clipboard. The sink's own
 * step budgets live here beside the overall limit, so the limit is derived from them and
 * cannot silently fall below the worst case again.
 */

/** Reading which window is in front (the HUD label and the language picker; not delivery). */
export const FOREGROUND_QUERY_TIMEOUT_MS = 2500;

/** Sending the Ctrl+V keystroke, per attempt. */
export const PASTE_KEYSTROKE_TIMEOUT_MS = 2500;

/** Snapshotting and writing the clipboard: synchronous, but not free. */
const CLIPBOARD_WORK_MS = 500;

/**
 * The slowest a delivery can run when every step uses its whole budget. The keystroke is
 * the only awaited step. A host attempt can time out without ever being written (it
 * waited behind a hung request), and the same step then reruns in a one-shot process, so
 * the keystroke budget counts twice.
 */
export const WORST_CASE_DELIVERY_MS = 2 * PASTE_KEYSTROKE_TIMEOUT_MS + CLIPBOARD_WORK_MS;

/**
 * The service gives up on a delivery after this long. Well above the worst case, so the
 * timeout is a safety net for a lost callback and never races a working sink.
 */
export const DELIVERY_TIMEOUT_MS = 15_000;

/**
 * The abort reason the service uses when the delivery timeout wins. The sink reads it to
 * tell a timeout (leave the dictation on the clipboard, which the service reports) from
 * a cancel (put the person's clipboard back and report nothing).
 */
export const DELIVERY_TIMED_OUT = 'delivery-timeout';
