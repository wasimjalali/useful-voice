import { describe, expect, it, vi } from 'vitest';

// The announcer asks Electron only whether a screen reader is attached; the rest is pure.
vi.mock('electron', () => ({ app: { isAccessibilitySupportEnabled: () => false } }));

const { Announcer } = await import('../src/main/announce.js');
import type { HudView } from '../src/core/hudModel.js';
import type { DictationError } from '../src/core/models.js';

/**
 * What a screen reader is told for each HUD state (WAS-53), and that the recording timer
 * is never spoken. The text is decided here in main; a live region in a window speaks it.
 */

function harness() {
  const spoken: Array<{ text: string; urgency: 'polite' | 'assertive' }> = [];
  const announcer = new Announcer((text, urgency) => spoken.push({ text, urgency }));
  return { announcer, spoken };
}

const keyRejected: DictationError = { kind: 'keyRejected', message: 'Deepgram rejected your API key. Check it in Settings.', fix: 'openEngineSettings' };

describe('announcement text per HUD state', () => {
  const cases: Array<[string, HudView, string, 'polite' | 'assertive']> = [
    ['recording', { kind: 'recording', elapsedSeconds: 0 }, 'Recording', 'polite'],
    ['recording with a countdown', { kind: 'recording', elapsedSeconds: 55, stopsIn: 5 }, 'Stops in 5 seconds', 'polite'],
    ['transcribing', { kind: 'transcribing' }, 'Transcribing', 'polite'],
    ['inserting', { kind: 'inserting' }, 'Inserting', 'polite'],
    ['saving', { kind: 'saving' }, 'Saving', 'polite'],
    ['inserted', { kind: 'done', words: 24, saved: false }, 'Inserted, 24 words', 'polite'],
    ['saved and copied', { kind: 'done', words: 1, saved: true }, 'Saved and copied, 1 word', 'polite'],
    ['copied', { kind: 'copied' }, 'Copied. Press Ctrl+V to paste', 'polite'],
    ['cancelled', { kind: 'cancelled' }, 'Cancelled', 'polite'],
    ['language', { kind: 'language', name: 'Deutsch' }, 'Language: Deutsch', 'polite'],
    [
      'an error with a fix',
      { kind: 'error', error: keyRejected },
      'Deepgram rejected your API key. Check it in Settings. Open settings available.',
      'assertive',
    ],
    ['an error with no fix', { kind: 'error', error: { kind: 'noSpeech', message: 'No speech detected.' } }, 'No speech detected.', 'assertive'],
  ];

  it.each(cases)('says the right thing for %s', (_name, view, text, urgency) => {
    const { announcer, spoken } = harness();
    announcer.hud(view);
    expect(spoken).toEqual([{ text, urgency }]);
  });

  it('says nothing for a hidden HUD', () => {
    const { announcer, spoken } = harness();
    announcer.hud(null);
    expect(spoken).toEqual([]);
  });

  it('puts the fix in the spoken error, not only the short title', () => {
    const { announcer, spoken } = harness();
    announcer.hud({ kind: 'error', error: { kind: 'offline', message: 'Could not reach Deepgram.', fix: 'retry' } });
    expect(spoken[0]?.text).toBe('Could not reach Deepgram. Retry last recording available.');
  });
});

describe('the recording timer is not announced', () => {
  it('speaks "Recording" once however many seconds tick by', () => {
    const { announcer, spoken } = harness();
    for (let second = 0; second < 30; second += 1) announcer.hud({ kind: 'recording', elapsedSeconds: second });
    expect(spoken).toEqual([{ text: 'Recording', urgency: 'polite' }]);
  });

  it('speaks the countdown when it first appears, and not on every tick after that', () => {
    const { announcer, spoken } = harness();
    announcer.hud({ kind: 'recording', elapsedSeconds: 50 });
    announcer.hud({ kind: 'recording', elapsedSeconds: 55, stopsIn: 5 });
    announcer.hud({ kind: 'recording', elapsedSeconds: 56, stopsIn: 4 });
    announcer.hud({ kind: 'recording', elapsedSeconds: 57, stopsIn: 3 });
    expect(spoken.map((line) => line.text)).toEqual(['Recording', 'Stops in 5 seconds']);
  });

  it('never carries the clock in anything it says', () => {
    const { announcer, spoken } = harness();
    announcer.hud({ kind: 'recording', elapsedSeconds: 12 });
    announcer.hud({ kind: 'recording', elapsedSeconds: 13, stopsIn: 2 });
    for (const line of spoken) expect(line.text).not.toMatch(/\d:\d\d/);
  });
});

describe('repeats', () => {
  it('does not repeat the same line for the same view', () => {
    const { announcer, spoken } = harness();
    announcer.hud({ kind: 'transcribing' });
    announcer.hud({ kind: 'transcribing' });
    expect(spoken).toHaveLength(1);
  });

  it('speaks the same view again after the HUD went away in between', () => {
    const { announcer, spoken } = harness();
    announcer.hud({ kind: 'cancelled' });
    announcer.hud(null);
    announcer.hud({ kind: 'cancelled' });
    expect(spoken.map((line) => line.text)).toEqual(['Cancelled', 'Cancelled']);
  });

  it('speaks a new error even when it has the same kind as the last', () => {
    const { announcer, spoken } = harness();
    announcer.hud({ kind: 'error', error: { kind: 'offline', message: 'Could not reach Deepgram.' } });
    announcer.hud({ kind: 'error', error: { kind: 'offline', message: 'Could not reach Deepgram again.' } });
    expect(spoken).toHaveLength(2);
  });

  it('walks a whole dictation in order', () => {
    const { announcer, spoken } = harness();
    announcer.hud({ kind: 'recording', elapsedSeconds: 0 });
    announcer.hud({ kind: 'recording', elapsedSeconds: 1 });
    announcer.hud({ kind: 'transcribing' });
    announcer.hud({ kind: 'saving' });
    announcer.hud({ kind: 'done', words: 3, saved: true });
    announcer.hud(null);
    expect(spoken.map((line) => line.text)).toEqual(['Recording', 'Transcribing', 'Saving', 'Saved and copied, 3 words']);
  });
});
