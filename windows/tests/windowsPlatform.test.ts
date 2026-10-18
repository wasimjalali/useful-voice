import { describe, expect, it } from 'vitest';
import {
  UNVERIFIABLE_PROCESSES,
  decideClipboardRestore,
  hasRestorableContent,
  hasUnrestorableFormat,
  isProbablyVerifiable,
  restoreSnapshotTo,
  type ClipboardContents,
  type ClipboardPort,
  type PasteObservation,
  type PasteTarget,
} from '../src/core/delivery/clipboardRestore.js';

/**
 * The delivery contract.
 *
 * `src/main/windowsPlatform.ts` cannot be imported here — it pulls in Electron, which
 * the test runner cannot load — so the decision it used to make inline now lives in
 * `src/core/delivery/clipboardRestore.ts` and is exercised directly, while the file
 * that touches the real clipboard keeps only the observing and the writing.
 *
 * The contract being pinned down: the transcript always survives. It is either pasted
 * (the keystroke went out; Ctrl+V never clears the clipboard, so the clipboard still
 * holding our text proves nothing) or left on the clipboard because the keystroke could
 * not be sent. The previous clipboard is put back ONLY when the target is verifiable,
 * focus stayed on it, the clipboard still holds exactly our text, and the snapshot is
 * complete and has something worth restoring.
 */

const notepad: PasteTarget = { processName: 'notepad.exe', handle: 0x1234 };
const terminal: PasteTarget = { processName: 'WindowsTerminal.exe', handle: 0x99 };

function clipboard(overrides: Partial<ClipboardContents> = {}): ClipboardContents {
  return { text: 'a paragraph the user had copied', html: '', rtf: '', incomplete: false, ...overrides };
}

/**
 * A paste that went out cleanly and may be restored over.
 *
 * `focusAfter` is a *different object with the same handle* on purpose: windows are
 * identified by handle, and an implementation that compared object identity or titles
 * would pass a test that reused the same object.
 */
function landedPaste(overrides: Partial<PasteObservation> = {}): PasteObservation {
  return {
    clipboard: clipboard(),
    target: notepad,
    pasteSent: true,
    focusAfter: { processName: 'notepad.exe', handle: 0x1234 },
    clipboardHoldsOurText: true,
    ...overrides,
  };
}

describe('isProbablyVerifiable', () => {
  it('accepts ordinary apps, with or without the .exe suffix', () => {
    expect(isProbablyVerifiable({ processName: 'notepad.exe', handle: 1 })).toBe(true);
    expect(isProbablyVerifiable({ processName: 'notepad', handle: 1 })).toBe(true);
    expect(isProbablyVerifiable({ processName: 'WINWORD.EXE', handle: 1 })).toBe(true);
    expect(isProbablyVerifiable({ processName: 'Notepad.Exe', handle: 1 })).toBe(true);
  });

  it('refuses terminals and editors whose text cannot be read', () => {
    expect(isProbablyVerifiable(terminal)).toBe(false);
    expect(isProbablyVerifiable({ processName: 'cmd.exe', handle: 1 })).toBe(false);
    expect(isProbablyVerifiable({ processName: 'Code', handle: 1 })).toBe(false);
  });

  it('refuses every process on the unverifiable list', () => {
    // Ties the list to the verdict, so adding a process to it cannot be forgotten by
    // the decision that reads it.
    expect(UNVERIFIABLE_PROCESSES.size).toBeGreaterThanOrEqual(15);
    for (const name of UNVERIFIABLE_PROCESSES) {
      expect(isProbablyVerifiable({ processName: `${name}.exe`, handle: 1 }), name).toBe(false);
    }
  });

  it('treats an unreadable window as unverifiable', () => {
    expect(isProbablyVerifiable(null)).toBe(false);
    expect(isProbablyVerifiable({ processName: '', handle: 1 })).toBe(false);
  });
});

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

describe('decideClipboardRestore', () => {
  // Failure cases first: every way the restore, or the claim of delivery, can go wrong.

  it('reports a keystroke that never went out as undelivered, and keeps the text', () => {
    const decision = decideClipboardRestore(landedPaste({ pasteSent: false }));
    expect(decision).toEqual({ delivered: false, restore: false, reason: 'paste-failed' });
  });

  it('says pasted when the clipboard still holds our text: Ctrl+V does not clear it', () => {
    // The old rule read this as "nothing consumed the paste". It is what every
    // successful paste looks like, and it told people to paste twice.
    const decision = decideClipboardRestore(landedPaste({ clipboardHoldsOurText: true }));
    expect(decision.delivered).toBe(true);
  });

  it('never overwrites a newer copy the person made while the paste settled', () => {
    const decision = decideClipboardRestore(landedPaste({ clipboardHoldsOurText: false }));
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'clipboard-changed' });
  });

  it('keeps the text on the clipboard for an unverifiable process, but still says pasted', () => {
    const decision = decideClipboardRestore(landedPaste({ target: terminal, focusAfter: terminal }));
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'unverifiable-target' });
  });

  it('keeps the text when the foreground window could not be read before pasting', () => {
    const decision = decideClipboardRestore(landedPaste({ target: null, focusAfter: null }));
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'unverifiable-target' });
  });

  it('keeps the text when focus moved while pasting', () => {
    const decision = decideClipboardRestore(
      landedPaste({ focusAfter: { processName: 'explorer.exe', handle: 0x777 } }),
    );
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'focus-moved' });
  });

  it('keeps the text when focus cannot be read after pasting', () => {
    // Unreadable is "cannot attribute", not "did not move".
    const decision = decideClipboardRestore(landedPaste({ focusAfter: null }));
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'focus-moved' });
  });

  it('keeps the text when the snapshot could not be captured completely', () => {
    // The clipboard held a file list or a proprietary format. Putting a partial copy
    // back would destroy the user's data.
    const decision = decideClipboardRestore(landedPaste({ clipboard: clipboard({ incomplete: true }) }));
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'snapshot-incomplete' });
  });

  it('keeps the text when the clipboard held nothing worth restoring', () => {
    const decision = decideClipboardRestore(landedPaste({ clipboard: clipboard({ text: '' }) }));
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'nothing-to-restore' });
  });

  it('keeps the text when the clipboard held only whitespace', () => {
    const decision = decideClipboardRestore(landedPaste({ clipboard: clipboard({ text: '  \r\n' }) }));
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'nothing-to-restore' });
  });

  it('restores the previous clipboard when every condition holds', () => {
    const decision = decideClipboardRestore(landedPaste());
    expect(decision).toEqual({ delivered: true, restore: true, reason: 'restored' });
  });
});

describe('the delivery contract holds for every combination of observations', () => {
  const clips: ClipboardContents[] = [
    clipboard(),
    clipboard({ text: '' }),
    clipboard({ text: '   ' }),
    clipboard({ incomplete: true }),
    clipboard({ text: '', html: '<p>doc</p>' }),
  ];
  const targets: Array<PasteTarget | null> = [notepad, terminal, null];
  const focuses: Array<PasteTarget | null> = [
    { processName: 'notepad.exe', handle: notepad.handle },
    { processName: 'notepad.exe', handle: 0x2222 },
    null,
  ];

  const all: PasteObservation[] = [];
  for (const clipboardState of clips) {
    for (const target of targets) {
      for (const focusAfter of focuses) {
        for (const pasteSent of [true, false]) {
          for (const clipboardHoldsOurText of [true, false]) {
            all.push({ clipboard: clipboardState, target, pasteSent, focusAfter, clipboardHoldsOurText });
          }
        }
      }
    }
  }

  it('covers the whole space', () => {
    expect(all).toHaveLength(clips.length * targets.length * focuses.length * 4);
  });

  it('only restores when every condition for it holds', () => {
    for (const observation of all) {
      const decision = decideClipboardRestore(observation);
      const context = JSON.stringify(observation);
      if (decision.restore) {
        expect(decision.delivered, context).toBe(true);
        expect(observation.pasteSent, context).toBe(true);
        expect(isProbablyVerifiable(observation.target), context).toBe(true);
        expect(observation.focusAfter?.handle, context).toBe(observation.target?.handle);
        expect(observation.clipboardHoldsOurText, context).toBe(true);
        expect(observation.clipboard.incomplete, context).toBe(false);
        expect(hasRestorableContent(observation.clipboard), context).toBe(true);
      }
    }
  });

  it('says delivered exactly when the keystroke went out', () => {
    for (const observation of all) {
      const decision = decideClipboardRestore(observation);
      expect(decision.delivered, JSON.stringify(observation)).toBe(observation.pasteSent);
    }
  });

  it('never leaves the text in neither place', () => {
    for (const observation of all) {
      const decision = decideClipboardRestore(observation);
      // The text is in the app (delivered) or still on the clipboard (no restore). A
      // decision that restored without delivering would lose it.
      expect(decision.delivered || !decision.restore, JSON.stringify(observation)).toBe(true);
      expect(decision.reason === 'restored', JSON.stringify(observation)).toBe(decision.restore);
    }
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
