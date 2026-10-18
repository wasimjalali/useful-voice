import { describe, expect, it } from 'vitest';
import type { ClipboardContents, RestoreOutcome } from '../src/core/delivery/clipboardRestore.js';
import {
  deliverText,
  type KeystrokeRequest,
  type KeystrokeResult,
  type PasteFlowPorts,
  type PasteFlowRequest,
} from '../src/core/delivery/pasteFlow.js';
import {
  DELIVERY_ABORT_GRACE_MS,
  DELIVERY_TIMED_OUT,
  DELIVERY_TIMEOUT_MS,
  HOST_STARTUP_TIMEOUT_MS,
  PASTE_KEYSTROKE_TIMEOUT_MS,
  WORST_CASE_DELIVERY_MS,
  WRITTEN_DELIVERY_MAX_MS,
} from '../src/core/delivery/timing.js';

/**
 * The sink's ordering rules. Failure cases first:
 *  1. the delivery timeout wins while the sink is mid-flight and the keystroke goes out
 *     afterwards (a double paste, or a paste of the wrong clipboard)
 *  2. a cancel does the same
 *  3. a timeout that stopped the sink before the paste leaves the person's OLD clipboard
 *     in place although the service told them "copied to your clipboard"
 *  4. the old clipboard is put back after a sent paste: a target that stalls then pastes
 *     it, and the dictation is lost
 *  5. a cancel puts the old clipboard over a newer copy the person made meanwhile
 *  6. Useful Voice comes to the front while the keystroke waits in the queue, and the
 *     paste lands in our own window
 *  7. the keystroke was written and the abort arrives after: the dictation is reported
 *     cancelled or "Press Ctrl+V" although it may have pasted
 *  8. the clipboard is replaced while the request waits, and the person's newer copy is
 *     pasted over, or overwritten, or the dictation is claimed as pasted
 *  9. a dictation started in our window is pasted into a button, the page or a password box
 */

const original: ClipboardContents = { text: 'the old clipboard', html: '', rtf: '', incomplete: false };

class Harness {
  clipboardText = 'the old clipboard';
  events: string[] = [];
  keystrokes = 0;
  snapshot: ClipboardContents = { ...original };
  ownInFront = false;
  ownField = true;
  keystrokeResult: KeystrokeResult = 'sent';
  lastRequest: KeystrokeRequest | null = null;
  /**
   * Run when the keystroke port is reached, to simulate the world changing while the
   * request waits in the queue.
   */
  whileQueued: () => void = () => undefined;
  /** Run after the request counts as written, to simulate an abort that arrives later. */
  afterWritten: () => void = () => undefined;

  readonly ports: PasteFlowPorts<ClipboardContents> = {
    writeText: (text) => {
      this.clipboardText = text;
      this.events.push(`write:${text}`);
    },
    snapshot: () => this.snapshot,
    restore: (snapshot): RestoreOutcome => {
      this.clipboardText = snapshot.text;
      this.events.push('restore');
      return 'restored';
    },
    holdsText: (text) => this.clipboardText === text,
    pasteKeystroke: async (request): Promise<KeystrokeResult> => {
      this.lastRequest = request;
      this.whileQueued();
      // The real port checks both at the moment it writes the keystroke.
      if (request.signal?.aborted || !request.canSend()) return 'blocked';
      this.keystrokes += 1;
      this.events.push('keystroke');
      this.afterWritten();
      return this.keystrokeResult;
    },
    ownWindowInFront: () => this.ownInFront,
    ownFieldAcceptsPaste: async () => this.ownField,
    log: (category, message) => this.events.push(`log:${category}:${message}`),
  };
}

function request(overrides: Partial<PasteFlowRequest> = {}): PasteFlowRequest {
  return { text: 'hello world', mode: 'paste', targetApp: 'Notepad', ...overrides };
}

describe('deliverText: abort while the request is still unsent', () => {
  it('never sends the keystroke when the timeout fires just before it', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.whileQueued = () => controller.abort(DELIVERY_TIMED_OUT);
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    // The service said "copied": the dictation has to be there.
    expect(harness.clipboardText).toBe('hello world');
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.events).not.toContain('restore');
  });

  it('puts the old clipboard back and reports cancelled when a cancel arrives before the keystroke', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.whileQueued = () => controller.abort();
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(harness.clipboardText).toBe('the old clipboard');
    expect(result).toEqual({ delivered: false, clipboardFallback: false, cancelled: true });
  });

  it('does not overwrite a newer copy when a cancel arrives before the keystroke', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.whileQueued = () => {
      harness.clipboardText = 'something newer';
      controller.abort();
    };
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(harness.clipboardText).toBe('something newer');
    expect(result.cancelled).toBe(true);
  });

  it('leaves an image-bearing clipboard alone on a cancel instead of restoring its text part', async () => {
    const harness = new Harness();
    harness.snapshot = { ...original, incomplete: true };
    const controller = new AbortController();
    harness.whileQueued = () => controller.abort();
    await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.events).not.toContain('restore');
    expect(harness.clipboardText).toBe('hello world');
  });

  it('leaves the clipboard alone on a cancel when it held nothing worth restoring', async () => {
    const harness = new Harness();
    harness.snapshot = { ...original, text: '' };
    const controller = new AbortController();
    harness.whileQueued = () => controller.abort();
    await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.events).not.toContain('restore');
  });

  it('stops at once when already aborted, touching nothing', async () => {
    const harness = new Harness();
    const result = await deliverText(request({ signal: AbortSignal.abort() }), harness.ports);
    expect(harness.events).toEqual([]);
    expect(result.cancelled).toBe(true);
  });

  it('copy mode stops on a pre-aborted signal without writing', async () => {
    const harness = new Harness();
    const result = await deliverText(request({ mode: 'copy', signal: AbortSignal.abort() }), harness.ports);
    expect(harness.clipboardText).toBe('the old clipboard');
    expect(result.cancelled).toBe(true);
  });

  it('treats a blocked keystroke as cancelled even when the script gave a reason', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.ports.pasteKeystroke = async () => {
      controller.abort();
      return 'blocked-own';
    };
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(result.cancelled).toBe(true);
  });
});

describe('deliverText: the keystroke may have gone out', () => {
  it('stays delivered when the abort arrives after the request was written', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.afterWritten = () => controller.abort();
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.keystrokes).toBe(1);
    // Never cancelled, never "Press Ctrl+V": the key is out and cannot be taken back.
    expect(result).toEqual({ delivered: true, clipboardFallback: false });
    expect(harness.events).not.toContain('restore');
    expect(harness.clipboardText).toBe('hello world');
  });

  it('stays delivered when the timeout abort arrives after the request was written', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.afterWritten = () => controller.abort(DELIVERY_TIMED_OUT);
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(result).toEqual({ delivered: true, clipboardFallback: false });
  });

  it('counts an indeterminate keystroke as delivered, even when aborted', async () => {
    // The request was written and then the process died, or a one-shot was killed on abort.
    const harness = new Harness();
    const controller = new AbortController();
    harness.ports.pasteKeystroke = async () => {
      controller.abort();
      return 'indeterminate';
    };
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(result).toEqual({ delivered: true, clipboardFallback: false });
    expect(harness.events).not.toContain('restore');
    expect(harness.clipboardText).toBe('hello world');
  });

  it('reports a keystroke that never started as copied, with the dictation on the clipboard', async () => {
    const harness = new Harness();
    harness.keystrokeResult = 'failed';
    const result = await deliverText(request(), harness.ports);
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.clipboardText).toBe('hello world');
  });
});

describe('deliverText: paste', () => {
  it('says pasted and leaves the dictation on the clipboard, never restoring the old one', async () => {
    const harness = new Harness();
    const result = await deliverText(request(), harness.ports);
    expect(result).toEqual({ delivered: true, clipboardFallback: false });
    expect(harness.keystrokes).toBe(1);
    // A target that stalls would paste whatever is on the clipboard when it gets to it.
    expect(harness.clipboardText).toBe('hello world');
    expect(harness.events).not.toContain('restore');
  });

  it('passes the text and the own-window allowance to the keystroke port', async () => {
    const harness = new Harness();
    await deliverText(request({ startedInOwnWindow: false }), harness.ports);
    expect(harness.lastRequest?.text).toBe('hello world');
    expect(harness.lastRequest?.allowOwnWindow).toBe(false);
  });

  it('copy mode puts the text on the clipboard and nothing else', async () => {
    const harness = new Harness();
    const result = await deliverText(request({ mode: 'copy' }), harness.ports);
    expect(result).toEqual({ delivered: true, clipboardFallback: false });
    expect(harness.keystrokes).toBe(0);
    expect(harness.clipboardText).toBe('hello world');
  });
});

describe('deliverText: our own windows', () => {
  it('copies instead when our window is in front after starting elsewhere', async () => {
    const harness = new Harness();
    harness.ownInFront = true;
    const result = await deliverText(request({ startedInOwnWindow: false }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.clipboardText).toBe('hello world');
  });

  it('copies instead when our window comes to the front while the keystroke is queued', async () => {
    const harness = new Harness();
    harness.whileQueued = () => {
      harness.ownInFront = true;
    };
    const result = await deliverText(request({ startedInOwnWindow: false }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.clipboardText).toBe('hello world');
    expect(harness.events.some((event) => event.includes('Useful Voice came to the front'))).toBe(true);
  });

  it('copies when the script itself finds our window in front', async () => {
    const harness = new Harness();
    harness.keystrokeResult = 'blocked-own';
    const result = await deliverText(request(), harness.ports);
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.clipboardText).toBe('hello world');
  });

  it('pastes into our own window when the dictation started there and a text field has focus', async () => {
    const harness = new Harness();
    harness.ownInFront = true;
    const result = await deliverText(request({ startedInOwnWindow: true }), harness.ports);
    expect(harness.keystrokes).toBe(1);
    expect(harness.lastRequest?.allowOwnWindow).toBe(true);
    expect(result.delivered).toBe(true);
  });

  it('copies a dictation that started in our window when no text field has focus', async () => {
    const harness = new Harness();
    harness.ownInFront = true;
    harness.ownField = false;
    const result = await deliverText(request({ startedInOwnWindow: true }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.clipboardText).toBe('hello world');
  });

  it('does not look for a text field when another app is in front', async () => {
    const harness = new Harness();
    let asked = 0;
    harness.ports.ownFieldAcceptsPaste = async () => {
      asked += 1;
      return false;
    };
    await deliverText(request({ startedInOwnWindow: true }), harness.ports);
    expect(asked).toBe(0);
    expect(harness.keystrokes).toBe(1);
  });

  it('refuses when our window comes to the front after the field check was skipped', async () => {
    // Started in our window, another app was in front at delivery, then ours came forward
    // while the request waited: the text field was never checked.
    const harness = new Harness();
    harness.whileQueued = () => {
      harness.ownInFront = true;
    };
    const result = await deliverText(request({ startedInOwnWindow: true }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
  });
});

describe('deliverText: the clipboard changed while waiting', () => {
  it('sends nothing and leaves the newer copy alone', async () => {
    const harness = new Harness();
    harness.whileQueued = () => {
      harness.clipboardText = 'the person copied this meanwhile';
    };
    const result = await deliverText(request(), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(harness.clipboardText).toBe('the person copied this meanwhile');
    expect(harness.events).not.toContain('restore');
    // Neither pasted nor copied: the caller reports an honest error.
    expect(result).toEqual({ delivered: false, clipboardFallback: false, clipboardChanged: true });
  });

  it('reports the same when the script finds the clipboard changed just before SendKeys', async () => {
    const harness = new Harness();
    harness.keystrokeResult = 'blocked-clipboard';
    const result = await deliverText(request(), harness.ports);
    expect(result).toEqual({ delivered: false, clipboardFallback: false, clipboardChanged: true });
    expect(harness.clipboardText).toBe('hello world');
  });
});

describe('delivery timing', () => {
  it('lets a written request finish before the service gives up on the verdict', () => {
    expect(DELIVERY_TIMEOUT_MS).toBeGreaterThan(WRITTEN_DELIVERY_MAX_MS);
    expect(DELIVERY_ABORT_GRACE_MS).toBeGreaterThan(WRITTEN_DELIVERY_MAX_MS);
  });

  it('counts the cold host start and the queue in the honest worst case', () => {
    expect(WORST_CASE_DELIVERY_MS).toBeGreaterThanOrEqual(
      HOST_STARTUP_TIMEOUT_MS + PASTE_KEYSTROKE_TIMEOUT_MS + WRITTEN_DELIVERY_MAX_MS,
    );
    // Deliberately above the service timeout: a request still waiting is interrupted, it
    // is not given the whole worst case.
    expect(WORST_CASE_DELIVERY_MS).toBeGreaterThan(DELIVERY_TIMEOUT_MS);
  });
});
