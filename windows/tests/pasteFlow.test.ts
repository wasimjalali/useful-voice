import { describe, expect, it } from 'vitest';
import type { ClipboardContents, PasteTarget, RestoreOutcome } from '../src/core/delivery/clipboardRestore.js';
import { deliverText, type PasteFlowPorts, type PasteFlowRequest } from '../src/core/delivery/pasteFlow.js';
import {
  CLIPBOARD_RESTORE_DELAY_MS,
  DELIVERY_TIMED_OUT,
  DELIVERY_TIMEOUT_MS,
  FOREGROUND_QUERY_TIMEOUT_MS,
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
 *  4. a restore that runs although the delivery was already abandoned
 */

const notepad: PasteTarget = { processName: 'notepad.exe', handle: 0x1234 };
const terminal: PasteTarget = { processName: 'WindowsTerminal.exe', handle: 0x99 };
const original: ClipboardContents = { text: 'the old clipboard', html: '', rtf: '', incomplete: false };

class Harness {
  clipboardText = 'the old clipboard';
  events: string[] = [];
  keystrokes = 0;
  foreground: Array<PasteTarget | null> = [notepad, notepad];
  foregroundCalls = 0;
  ownInFront = false;
  pasteResult = true;
  /** Run when the Nth await (by name) is reached, to simulate a signal firing mid-flight. */
  onAwait: Record<string, () => void> = {};

  readonly ports: PasteFlowPorts<ClipboardContents> = {
    writeText: (text) => {
      this.clipboardText = text;
      this.events.push(`write:${text}`);
    },
    snapshot: () => ({ ...original }),
    restore: (snapshot): RestoreOutcome => {
      this.clipboardText = snapshot.text;
      this.events.push('restore');
      return 'restored';
    },
    holdsText: (text) => this.clipboardText === text,
    foregroundWindow: async () => {
      const index = this.foregroundCalls++;
      this.events.push(`foreground:${index}`);
      this.onAwait[`foreground:${index}`]?.();
      return this.foreground[index] ?? null;
    },
    pasteKeystroke: async (signal) => {
      this.onAwait.paste?.();
      // The real port checks the signal at the moment it writes the keystroke.
      if (signal?.aborted) return false;
      this.keystrokes += 1;
      this.events.push('keystroke');
      return this.pasteResult;
    },
    ownWindowInFront: () => this.ownInFront,
    delay: async () => {
      this.events.push('delay');
      this.onAwait.delay?.();
    },
    log: (category, message) => this.events.push(`log:${category}:${message}`),
  };
}

function request(overrides: Partial<PasteFlowRequest> = {}): PasteFlowRequest {
  return { text: 'hello world', mode: 'paste', targetApp: 'Notepad', ...overrides };
}

describe('deliverText: abort', () => {
  it('never sends the keystroke when the timeout fires during the first window read', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.onAwait['foreground:0'] = () => controller.abort(DELIVERY_TIMED_OUT);
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    // The service said "copied": the dictation has to be there.
    expect(harness.clipboardText).toBe('hello world');
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
  });

  it('never sends the keystroke when the timeout fires just before it', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.onAwait.paste = () => controller.abort(DELIVERY_TIMED_OUT);
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(harness.clipboardText).toBe('hello world');
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.events).not.toContain('restore');
  });

  it('puts the old clipboard back and reports cancelled when a cancel arrives before the keystroke', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.onAwait.paste = () => controller.abort();
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(harness.clipboardText).toBe('the old clipboard');
    expect(result).toEqual({ delivered: false, clipboardFallback: false, cancelled: true });
  });

  it('stops at once when already aborted, touching nothing', async () => {
    const harness = new Harness();
    const result = await deliverText(request({ signal: AbortSignal.abort() }), harness.ports);
    expect(harness.events).toEqual([]);
    expect(result.cancelled).toBe(true);
  });

  it('leaves the dictation on the clipboard when the timeout fires after the keystroke', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.onAwait.delay = () => controller.abort(DELIVERY_TIMED_OUT);
    const result = await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.keystrokes).toBe(1);
    expect(harness.events).not.toContain('restore');
    expect(harness.clipboardText).toBe('hello world');
    expect(result.delivered).toBe(true);
  });

  it('skips the restore when aborted during the second window read', async () => {
    const harness = new Harness();
    const controller = new AbortController();
    harness.onAwait['foreground:1'] = () => controller.abort(DELIVERY_TIMED_OUT);
    await deliverText(request({ signal: controller.signal }), harness.ports);
    expect(harness.events).not.toContain('restore');
    expect(harness.clipboardText).toBe('hello world');
  });

  it('copy mode stops on a pre-aborted signal without writing', async () => {
    const harness = new Harness();
    const result = await deliverText(request({ mode: 'copy', signal: AbortSignal.abort() }), harness.ports);
    expect(harness.clipboardText).toBe('the old clipboard');
    expect(result.cancelled).toBe(true);
  });
});

describe('deliverText: paste', () => {
  it('pastes, says pasted and restores the old clipboard for a verifiable app', async () => {
    const harness = new Harness();
    const result = await deliverText(request(), harness.ports);
    expect(result).toEqual({ delivered: true, clipboardFallback: false });
    expect(harness.keystrokes).toBe(1);
    expect(harness.clipboardText).toBe('the old clipboard');
    // The settle delay sits between the keystroke and the restore.
    const order = harness.events.filter((e) => ['keystroke', 'delay', 'restore'].includes(e));
    expect(order).toEqual(['keystroke', 'delay', 'restore']);
  });

  it('says pasted and keeps the dictation on the clipboard for a terminal', async () => {
    const harness = new Harness();
    harness.foreground = [terminal, terminal];
    const result = await deliverText(request(), harness.ports);
    expect(result).toEqual({ delivered: true, clipboardFallback: false });
    expect(harness.clipboardText).toBe('hello world');
    expect(harness.events).not.toContain('delay');
  });

  it('does not overwrite a newer copy the person made while the paste settled', async () => {
    const harness = new Harness();
    harness.onAwait.delay = () => {
      harness.clipboardText = 'something newer';
    };
    const result = await deliverText(request(), harness.ports);
    expect(result.delivered).toBe(true);
    expect(harness.clipboardText).toBe('something newer');
  });

  it('keeps the dictation on the clipboard when focus moved while pasting', async () => {
    const harness = new Harness();
    harness.foreground = [notepad, { processName: 'explorer.exe', handle: 0x777 }];
    const result = await deliverText(request(), harness.ports);
    expect(result.delivered).toBe(true);
    expect(harness.clipboardText).toBe('hello world');
  });

  it('reports a keystroke that failed as copied, with the dictation on the clipboard', async () => {
    const harness = new Harness();
    harness.pasteResult = false;
    const result = await deliverText(request(), harness.ports);
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.clipboardText).toBe('hello world');
  });

  it('copies instead when our window came to the front after starting elsewhere', async () => {
    const harness = new Harness();
    harness.ownInFront = true;
    const result = await deliverText(request({ startedInOwnWindow: false }), harness.ports);
    expect(harness.keystrokes).toBe(0);
    expect(result).toEqual({ delivered: false, clipboardFallback: true });
    expect(harness.clipboardText).toBe('hello world');
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
  it('keeps the service timeout comfortably above the sink worst case', () => {
    expect(WORST_CASE_DELIVERY_MS).toBe(
      2 * FOREGROUND_QUERY_TIMEOUT_MS + PASTE_KEYSTROKE_TIMEOUT_MS + CLIPBOARD_RESTORE_DELAY_MS + 500,
    );
    expect(DELIVERY_TIMEOUT_MS).toBeGreaterThanOrEqual(WORST_CASE_DELIVERY_MS * 1.5);
  });
});
