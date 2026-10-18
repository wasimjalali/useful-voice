import { describe, expect, it } from 'vitest';
import { pasteTargetMoved } from '../src/core/delivery/pasteTarget.js';

/**
 * Whether a hotkey dictation may still be pasted where it started.
 *
 * Ways it can fail: pasting into the window in front at delivery when the user
 * stopped from the dock (Useful Voice itself) or clicked elsewhere; treating "could
 * not read the window" as "same window"; refusing to paste when the start window was
 * never known.
 */
describe('pasteTargetMoved', () => {
  it('is false when the same window is still in front', () => {
    expect(pasteTargetMoved(4242, { handle: 4242 })).toBe(false);
  });

  it('is true when another window is in front, for instance Useful Voice after a stop from the dock', () => {
    expect(pasteTargetMoved(4242, { handle: 7 })).toBe(true);
  });

  it('is true when the foreground cannot be read at delivery', () => {
    expect(pasteTargetMoved(4242, null)).toBe(true);
  });

  it('cannot say the target moved when the start window was never known', () => {
    expect(pasteTargetMoved(undefined, { handle: 7 })).toBe(false);
    expect(pasteTargetMoved(undefined, null)).toBe(false);
  });
});
