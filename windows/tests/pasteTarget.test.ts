import { describe, expect, it } from 'vitest';
import { pasteLandsInOwnWindow } from '../src/core/delivery/pasteTarget.js';

/**
 * Whether a hotkey dictation is copied instead of pasted.
 *
 * Ways it can fail: refusing to paste because the user clicked another window or field
 * while it transcribed (the dictation must follow the cursor); pasting into Useful
 * Voice's own window after a stop from the dock; refusing to paste into a note the
 * dictation started in.
 */
describe('pasteLandsInOwnWindow', () => {
  it('pastes when another app is in front, wherever the dictation started', () => {
    expect(pasteLandsInOwnWindow(false, false)).toBe(false);
    expect(pasteLandsInOwnWindow(true, false)).toBe(false);
  });

  it('copies when our own window came to the front after starting elsewhere', () => {
    expect(pasteLandsInOwnWindow(false, true)).toBe(true);
  });

  it('pastes into our own window when the dictation started there', () => {
    expect(pasteLandsInOwnWindow(true, true)).toBe(false);
  });
});
