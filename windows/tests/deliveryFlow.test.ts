import { describe, expect, it } from 'vitest';
import {
  DELIVERY_TIMEOUT,
  PROOF_READ_MS,
  deliverToTarget,
  type DeliveryEffects,
  type InsertAttempt,
  type PasteDeliveryInput,
} from '../src/core/delivery/deliveryFlow.js';
import type { ClipboardContents } from '../src/core/delivery/clipboardRestore.js';
import type { DeliveryTarget } from '../src/core/delivery/deliveryTarget.js';
import { HudModel, hudLabel, isPasteBlocked, type HudFrame } from '../src/core/hudModel.js';

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
 * user turned restoring off; calling a partly typed dictation plain "copied"; telling
 * the user to press Ctrl+V after a keystroke went out (the text twice); a paste that
 * used all its time leaving the proof no time to read the foreground.
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

  it('copies text with a line break for a type-out app: nothing typed or pasted, its own notice', async () => {
    const h = harness({ focus: [terminal] });
    const result = await deliverToTarget(input({ target: terminal, text: 'git add .\ngit commit' }), h.fx);
    expect(result).toMatchObject({ delivered: false, clipboardFallback: true, lineBreaks: true, method: 'copyOnly' });
    expect(keystrokes(h.calls)).toEqual([]);
    expect(h.calls).not.toContain('restore');
    expect(h.clipboard()).toBe('git add .\ngit commit');
  });

  it('decides line-break copy before the lock: no foreground read, no reactivation', async () => {
    const h = harness({ focus: [elsewhere], reactivate: 'refused' });
    const result = await deliverToTarget(input({ target: terminal, text: 'one\ntwo' }), h.fx);
    expect(result).toMatchObject({ lineBreaks: true, reason: 'lineBreaks', clipboardFallback: true });
    expect(h.calls).not.toContain('reactivate');
    expect(h.calls).not.toContain('readFocus');
    expect(h.clipboard()).toBe('one\ntwo');
  });

  it('still pastes text with a line break into a paste app', async () => {
    const h = harness({ focus: [notepad] });
    const result = await deliverToTarget(input({ text: 'one\ntwo' }), h.fx);
    expect(result).toMatchObject({ delivered: true, method: 'paste' });
    expect(result.lineBreaks).toBeUndefined();
    expect(keystrokes(h.calls)).toEqual(['paste']);
  });

  it('says inserted after a paste into a window whose text cannot be checked, and never restores', async () => {
    const slack: DeliveryTarget = { appId: 'slack', processId: 40, windowHandle: 0x400 };
    const h = harness({ focus: [slack] });
    const result = await deliverToTarget(input({ target: slack }), h.fx);
    expect(result).toMatchObject({ delivered: true, unproven: true, clipboardFallback: false, reason: 'unverifiable-target' });
    expect(h.calls).not.toContain('restore');
    expect(h.clipboard()).toBe('hello world');
  });

  it('does not restore when nothing consumed the paste, but still says inserted', async () => {
    const h = harness({ focus: [notepad], stillOurs: true });
    const result = await deliverToTarget(input(), h.fx);
    expect(result).toMatchObject({ delivered: true, unproven: true, clipboardFallback: false, reason: 'paste-not-consumed' });
    expect(h.clipboard()).toBe('hello world');
  });
});

describe('sent, then the proof', () => {
  it('a sent paste whose focus cannot be read afterwards says inserted, keeps the text and never restores', async () => {
    const h = harness({ focus: [notepad, null] });
    const result = await deliverToTarget(input(), h.fx);
    expect(result).toMatchObject({ delivered: true, unproven: true, clipboardFallback: false, method: 'paste' });
    expect(h.calls).not.toContain('restore');
    expect(h.clipboard()).toBe('hello world');
  });

  it('a sent type-out whose focus cannot be read afterwards counts as typed', async () => {
    const h = harness({ focus: [terminal, null] });
    const result = await deliverToTarget(input({ target: terminal }), h.fx);
    expect(result).toMatchObject({ delivered: true, clipboardFallback: false, method: 'typeOut', reason: 'typed' });
    expect(result.unproven).toBeUndefined();
    expect(h.clipboard()).toBe('hello world');
  });

  it('a sent type-out counts as typed even when another window is in front afterwards', async () => {
    const h = harness({ focus: [terminal, elsewhere] });
    const result = await deliverToTarget(input({ target: terminal }), h.fx);
    expect(result).toMatchObject({ delivered: true, clipboardFallback: false, reason: 'typed' });
  });

  it('keeps time back from the paste so the proof read always gets some', async () => {
    let clock = 0;
    let pasteDeadline = 0;
    let proofBudget = -1;
    let reads = 0;
    const h = harness({ focus: [notepad] });
    h.fx.now = () => clock;
    h.fx.wait = async (ms) => {
      clock += ms;
    };
    h.fx.readFocus = async (budget) => {
      reads += 1;
      if (reads === 2) proofBudget = budget;
      return { ...notepad };
    };
    h.fx.paste = async (_target, until) => {
      pasteDeadline = until;
      clock = until + 100; // the script overran its deadline a little
      return { result: 'sent' };
    };
    const result = await deliverToTarget(input({ deadline: 5000 }), h.fx);
    expect(pasteDeadline).toBe(5000 - 700 - PROOF_READ_MS);
    expect(proofBudget).toBeGreaterThanOrEqual(PROOF_READ_MS);
    expect(result).toMatchObject({ delivered: true, reason: 'restored' });
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

  it('reads the page once at the lock, never while or after typing (a live search may rewrite it)', async () => {
    const edge: DeliveryTarget = { appId: 'msedge', processId: 50, windowHandle: 0x500, browserUrl: 'https://example.com/search?q=a' };
    const h = harness({ focus: [edge, { ...edge, browserUrl: 'https://example.com/search?q=abc' }] });
    const result = await deliverToTarget(input({ target: edge, typeOutApps: ['msedge'] }), h.fx);
    expect(result).toMatchObject({ delivered: true, method: 'typeOut', reason: 'typed' });
    expect(h.calls.filter((call) => call === 'address')).toHaveLength(1);
    expect(h.calls.indexOf('address')).toBeLessThan(h.calls.indexOf('typeOut'));
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

    it(`marks only a failed paste script as blocked (${result})`, async () => {
      const h = harness({ focus: [notepad], paste: { result } });
      const outcome = await deliverToTarget(input(), h.fx);
      expect(outcome.pasteFailed).toBe(result === 'failed' ? true : undefined);
      const typed = harness({ focus: [terminal], typeOut: { result, typedUnits: 0 } });
      expect((await deliverToTarget(input({ target: terminal }), typed.fx)).pasteFailed).toBeUndefined();
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
    expect(seen).toBe(4321 - 700 - PROOF_READ_MS);
    let typedUntil = 0;
    const t = harness({ focus: [terminal] });
    t.fx.typeOut = async (_target, _batches, deadline) => {
      typedUntil = deadline;
      return { result: 'sent', typedUnits: 11 };
    };
    await deliverToTarget(input({ target: terminal, deadline: 4321 }), t.fx);
    expect(typedUntil).toBe(4321);
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
  it('only a paste Windows refused raises the administrator banner', () => {
    const copied = { kind: 'delivered', words: 3, result: 'copiedNotPasted' } as const;
    expect(isPasteBlocked({ ...copied, pasteBlocked: true })).toBe(true);
    expect(isPasteBlocked(copied)).toBe(false);
    expect(isPasteBlocked({ ...copied, lineBreaks: true })).toBe(false);
    expect(isPasteBlocked({ ...copied, partlyTyped: true })).toBe(false);
    expect(isPasteBlocked({ kind: 'delivered', words: 3, result: 'pasted' })).toBe(false);
    expect(isPasteBlocked({ kind: 'cancelled' })).toBe(false);
  });

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
    hud.outcome({ kind: 'delivered', words: 3, result: 'copiedNotPasted', lineBreaks: true });
    expect(frames.at(-1)).toMatchObject({ kind: 'copied', lineBreaks: true });
    expect(hudLabel(frames.at(-1)!)).toBe("Copied. It has line breaks, so it wasn't typed. Press Ctrl+V.");
  });
});
