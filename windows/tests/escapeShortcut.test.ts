import { describe, expect, it } from 'vitest';
import { escapeCancelsIn } from '../src/core/settings/escapeShortcut.js';

// Failure modes: Esc left registered after the recording (an Esc meant for the user's app
// would discard a finished dictation) or when idle (it would swallow the key everywhere).
describe('escapeCancelsIn', () => {
  it('is held only while recording', () => {
    expect(escapeCancelsIn('recording')).toBe(true);
  });

  it('is released when idle, transcribing, delivering or in error', () => {
    expect(escapeCancelsIn('idle')).toBe(false);
    expect(escapeCancelsIn('transcribing')).toBe(false);
    expect(escapeCancelsIn('delivering')).toBe(false);
    expect(escapeCancelsIn('error')).toBe(false);
  });
});
