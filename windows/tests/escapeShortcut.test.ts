import { describe, expect, it } from 'vitest';
import { escapeCancelsIn } from '../src/core/settings/escapeShortcut.js';

// Failure modes: Esc registered only while recording (cancel during transcription is
// documented but unreachable by keyboard); Esc left registered when idle or delivering
// (it would swallow the key in every other app, or in the app being pasted into).
describe('escapeCancelsIn', () => {
  it('is held while recording and while transcribing', () => {
    expect(escapeCancelsIn('recording')).toBe(true);
    expect(escapeCancelsIn('transcribing')).toBe(true);
  });

  it('is released when idle, delivering or in error', () => {
    expect(escapeCancelsIn('idle')).toBe(false);
    expect(escapeCancelsIn('delivering')).toBe(false);
    expect(escapeCancelsIn('error')).toBe(false);
  });
});
