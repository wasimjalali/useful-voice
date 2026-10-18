import { describe, expect, it } from 'vitest';
import {
  hasRestorableContent,
  hasUnrestorableFormat,
  mayRestoreAfterCancel,
  sameClipboardText,
  restoreSnapshotTo,
  type ClipboardContents,
  type ClipboardPort,
} from '../src/core/delivery/clipboardRestore.js';

/**
 * The clipboard rules of delivery.
 *
 * `src/main/windowsPlatform.ts` cannot be imported here — it pulls in Electron, which
 * the test runner cannot load — so the decisions live in
 * `src/core/delivery/clipboardRestore.ts` and are exercised directly.
 *
 * The contract being pinned down: the transcript always survives. After a sent paste the
 * previous clipboard is NEVER put back (nothing proves the target consumed Ctrl+V, and a
 * target that stalls would paste the old clipboard); that rule is exercised through
 * `deliverText` in pasteFlow.test.ts. Before the paste, a cancel may put it back only
 * when the clipboard still holds exactly our text and the snapshot is complete and has
 * something worth restoring.
 */

function clipboard(overrides: Partial<ClipboardContents> = {}): ClipboardContents {
  return { text: 'a paragraph the user had copied', html: '', rtf: '', incomplete: false, ...overrides };
}

describe('hasRestorableContent', () => {
  it('keeps real clipboard content', () => {
    expect(hasRestorableContent(clipboard())).toBe(true);
    expect(hasRestorableContent(clipboard({ text: '', html: '<b>x</b>' }))).toBe(true);
    expect(hasRestorableContent(clipboard({ text: '', rtf: '{\\rtf1}' }))).toBe(true);
  });

  it('counts whitespace as nothing', () => {
    // The Windows keyboard automation caches a stray space or newline easily, and
    // putting that back would throw the dictation away for no user data at all.
    expect(hasRestorableContent(clipboard({ text: '' }))).toBe(false);
    expect(hasRestorableContent(clipboard({ text: '   ' }))).toBe(false);
    expect(hasRestorableContent(clipboard({ text: '\n\t ' }))).toBe(false);
  });
});

describe('mayRestoreAfterCancel', () => {
  it('restores a complete snapshot while the clipboard still holds our text', () => {
    expect(mayRestoreAfterCancel(clipboard(), true)).toBe(true);
  });

  it('leaves a newer copy alone', () => {
    // The person copied something after the dictation was written: it is theirs.
    expect(mayRestoreAfterCancel(clipboard(), false)).toBe(false);
  });

  it('leaves the clipboard alone when the snapshot is incomplete', () => {
    // An image or file list was on it: a partial copy would destroy data.
    expect(mayRestoreAfterCancel(clipboard({ incomplete: true }), true)).toBe(false);
  });

  it('leaves the clipboard alone when there was nothing worth restoring', () => {
    expect(mayRestoreAfterCancel(clipboard({ text: '' }), true)).toBe(false);
    expect(mayRestoreAfterCancel(clipboard({ text: '  \r\n' }), true)).toBe(false);
  });

  it('restores an HTML-only clipboard', () => {
    expect(mayRestoreAfterCancel(clipboard({ text: '', html: '<p>doc</p>' }), true)).toBe(true);
  });
});

describe('hasUnrestorableFormat', () => {
  it('marks a clipboard holding an image as unrestorable', () => {
    // An image is never written back, so a snapshot claiming complete would replace a
    // copied screenshot with its caption.
    expect(hasUnrestorableFormat(['text/plain', 'image/png'])).toBe(true);
    expect(hasUnrestorableFormat(['image/bmp'])).toBe(true);
  });

  it('marks file lists and proprietary types as unrestorable', () => {
    expect(hasUnrestorableFormat(['text/uri-list'])).toBe(true);
    expect(hasUnrestorableFormat(['text/plain', 'application/x-vendor'])).toBe(true);
  });

  it('accepts text, HTML and RTF only', () => {
    expect(hasUnrestorableFormat(['text/plain', 'text/html', 'text/rtf'])).toBe(false);
    expect(hasUnrestorableFormat(['Text/Plain;charset=utf-8'])).toBe(false);
    expect(hasUnrestorableFormat([])).toBe(false);
  });
});

describe('restoreSnapshotTo', () => {
  /** A clipboard that holds one text value and can be told to fail. */
  function fakeClipboard(options: { failFirstWrite?: boolean; failAllWrites?: boolean; garbleReadback?: boolean } = {}) {
    const state = { text: 'the dictation', writes: 0 };
    const port: ClipboardPort = {
      clear: () => {
        state.text = '';
      },
      write: (entry) => {
        state.writes += 1;
        if (options.failAllWrites || (options.failFirstWrite && state.writes === 1)) {
          throw new Error('clipboard busy');
        }
        state.text = entry.text ?? '';
      },
      readText: () => (options.garbleReadback && state.writes === 1 ? 'garbled' : state.text),
      readHTML: () => '',
      readRTF: () => '',
    };
    return { port, state };
  }

  it('puts the original back', () => {
    const { port, state } = fakeClipboard();
    expect(restoreSnapshotTo(port, clipboard(), 'the dictation')).toBe('restored');
    expect(state.text).toBe('a paragraph the user had copied');
  });

  it('puts the dictation back when the write fails after the clear', () => {
    // clear() has already thrown the dictation away: without the fallback the clipboard
    // would be empty and the dictation gone.
    const { port, state } = fakeClipboard({ failFirstWrite: true });
    expect(restoreSnapshotTo(port, clipboard(), 'the dictation')).toBe('failed-kept-dictation');
    expect(state.text).toBe('the dictation');
  });

  it('puts the dictation back when the readback does not match', () => {
    const { port, state } = fakeClipboard({ garbleReadback: true });
    expect(restoreSnapshotTo(port, clipboard(), 'the dictation')).toBe('failed-kept-dictation');
    expect(state.text).toBe('the dictation');
  });

  it('reports a clipboard it could not repair', () => {
    const { port } = fakeClipboard({ failAllWrites: true });
    expect(restoreSnapshotTo(port, clipboard(), 'the dictation')).toBe('failed-lost');
  });

  it('leaves the clipboard alone when nothing restorable was captured', () => {
    const { port, state } = fakeClipboard();
    expect(restoreSnapshotTo(port, clipboard({ text: '' }), 'the dictation')).toBe('nothing-to-restore');
    expect(state.text).toBe('the dictation');
  });
});

describe('sameClipboardText', () => {
  it('treats CRLF and LF alike, in either direction', () => {
    expect(sameClipboardText('one\r\ntwo', 'one\ntwo')).toBe(true);
    expect(sameClipboardText('one\ntwo', 'one\r\ntwo')).toBe(true);
  });

  it('tells a changed clipboard apart, including a trailing newline', () => {
    expect(sameClipboardText('one', 'one\n')).toBe(false);
    expect(sameClipboardText('something newer', 'one')).toBe(false);
  });
});
