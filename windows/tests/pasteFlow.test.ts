import { describe, expect, it } from 'vitest';
import type { ClipboardContents, RestoreOutcome } from '../src/core/delivery/clipboardRestore.js';
import { deliverText, type KeystrokeResult, type PasteFlowPorts, type PasteFlowRequest } from '../src/core/delivery/pasteFlow.js';
import {
  DELIVERY_TIMED_OUT,
  DELIVERY_TIMEOUT_MS,
  PASTE_KEYSTROKE_TIMEOUT_MS,
  WORST_CASE_DELIVERY_MS,
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
 */

const original: ClipboardContents = { text: 'the old clipboard', html: '', rtf: '', incomplete: false };

class Harness {
  clipboardText = 'the old clipboard';
  events: string[] = [];
  keystrokes = 0;
  snapshot: ClipboardContents = { ...original };
  ownInFront = false;
  keystrokeResult: 'sent' | 'failed' = 'sent';
  /** Run when the keystroke port is reached, to simulate the world changing while it queued. */
  beforeKeystroke: () => void = () => undefined;

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
    pasteKeystroke: async (signal, canSend): Promise<KeystrokeResult> => {
      this.beforeKeystroke();
      // The real port checks both at the moment it writes the keystroke.
      if (signal?.aborted || !canSend()) return 'blocked';
      this.keystrokes += 1;
      this.events.push('keystroke');
      return this.keystrokeResult;
    },
    ownWindowInFront: () => this.ownInFront,
    log: (category, message) => this.events.push(`log:${category}:${message}`),
  };
}

function request(overrides: Partial<PasteFlowRequest> = {}): PasteFlowRequest {
  return { text: 'hello world', mode: 'paste', targetApp: 'Notepad', ...overrides };
}

describe('deliverText: abort', () => {
  it('never sends the keystroke when the timeout fires just before it', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.beforeKeystroke = () => controller.abort(DELIVERY_TIMED_OUT);
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
    harness.beforeKeystroke = () => controller.abort();
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(harness.clipboardText).toBe('the old clipboard');
    expect(result).toEqual({ delivered: false, clipboardFallback: false, cancelled: true });
  });

  it('does not overwrite a newer copy when a cancel arrives before the keystroke', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.beforeKeystroke = () => {
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
    harness.beforeKeystroke = () => controller.abort();
    await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.events).not.toContain('restore');
    expect(harness.clipboardText).toBe('hello world');
  });

  it('leaves the clipboard alone on a cancel when it held nothing worth restoring', async () => {
    const harness = new Harness();
    harness.snapshot = { ...original, text: '' };
    const controller = new AbortController();
    harness.beforeKeystroke = () => controller.abort();
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

  it('reports a keystroke that failed as copied, with the dictation on the clipboard', async () => {
    const harness = new Harness();
    harness.keystrokeResult = 'failed';
    const result = await deliverText(request(), harness.ports);
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.clipboardText).toBe('hello world');
  });

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
    harness.beforeKeystroke = () => {
      harness.ownInFront = true;
    };
    const result = await deliverText(request({ startedInOwnWindow: false }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.clipboardText).toBe('hello world');
    expect(harness.events.some((event) => event.includes('Useful Voice is in front'))).toBe(true);
  });

  it('pastes into our own window when the dictation started there', async () => {
    const harness = new Harness();
    harness.ownInFront = true;
    await deliverText(request({ startedInOwnWindow: true }), harness.ports);
    expect(harness.keystrokes).toBe(1);
  });

  it('copy mode puts the text on the clipboard and nothing else', async () => {
    const harness = new Harness();
    const result = await deliverText(request({ mode: 'copy' }), harness.ports);
    expect(result).toEqual({ delivered: true, clipboardFallback: false });
    expect(harness.keystrokes).toBe(0);
    expect(harness.clipboardText).toBe('hello world');
  });
});

describe('delivery timing', () => {
  it('keeps the service timeout well above the worst case, one-shot rerun included', () => {
    // The host attempt can time out unsent and the same step then reruns in a one-shot process.
    expect(WORST_CASE_DELIVERY_MS).toBeGreaterThanOrEqual(2 * PASTE_KEYSTROKE_TIMEOUT_MS);
    expect(DELIVERY_TIMEOUT_MS).toBeGreaterThanOrEqual(WORST_CASE_DELIVERY_MS * 1.5);
  });
});
