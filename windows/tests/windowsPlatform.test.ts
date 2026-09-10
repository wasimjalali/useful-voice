import { describe, expect, it } from 'vitest';
import {
  UNVERIFIABLE_PROCESSES,
  decideClipboardRestore,
  hasRestorableContent,
  isProbablyVerifiable,
  type ClipboardContents,
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
 * The contract being pinned down: the transcript always survives. It is either proven
 * pasted, or left on the clipboard. The previous clipboard is put back ONLY when the
 * paste is attributable to the window it was aimed at and the snapshot was captured
 * completely; an unverifiable target deliberately keeps the text on the clipboard
 * rather than claiming a success that cannot be shown.
 */

const notepad: PasteTarget = { processName: 'notepad.exe', handle: 0x1234 };
const terminal: PasteTarget = { processName: 'WindowsTerminal.exe', handle: 0x99 };

function clipboard(overrides: Partial<ClipboardContents> = {}): ClipboardContents {
  return { text: 'a paragraph the user had copied', html: '', rtf: '', incomplete: false, ...overrides };
}

/**
 * A paste that provably landed.
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
    clipboardStillHoldsText: false,
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
  it('restores the previous clipboard when the paste is proven', () => {
    const decision = decideClipboardRestore(landedPaste());
    expect(decision).toEqual({ delivered: true, restore: true, reason: 'restored' });
  });

  it('refuses to restore into an unverifiable process', () => {
    const decision = decideClipboardRestore(landedPaste({ target: terminal, focusAfter: terminal }));
    expect(decision).toEqual({ delivered: false, restore: false, reason: 'unverifiable-target' });
  });

  it('refuses when the foreground window could not be read before pasting', () => {
    const decision = decideClipboardRestore(landedPaste({ target: null, focusAfter: null }));
    expect(decision).toEqual({ delivered: false, restore: false, reason: 'unverifiable-target' });
  });

  it('refuses when the snapshot could not be captured completely', () => {
    // The clipboard held a file list or a proprietary format. Putting a partial copy
    // back would destroy the user's data, so the dictation stays on the clipboard even
    // though the paste demonstrably landed.
    const decision = decideClipboardRestore(landedPaste({ clipboard: clipboard({ incomplete: true }) }));
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'snapshot-incomplete' });
  });

  it('refuses when the clipboard held nothing worth restoring', () => {
    const decision = decideClipboardRestore(landedPaste({ clipboard: clipboard({ text: '' }) }));
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'nothing-to-restore' });
  });

  it('refuses when the clipboard held only whitespace', () => {
    const decision = decideClipboardRestore(landedPaste({ clipboard: clipboard({ text: '  \r\n' }) }));
    expect(decision).toEqual({ delivered: true, restore: false, reason: 'nothing-to-restore' });
  });

  it('restores once the paste has consumed the clipboard', () => {
    // The observable that counts as proof: something ate our text.
    const decision = decideClipboardRestore(landedPaste({ clipboardStillHoldsText: false }));
    expect(decision.restore).toBe(true);
    expect(decision.delivered).toBe(true);
  });

  it('does not restore over text that is still on the clipboard', () => {
    // Nothing consumed the paste, so it very likely never landed: this is the exact
    // case that lost dictations on macOS, where the restore ran anyway.
    const decision = decideClipboardRestore(landedPaste({ clipboardStillHoldsText: true }));
    expect(decision).toEqual({ delivered: false, restore: false, reason: 'paste-not-consumed' });
  });

  it('refuses when focus moved while pasting', () => {
    const decision = decideClipboardRestore(
      landedPaste({ focusAfter: { processName: 'explorer.exe', handle: 0x777 } }),
    );
    expect(decision).toEqual({ delivered: false, restore: false, reason: 'focus-moved' });
  });

  it('refuses when focus cannot be read after pasting', () => {
    // Unreadable is "cannot attribute", not "did not move".
    const decision = decideClipboardRestore(landedPaste({ focusAfter: null }));
    expect(decision).toEqual({ delivered: false, restore: false, reason: 'focus-moved' });
  });

  it('refuses when the paste automation never ran', () => {
    const decision = decideClipboardRestore(
      landedPaste({ pasteSent: false, clipboardStillHoldsText: true }),
    );
    expect(decision).toEqual({ delivered: false, restore: false, reason: 'paste-failed' });
  });

  it('reports the paste as a failure when the clipboard was never touched', () => {
    // Same window, clipboard intact: the target's edit control probably was not
    // focused at all, so the app must not claim it pasted anything.
    const decision = decideClipboardRestore(landedPaste({ clipboardStillHoldsText: true }));
    expect(decision.delivered).toBe(false);
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
          for (const clipboardStillHoldsText of [true, false]) {
            all.push({ clipboard: clipboardState, target, pasteSent, focusAfter, clipboardStillHoldsText });
          }
        }
      }
    }
  }

  it('covers the whole space', () => {
    expect(all).toHaveLength(clips.length * targets.length * focuses.length * 4);
  });

  it('never restores a clipboard it could not attribute', () => {
    for (const observation of all) {
      const decision = decideClipboardRestore(observation);
      const context = JSON.stringify(observation);
      if (decision.restore) {
        // Restoring is only ever allowed on top of a proven paste.
        expect(decision.delivered, context).toBe(true);
        expect(observation.pasteSent, context).toBe(true);
        expect(observation.clipboard.incomplete, context).toBe(false);
        expect(hasRestorableContent(observation.clipboard), context).toBe(true);
        expect(observation.target, context).not.toBeNull();
      }
      // Claiming delivery without a paste that ran and was seen to be consumed would
      // report success for a keystroke that never happened.
      if (decision.delivered) {
        expect(observation.pasteSent, context).toBe(true);
        expect(observation.clipboardStillHoldsText, context).toBe(false);
      }
    }
  });

  it('never leaves the text in neither place', () => {
    for (const observation of all) {
      const decision = decideClipboardRestore(observation);
      // Either the paste is claimed (the text went into the app) or the restore is
      // refused (the text is still on the clipboard). A decision that claimed delivery
      // *and* restored, or refused both, would lose it.
      expect(decision.delivered || !decision.restore, JSON.stringify(observation)).toBe(true);
      expect(decision.reason === 'restored', JSON.stringify(observation)).toBe(decision.restore);
    }
  });
});
