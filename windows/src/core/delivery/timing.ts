/**
 * How long each step of a delivery may take, and how long the whole of it may.
 *
 * A delivery has two very different phases, and the limits treat them differently:
 *
 *  - BEFORE the keystroke request is written to PowerShell, the sink may be waiting for
 *    the host to start (up to `HOST_STARTUP_TIMEOUT_MS`) and for requests queued ahead of
 *    it. Nothing has been sent, so the service may interrupt it at any time: the signal
 *    aborts, the queued request is dropped, and the dictation is reported as copied.
 *  - ONCE the request is written, the keystroke may have gone out. It can no longer be
 *    taken back, and a timeout or an abort proves nothing about whether it ran. From
 *    there the dictation counts as delivered whatever happens (see `pasteFlow.ts`), so
 *    the service must wait for the sink's own verdict instead of overruling it.
 */

/** Reading which window is in front (the HUD label and the language picker; not delivery). */
export const FOREGROUND_QUERY_TIMEOUT_MS = 2500;

/** Sending Ctrl+V once the request is written, per attempt. */
export const PASTE_KEYSTROKE_TIMEOUT_MS = 2500;

/** How long a cold PowerShell host may take to compile its types and answer. */
export const HOST_STARTUP_TIMEOUT_MS = 20_000;

/** Snapshotting, writing and checking the clipboard: synchronous, but not free. */
const CLIPBOARD_WORK_MS = 500;

/**
 * The longest a sink can legitimately run after its request is written: the keystroke's
 * own budget plus the clipboard work. A written request is never retried elsewhere, so
 * this is counted once.
 */
export const WRITTEN_DELIVERY_MAX_MS = PASTE_KEYSTROKE_TIMEOUT_MS + CLIPBOARD_WORK_MS;

/**
 * The longest a delivery can take end to end: a request that waits out a cold host start
 * and one request queued ahead of it, then runs. This is deliberately LONGER than
 * `DELIVERY_TIMEOUT_MS`: the service interrupts a request that is still waiting, it does
 * not let it wait this long.
 */
export const WORST_CASE_DELIVERY_MS =
  HOST_STARTUP_TIMEOUT_MS + PASTE_KEYSTROKE_TIMEOUT_MS + WRITTEN_DELIVERY_MAX_MS;

/**
 * The service aborts a delivery after this long. Above what a written request needs, so a
 * working sink is not interrupted in its last, committed phase; a request still waiting
 * is interrupted here.
 */
export const DELIVERY_TIMEOUT_MS = 15_000;

/**
 * After the abort the service still waits this long for the sink's own verdict, because
 * a request that was already written may have pasted. Enough for a written request to
 * finish or time out, with margin. Only a sink that answers nothing at all for this long
 * is treated as lost.
 */
export const DELIVERY_ABORT_GRACE_MS = WRITTEN_DELIVERY_MAX_MS + 2000;

/**
 * The abort reason the service uses when the delivery timeout wins. The sink reads it to
 * tell a timeout (leave the dictation on the clipboard, which the service reports) from
 * a cancel (put the person's clipboard back when that is safe).
 */
export const DELIVERY_TIMED_OUT = 'delivery-timeout';
