import { describe, expect, it } from 'vitest';
import {
  DELIVERY_TIMEOUT,
  deliverToTarget,
  type DeliveryEffects,
  type InsertAttempt,
  type PasteDeliveryInput,
} from '../src/core/delivery/deliveryFlow.js';
import type { ClipboardContents } from '../src/core/delivery/clipboardRestore.js';
import type { DeliveryTarget } from '../src/core/delivery/deliveryTarget.js';
import { HudModel, hudLabel, type HudFrame } from '../src/core/hudModel.js';

/**
 * One hotkey dictation's delivery, with every platform effect faked and recorded.
 * Mirrors `Tests/UsefulVoiceCoreTests/InsertionFlowTests.swift`.
 *
 * Ways it could fail, each pinned below: pasting or typing when the target is not in
 * front; reactivating more than once, or after the target is gone; pasting after a
 * reactivation that brought back the wrong window; reactivating to "fix" a changed
 * page; both pasting and typing; typing text with a line break; sending a keystroke
 * after the deadline or after the service gave up; a cancel that leaves the user's
 * clipboard overwritten; restoring the clipboard after an unproven paste, or when the
 * user turned restoring off; calling a partly typed dictation plain "copied".
 */

const notepad: DeliveryTarget = { appId: 'notepad', processId: 10, windowHandle: 0x100, focusHandle: 0x101 };
const terminal: DeliveryTarget = { appId: 'windowsterminal', processId: 20, windowHandle: 0x200, focusHandle: 0x201 };
const elsewhere: DeliveryTarget = { appId: 'usefulvoice', processId: 30, windowHandle: 0x300 };

interface Script {
  /** What `readFocus` returns, call by call (the last one repeats). */
  focus: Array<DeliveryTarget | null>;
  reactivate?: 'ok' | 'gone' | 'refused';
  paste?: InsertAttempt;
  typeOut?: InsertAttempt;
  /** Whether the clipboard still holds the text when the proof reads it. */
  stillOurs?: boolean;
  /** Milliseconds each await costs on the fake clock. */
  stepMs?: number;
  /** Runs inside the named effect, after it is recorded. */
  during?: Partial<Record<'readFocus' | 'reactivate' | 'paste' | 'typeOut', () => void>>;
}

function harness(script: Script) {
  let clock = 0;
  let focusCall = 0;
  const calls: string[] = [];
  const typed: number[][][] = [];
  let clipboard = 'what the user had copied';
  const step = async (name: 'readFocus' | 'reactivate' | 'paste' | 'typeOut'): Promise<void> => {
    calls.push(name);
    script.during?.[name]?.();
    clock += script.stepMs ?? 10;
  };
  const fx: DeliveryEffects<ClipboardContents> = {
    now: () => clock,
    readFocus: async (_budget, withAddress) => {
      await step('readFocus');
      if (withAddress) calls.push('address');
      const value = script.focus[Math.min(focusCall, script.focus.length - 1)] ?? null;
      focusCall += 1;
      return value ? { ...value } : null;
    },
    reactivate: async () => {
      await step('reactivate');
      return script.reactivate ?? 'ok';
    },
    snapshotClipboard: () => ({ text: clipboard, html: '', rtf: '', incomplete: false }),
    writeClipboard: (text) => {
      calls.push('write');
      clipboard = text;
    },
    restoreClipboard: (snapshot) => {
      calls.push('restore');
      clipboard = snapshot.text;
    },
    clipboardHoldsText: () => script.stillOurs ?? false,
    paste: async () => {
      await step('paste');
      return script.paste ?? { result: 'sent' };
    },
    typeOut: async (_target, batches) => {
      await step('typeOut');
      typed.push(batches);
      return script.typeOut ?? { result: 'sent', typedUnits: batches.flat().length };
    },
    wait: async (ms) => {
      clock += ms;
    },
    log: () => undefined,
  };
  return { fx, calls, typed, clipboard: () => clipboard };
}

function input(overrides: Partial<PasteDeliveryInput> = {}): PasteDeliveryInput {
  return {
    text: 'hello world',
    target: notepad,
    typeOutApps: ['windowsterminal'],
    restorePreviousClipboard: true,
    deadline: 5000,
    settleMs: 700,
    ...overrides,
  };
}

const keystrokes = (calls: string[]): string[] => calls.filter((call) => call === 'paste' || call === 'typeOut');

describe('target in front', () => {
  it('pastes once, proves it and restores the clipboard', async () => {
    const h = harness({ focus: [notepad] });
    const result = await deliverToTarget(input(), h.fx);
    expect(result).toMatchObject({ delivered: true, clipboardFallback: false, method: 'paste', reason: 'restored' });
    expect(keystrokes(h.calls)).toEqual(['paste']);
    expect(h.calls).not.toContain('reactivate');
    expect(h.clipboard()).toBe('what the user had copied');
  });

  it('keeps the dictation on the clipboard when restoring is off', async () => {
    const h = harness({ focus: [notepad] });
    const result = await deliverToTarget(input({ restorePreviousClipboard: false }), h.fx);
    expect(result).toMatchObject({ delivered: true, reason: 'restore-disabled' });
    expect(h.calls).not.toContain('restore');
    expect(h.clipboard()).toBe('hello world');
  });

  it('types for a type-out app, never pastes, and sends the batches of the whole text', async () => {
    const text = 'a fairly long command line that needs more than one batch 😀 done';
    const h = harness({ focus: [terminal] });
    const result = await deliverToTarget(input({ target: terminal, text }), h.fx);
    expect(result).toMatchObject({ delivered: true, method: 'typeOut', reason: 'typed' });
    expect(keystrokes(h.calls)).toEqual(['typeOut']);
    expect(String.fromCharCode(...h.typed[0]!.flat())).toBe(text);
    expect(h.typed[0]!.every((batch) => batch.length <= 20)).toBe(true);
    expect(h.clipboard()).toBe(text);
  });

  it('pastes text with a line break even for a type-out app', async () => {
    const h = harness({ focus: [terminal] });
    const result = await deliverToTarget(input({ target: terminal, text: 'git add .\ngit commit' }), h.fx);
    expect(result.method).toBe('paste');
    expect(keystrokes(h.calls)).toEqual(['paste']);
  });

  it('does not claim a paste into a window whose text cannot be checked', async () => {
    const slack: DeliveryTarget = { appId: 'slack', processId: 40, windowHandle: 0x400 };
    const h = harness({ focus: [slack] });
    const result = await deliverToTarget(input({ target: slack }), h.fx);
    expect(result).toMatchObject({ delivered: false, clipboardFallback: true, reason: 'unverifiable-target' });
    expect(h.calls).not.toContain('restore');
  });

  it('does not restore when nothing consumed the paste', async () => {
    const h = harness({ focus: [notepad], stillOurs: true });
    const result = await deliverToTarget(input(), h.fx);
    expect(result).toMatchObject({ delivered: false, reason: 'paste-not-consumed' });
    expect(h.clipboard()).toBe('hello world');
  });
});

describe('the target lock', () => {
  for (const [label, target, focusAfter] of [
    ['paste', notepad, notepad],
    ['type-out', terminal, terminal],
  ] as const) {
    it(`reactivates exactly once, then ${label}s`, async () => {
      const h = harness({ focus: [elsewhere, focusAfter], reactivate: 'ok' });
      const result = await deliverToTarget(input({ target }), h.fx);
      expect(h.calls.filter((call) => call === 'reactivate')).toHaveLength(1);
      expect(result.delivered).toBe(true);
      expect(keystrokes(h.calls)).toHaveLength(1);
    });

    it(`copies when the target is gone (${label})`, async () => {
      const h = harness({ focus: [elsewhere], reactivate: 'gone' });
      const result = await deliverToTarget(input({ target }), h.fx);
      expect(result).toMatchObject({ delivered: false, clipboardFallback: true, reason: 'targetGone' });
      expect(keystrokes(h.calls)).toEqual([]);
      expect(h.clipboard()).toBe('hello world');
    });

    it(`copies when Windows refuses to bring it back (${label})`, async () => {
      const h = harness({ focus: [elsewhere, elsewhere], reactivate: 'refused' });
      const result = await deliverToTarget(input({ target }), h.fx);
      expect(result).toMatchObject({ clipboardFallback: true, reason: 'notRestored' });
      expect(keystrokes(h.calls)).toEqual([]);
      expect(h.calls.filter((call) => call === 'reactivate')).toHaveLength(1);
    });

    it(`copies when the reactivation brought back another focused child (${label})`, async () => {
      const h = harness({ focus: [elsewhere, { ...target, focusHandle: 0x999 }], reactivate: 'ok' });
      const result = await deliverToTarget(input({ target }), h.fx);
      expect(result.reason).toBe('notRestored');
      expect(keystrokes(h.calls)).toEqual([]);
    });
  }

  it('copies when nothing was captured at the press', async () => {
    const h = harness({ focus: [notepad] });
    const result = await deliverToTarget(input({ target: undefined }), h.fx);
    expect(result).toMatchObject({ clipboardFallback: true, reason: 'unknownTarget' });
    expect(keystrokes(h.calls)).toEqual([]);
  });

  it('copies without reactivating when the browser tab shows another page', async () => {
    const edge: DeliveryTarget = { appId: 'msedge', processId: 50, windowHandle: 0x500, browserUrl: 'https://mail.example.com/compose' };
    const h = harness({ focus: [{ ...edge, browserUrl: 'https://news.example.com/' }] });
    const result = await deliverToTarget(input({ target: edge }), h.fx);
    expect(result).toMatchObject({ clipboardFallback: true, reason: 'pageChanged' });
    expect(h.calls).toContain('address');
    expect(h.calls).not.toContain('reactivate');
    expect(keystrokes(h.calls)).toEqual([]);
  });

  it('reads no address when the target recorded none', async () => {
    const h = harness({ focus: [notepad] });
    await deliverToTarget(input(), h.fx);
    expect(h.calls).not.toContain('address');
  });
});

describe('the last look before the keystroke', () => {
  for (const result of ['moved', 'secure', 'failed', 'timeout'] as const) {
    it(`leaves the paste on the clipboard when the script reports ${result}`, async () => {
      const h = harness({ focus: [notepad], paste: { result } });
      const outcome = await deliverToTarget(input(), h.fx);
      expect(outcome).toMatchObject({ delivered: false, clipboardFallback: true, reason: result, method: 'paste' });
      expect(outcome.partlyTyped).toBeUndefined();
      expect(h.clipboard()).toBe('hello world');
      expect(h.calls).not.toContain('restore');
    });

    it(`says "partly typed" when typing stopped part way (${result})`, async () => {
      const h = harness({ focus: [terminal], typeOut: { result, typedUnits: 7 } });
      const outcome = await deliverToTarget(input({ target: terminal }), h.fx);
      expect(outcome).toMatchObject({ delivered: false, clipboardFallback: true, reason: result, partlyTyped: true });
      expect(h.clipboard()).toBe('hello world');
    });

    it(`stays plain "copied" when typing stopped before the first batch (${result})`, async () => {
      const h = harness({ focus: [terminal], typeOut: { result, typedUnits: 0 } });
      const outcome = await deliverToTarget(input({ target: terminal }), h.fx);
      expect(outcome.partlyTyped).toBeUndefined();
    });
  }

  it('counts a type-out script that died without saying as partly typed', async () => {
    const h = harness({ focus: [terminal], typeOut: { result: 'timeout' } });
    const outcome = await deliverToTarget(input({ target: terminal }), h.fx);
    expect(outcome.partlyTyped).toBe(true);
  });

  it('does not claim a typed delivery when focus left during typing', async () => {
    const h = harness({ focus: [terminal, elsewhere] });
    const outcome = await deliverToTarget(input({ target: terminal }), h.fx);
    expect(outcome).toMatchObject({ delivered: false, clipboardFallback: true, reason: 'focus-moved' });
  });
});

describe('time and cancel', () => {
  it('sends no keystroke once the deadline passed during the lock', async () => {
    const h = harness({ focus: [notepad], stepMs: 6000 });
    const outcome = await deliverToTarget(input(), h.fx);
    expect(outcome).toMatchObject({ delivered: false, clipboardFallback: true, reason: 'timeout' });
    expect(keystrokes(h.calls)).toEqual([]);
    expect(h.clipboard()).toBe('hello world');
  });

  it('sends no keystroke after the service gave up during a reactivation', async () => {
    const controller = new AbortController();
    const h = harness({
      focus: [elsewhere, notepad],
      during: { reactivate: () => controller.abort(DELIVERY_TIMEOUT) },
    });
    const outcome = await deliverToTarget(input({ signal: controller.signal }), h.fx);
    expect(outcome).toMatchObject({ clipboardFallback: true, reason: 'timeout' });
    expect(outcome.cancelled).toBeUndefined();
    expect(keystrokes(h.calls)).toEqual([]);
    // No second look at the foreground either: it stopped right after the reactivation.
    expect(h.calls.filter((call) => call === 'readFocus')).toHaveLength(1);
  });

  it('sends no keystroke after the service gave up while reading the foreground', async () => {
    const controller = new AbortController();
    const h = harness({ focus: [notepad], during: { readFocus: () => controller.abort(DELIVERY_TIMEOUT) } });
    const outcome = await deliverToTarget(input({ signal: controller.signal }), h.fx);
    expect(outcome.reason).toBe('timeout');
    expect(keystrokes(h.calls)).toEqual([]);
    expect(h.clipboard()).toBe('hello world');
  });

  it('hands the deadline to the keystroke script', async () => {
    let seen = 0;
    const h = harness({ focus: [notepad] });
    h.fx.paste = async (_target, deadline) => {
      seen = deadline;
      return { result: 'sent' };
    };
    await deliverToTarget(input({ deadline: 4321 }), h.fx);
    expect(seen).toBe(4321);
  });

  it('a cancel during the lock stops before the clipboard is touched', async () => {
    const controller = new AbortController();
    const h = harness({ focus: [notepad], during: { readFocus: () => controller.abort() } });
    const outcome = await deliverToTarget(input({ signal: controller.signal }), h.fx);
    expect(outcome).toEqual({ delivered: false, clipboardFallback: false, cancelled: true, reason: 'cancelled' });
    expect(h.calls).not.toContain('write');
    expect(h.clipboard()).toBe('what the user had copied');
  });

  it('a cancel already in place sends nothing and reads nothing', async () => {
    const controller = new AbortController();
    controller.abort();
    const h = harness({ focus: [notepad] });
    const outcome = await deliverToTarget(input({ signal: controller.signal }), h.fx);
    expect(outcome.cancelled).toBe(true);
    expect(h.calls).toEqual([]);
  });
});

describe('the notice', () => {
  it('the HUD says "partly typed", not "copied", when typing stopped part way', () => {
    const frames: Array<HudFrame | null> = [];
    const hud = new HudModel((frame) => frames.push(frame), {
      setTimeout: () => 0,
      clearTimeout: () => undefined,
      now: () => 0,
    });
    hud.outcome({ kind: 'delivered', words: 3, result: 'copiedNotPasted', partlyTyped: true });
    const partly = frames.at(-1)!;
    expect(partly).toMatchObject({ kind: 'copied', partlyTyped: true });
    expect(hudLabel(partly)).toBe('Partly typed. The full text is on your clipboard.');
    hud.outcome({ kind: 'delivered', words: 3, result: 'copiedNotPasted' });
    expect(hudLabel(frames.at(-1)!)).toBe('Copied. Press Ctrl+V to paste');
  });
});
