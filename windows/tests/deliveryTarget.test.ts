import { describe, expect, it } from 'vitest';
import {
  KNOWN_BROWSERS,
  appIdFor,
  checkTarget,
  insertionMethodFor,
  isIdentified,
  isKnownBrowser,
  recheckTarget,
  targetMatches,
  typeOutChunks,
  typeOutText,
  type DeliveryTarget,
} from '../src/core/delivery/deliveryTarget.js';
import { parseForegroundLine } from '../src/core/delivery/foregroundLine.js';

/**
 * The target lock, mirrored from `Tests/UsefulVoiceCoreTests/DeliveryTargetTests.swift`.
 *
 * Ways it could fail: pasting into whatever is in front at delivery (the "wrong composer"
 * bug); matching by app alone when the process is known, so a relaunched app counts as
 * the old target; ignoring the window or the focused child; treating "could not read the
 * foreground" as a match; treating a target that recorded no focused child as a mismatch;
 * reactivating a target that is gone, or twice; pasting after a reactivation that brought
 * back the wrong window; pasting when nothing was captured.
 */

const slack: DeliveryTarget = {
  appId: 'slack',
  appName: 'general - Slack',
  processId: 501,
  windowHandle: 0x1234,
  windowTitle: 'general - Slack',
  focusHandle: 0x99,
};

function current(overrides: Partial<DeliveryTarget> = {}): DeliveryTarget {
  // A fresh object every time: identity is by value, never by reference.
  return { ...slack, ...overrides };
}

describe('targetMatches', () => {
  it('matches the same process, window and focused child', () => {
    expect(targetMatches(slack, current())).toBe(true);
  });

  it('never compares the title', () => {
    expect(targetMatches(slack, current({ windowTitle: 'general (3) - Slack' }))).toBe(true);
  });

  it('rejects another process of the same app', () => {
    expect(targetMatches(slack, current({ processId: 777 }))).toBe(false);
  });

  it('falls back to the app id when a process id is missing', () => {
    const noPid: DeliveryTarget = { appId: 'notepad' };
    expect(targetMatches(noPid, { appId: 'notepad', processId: 3 })).toBe(true);
    expect(targetMatches(noPid, { appId: 'wordpad', processId: 3 })).toBe(false);
    expect(targetMatches(noPid, { processId: 3 })).toBe(false);
  });

  it('rejects another window or another focused child', () => {
    expect(targetMatches(slack, current({ windowHandle: 0x5678 }))).toBe(false);
    expect(targetMatches(slack, current({ focusHandle: 0x42 }))).toBe(false);
  });

  it('rejects a focus that cannot report the window or child the target recorded', () => {
    expect(targetMatches(slack, current({ windowHandle: undefined }))).toBe(false);
    expect(targetMatches(slack, current({ focusHandle: undefined }))).toBe(false);
  });

  it('skips the child comparison when the target recorded none', () => {
    const noChild = current({ focusHandle: undefined });
    expect(targetMatches(noChild, current({ focusHandle: 0x42 }))).toBe(true);
  });

  it('never matches an unreadable foreground or an unidentified target', () => {
    expect(targetMatches(slack, null)).toBe(false);
    expect(targetMatches(slack, undefined)).toBe(false);
    expect(isIdentified({ windowHandle: 1 })).toBe(false);
    expect(targetMatches({ windowHandle: 1 }, { windowHandle: 1 })).toBe(false);
  });
});

describe('checkTarget', () => {
  it('inserts when the target is still in front', () => {
    expect(checkTarget(slack, current(), true)).toEqual({ kind: 'insert' });
  });

  it('reactivates when focus moved to another app or inside the target', () => {
    const notepad: DeliveryTarget = { appId: 'notepad', processId: 900, windowHandle: 7 };
    expect(checkTarget(slack, notepad, true)).toEqual({ kind: 'reactivate' });
    expect(checkTarget(slack, current({ focusHandle: 0x42 }), true)).toEqual({ kind: 'reactivate' });
    expect(checkTarget(slack, null, true)).toEqual({ kind: 'reactivate' });
  });

  it('copies when the target is gone', () => {
    expect(checkTarget(slack, null, false)).toEqual({ kind: 'copyOnly', reason: 'targetGone' });
  });

  it('copies when nothing was captured', () => {
    expect(checkTarget(undefined, current(), true)).toEqual({ kind: 'copyOnly', reason: 'unknownTarget' });
    expect(checkTarget(null, current(), true)).toEqual({ kind: 'copyOnly', reason: 'unknownTarget' });
    expect(checkTarget({ windowHandle: 1 }, current(), true)).toEqual({ kind: 'copyOnly', reason: 'unknownTarget' });
  });

  it('inserts into a target in front even when the running probe says otherwise', () => {
    expect(checkTarget(slack, current(), false)).toEqual({ kind: 'insert' });
  });
});

describe('recheckTarget', () => {
  it('inserts when the target came back', () => {
    expect(recheckTarget(slack, current(), true)).toEqual({ kind: 'insert' });
  });

  it('copies when the reactivation was refused, even if the focus reads right', () => {
    expect(recheckTarget(slack, current(), false)).toEqual({ kind: 'copyOnly', reason: 'notRestored' });
  });

  it('copies when the wrong window or child came back, or nothing can be read', () => {
    expect(recheckTarget(slack, current({ windowHandle: 9 }), true)).toEqual({ kind: 'copyOnly', reason: 'notRestored' });
    expect(recheckTarget(slack, current({ focusHandle: 9 }), true)).toEqual({ kind: 'copyOnly', reason: 'notRestored' });
    expect(recheckTarget(slack, null, true)).toEqual({ kind: 'copyOnly', reason: 'notRestored' });
  });

  it('never asks to reactivate again', () => {
    for (const now of [null, current(), current({ windowHandle: 9 }), current({ processId: 3 })]) {
      for (const reactivated of [true, false]) {
        expect(recheckTarget(slack, now, reactivated).kind).not.toBe('reactivate');
      }
    }
  });

  it('copies without a target', () => {
    expect(recheckTarget(undefined, current(), true)).toEqual({ kind: 'copyOnly', reason: 'unknownTarget' });
  });
});

describe('insertionMethodFor', () => {
  it('pastes by default', () => {
    expect(insertionMethodFor('WindowsTerminal', [])).toBe('paste');
  });

  it('types only for the apps the user turned on, whatever the case or .exe', () => {
    const list = ['windowsterminal', 'putty'];
    expect(insertionMethodFor('WindowsTerminal.exe', list)).toBe('typeOut');
    expect(insertionMethodFor('PUTTY', list)).toBe('typeOut');
    expect(insertionMethodFor('slack', list)).toBe('paste');
    expect(insertionMethodFor('windowsterminal', ['WindowsTerminal.exe'])).toBe('typeOut');
  });

  it('pastes for an unknown app', () => {
    expect(insertionMethodFor(undefined, ['putty'])).toBe('paste');
    expect(insertionMethodFor('', [''])).toBe('paste');
  });
});

describe('type-out text', () => {
  const join = (chunks: number[][]): string => String.fromCharCode(...chunks.flat());

  it('covers the text exactly once, in order, within the batch size', () => {
    const text = 'Hallo Welt, '.repeat(9);
    const chunks = typeOutChunks(text);
    expect(chunks.every((chunk) => chunk.length > 0 && chunk.length <= 20)).toBe(true);
    expect(join(chunks)).toBe(text);
  });

  it('has no batches for empty text', () => {
    expect(typeOutChunks('')).toEqual([]);
  });

  it('never splits an emoji or a CRLF', () => {
    const emoji = `${'a'.repeat(19)}😀b`;
    const chunks = typeOutChunks(emoji);
    for (const chunk of chunks) {
      const last = chunk[chunk.length - 1]!;
      expect(last >= 0xd800 && last <= 0xdbff).toBe(false);
    }
    expect(join(chunks)).toBe(emoji);
    const crlf = `${'a'.repeat(19)}\r\nb`;
    const crlfChunks = typeOutChunks(crlf);
    expect(crlfChunks[0]![crlfChunks[0]!.length - 1]).not.toBe(0x0d);
    expect(join(crlfChunks)).toBe(crlf);
  });

  it('keeps Persian with a ZWNJ intact', () => {
    const text = 'می‌خواهم این متن را بنویسم و بعد آن را ارسال کنم';
    const chunks = typeOutChunks(text, 7);
    expect(chunks.every((chunk) => chunk.length <= 7)).toBe(true);
    expect(join(chunks)).toBe(text);
  });

  it('turns every line break into one CR, which Windows types as Enter', () => {
    expect(typeOutText('one\ntwo\r\nthree')).toBe('one\rtwo\rthree');
  });
});

describe('browsers and app ids', () => {
  it('recognises the browsers whose address bar may be read', () => {
    for (const name of ['chrome.exe', 'msedge', 'Brave.exe', 'firefox']) expect(isKnownBrowser(name)).toBe(true);
    expect(isKnownBrowser('slack')).toBe(false);
    expect(isKnownBrowser(undefined)).toBe(false);
    expect(KNOWN_BROWSERS.size).toBe(4);
  });

  it('normalises process names to app ids', () => {
    expect(appIdFor('  WindowsTerminal.EXE ')).toBe('windowsterminal');
    expect(appIdFor('')).toBeUndefined();
    expect(appIdFor(undefined)).toBeUndefined();
  });
});

describe('parseForegroundLine', () => {
  const US = '\u001f';

  it('reads handle, process, pid, focused child and title', () => {
    expect(parseForegroundLine(['4660', 'slack', '501', '153', 'general - Slack'].join(US))).toEqual({
      handle: 4660,
      processName: 'slack',
      processId: 501,
      focusHandle: 153,
      title: 'general - Slack',
    });
  });

  it('leaves out a pid or focus of zero', () => {
    const info = parseForegroundLine(['4660', 'notepad', '0', '0', 'Untitled'].join(US));
    expect(info).toEqual({ handle: 4660, processName: 'notepad', title: 'Untitled' });
  });

  it('keeps a title that contains the separator', () => {
    expect(parseForegroundLine(['1', 'x', '2', '3', 'a', 'b'].join(US))?.title).toBe('a b');
  });

  it('returns null for unreadable output', () => {
    expect(parseForegroundLine('')).toBeNull();
    expect(parseForegroundLine('garbage')).toBeNull();
  });
});
