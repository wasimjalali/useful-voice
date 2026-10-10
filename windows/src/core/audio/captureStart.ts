/**
 * The renderer's record of a capture that is still opening the microphone.
 *
 * `getUserMedia` can take seconds (a permission prompt, a slow driver), and the main
 * process may give up and send a discard in the meantime. Without a record of the
 * start in progress, that discard finds nothing to cancel, the stream opens a moment
 * later and nobody ever closes it. The start checks its ticket after every await and
 * tears down what it opened as soon as the ticket says it was cancelled.
 */

export interface CaptureStartTicket {
  readonly token: string;
  cancelled: boolean;
}

export class CaptureStartTracker {
  private current: CaptureStartTicket | null = null;

  /** Begin a start. Any start still in progress is superseded. */
  begin(token: string): CaptureStartTicket {
    if (this.current) this.current.cancelled = true;
    const ticket: CaptureStartTicket = { token, cancelled: false };
    this.current = ticket;
    return ticket;
  }

  /** The main process no longer wants `token`. */
  discard(token: string): void {
    if (this.current?.token === token) this.current.cancelled = true;
  }

  /** The start is over (it finished or failed), so a later discard has nothing to cancel. */
  finish(ticket: CaptureStartTicket): void {
    if (this.current === ticket) this.current = null;
  }
}
