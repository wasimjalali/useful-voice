import { describe, expect, it } from 'vitest';
import {
  KNOWN_BROWSERS,
  appIdFor,
  checkTarget,
  insertionMethodFor,
  isIdentified,
  isKnownBrowser,
  pageChanged,
  recheckTarget,
  targetMatches,
  typeOutChunks,
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
 * back the wrong window; pasting when nothing was captured; pasting into the right tab
 * after it navigated to another page, or reactivating to "fix" that; treating a
 * fragment-only change as another page; matching a reused pid that now belongs to
 * another app; typing out text with a line break (each one is an Enter key).
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

  it('rejects a reused pid that now belongs to another app', () => {
    expect(targetMatches(slack, current({ appId: 'notepad' }))).toBe(false);
    // A side that can't report the app id still matches on the pid.
    expect(targetMatches(slack, current({ appId: undefined }))).toBe(true);
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

describe('page address', () => {
  const page = (browserUrl?: string): DeliveryTarget => ({
    appId: 'chrome',
    processId: 900,
    windowHandle: 0x50,
    focusHandle: 0x51,
    browserUrl,
  });

  it('matches the same page', () => {
    const target = page('https://mail.google.com/mail/u/0/?tab=rm');
    expect(targetMatches(target, page('https://mail.google.com/mail/u/0/?tab=rm'))).toBe(true);
    expect(checkTarget(target, page('https://mail.google.com/mail/u/0/?tab=rm'), true)).toEqual({ kind: 'insert' });
  });

  it('copies without reactivating when the window shows another page', () => {
    const target = page('https://mail.google.com/mail/u/0/#inbox');
    const now = page('https://news.ycombinator.com/');
    expect(targetMatches(target, now)).toBe(false);
    expect(checkTarget(target, now, true)).toEqual({ kind: 'copyOnly', reason: 'pageChanged' });
  });

  it('treats another query as another page', () => {
    expect(pageChanged(page('https://example.com/search?q=a'), page('https://example.com/search?q=b'))).toBe(true);
  });

  it('treats a fragment-only change as the same page', () => {
    const target = page('https://mail.google.com/mail/u/0/#inbox');
    const now = page('https://mail.google.com/mail/u/0/#inbox/FMfcgz');
    expect(targetMatches(target, now)).toBe(true);
    expect(checkTarget(target, now, true)).toEqual({ kind: 'insert' });
  });

  it('ignores scheme and host case, not path case', () => {
    expect(targetMatches(page('HTTPS://Example.COM/a'), page('https://example.com/a'))).toBe(true);
    expect(pageChanged(page('https://example.com/A'), page('https://example.com/a'))).toBe(true);
  });

  it('does not compare when one side has no web address', () => {
    expect(targetMatches(page('https://example.com/a'), page(undefined))).toBe(true);
    expect(targetMatches(page(undefined), page('https://example.com/a'))).toBe(true);
    expect(targetMatches(page('file:///C:/a.pdf'), page('https://example.com/a'))).toBe(true);
    expect(targetMatches(page('edge://settings'), page('https://example.com/a'))).toBe(true);
    expect(targetMatches(page('not a url'), page('https://example.com/a'))).toBe(true);
  });

  it('copies when the restored window shows another page', () => {
    const target = page('https://example.com/compose');
    expect(recheckTarget(target, page('https://example.com/other'), true)).toEqual({
      kind: 'copyOnly',
      reason: 'pageChanged',
    });
    expect(recheckTarget(target, page('https://example.com/compose#x'), true)).toEqual({ kind: 'insert' });
  });

  it('still reactivates when another app is in front, whatever its page', () => {
    const other: DeliveryTarget = { appId: 'notepad', processId: 77, browserUrl: 'https://x.com/' };
    expect(checkTarget(page('https://example.com/a'), other, true)).toEqual({ kind: 'reactivate' });
  });
});

describe('insertionMethodFor', () => {
  it('pastes by default', () => {
    expect(insertionMethodFor('WindowsTerminal', [], 'ls -la')).toBe('paste');
  });

  it('types only for the apps the user turned on, whatever the case or .exe', () => {
    const list = ['windowsterminal', 'putty'];
    expect(insertionMethodFor('WindowsTerminal.exe', list, 'ls -la')).toBe('typeOut');
    expect(insertionMethodFor('PUTTY', list, 'ls -la')).toBe('typeOut');
    expect(insertionMethodFor('slack', list, 'ls -la')).toBe('paste');
    expect(insertionMethodFor('windowsterminal', ['WindowsTerminal.exe'], 'ls -la')).toBe('typeOut');
  });

  it('copies text with a line break for a type-out app, and still pastes it elsewhere', () => {
    for (const text of ['one\ntwo', 'one\r\ntwo', 'one\rtwo', 'end\n', 'a\u2028b', 'a\u2029b', 'a\u0085b']) {
      expect(insertionMethodFor('putty', ['putty'], text)).toBe('copyOnly');
      expect(insertionMethodFor('notepad', ['putty'], text)).toBe('paste');
      expect(insertionMethodFor(undefined, ['putty'], text)).toBe('paste');
    }
    expect(insertionMethodFor('putty', ['putty'], 'one two')).toBe('typeOut');
  });

  it('pastes for an unknown app', () => {
    expect(insertionMethodFor(undefined, ['putty'], 'ls -la')).toBe('paste');
    expect(insertionMethodFor('', [''], 'ls -la')).toBe('paste');
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
