import { describe, expect, it } from 'vitest';
import { pasteLandsInOwnWindow } from '../src/core/delivery/pasteTarget.js';

/**
 * Whether a hotkey dictation is copied instead of pasted.
 *
 * Ways it can fail: refusing to paste because the user clicked another window or field
 * while it transcribed (the dictation must follow the cursor); pasting into Useful
 * Voice's own window after a stop from the dock; refusing to paste into a note the
 * dictation started in; refusing to paste when the foreground could not be read.
 */
describe('pasteLandsInOwnWindow', () => {
  const own = [100, 200];

  it('pastes into the window the dictation started in', () => {
    expect(pasteLandsInOwnWindow(4242, { handle: 4242 }, own)).toBe(false);
  });

  it('pastes into another window the user moved to', () => {
    expect(pasteLandsInOwnWindow(4242, { handle: 7 }, own)).toBe(false);
  });

  it('copies when our own window came to the front after starting elsewhere', () => {
    expect(pasteLandsInOwnWindow(4242, { handle: 100 }, own)).toBe(true);
    expect(pasteLandsInOwnWindow(undefined, { handle: 200 }, own)).toBe(true);
  });

  it('pastes into our own window when the dictation started there', () => {
    expect(pasteLandsInOwnWindow(100, { handle: 100 }, own)).toBe(false);
  });

  it('pastes when the foreground window could not be read', () => {
    expect(pasteLandsInOwnWindow(4242, null, own)).toBe(false);
    expect(pasteLandsInOwnWindow(undefined, null, own)).toBe(false);
  });
});
