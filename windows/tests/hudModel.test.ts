import { describe, expect, it } from 'vitest';
import {
  HUD_CANCELLED_MS,
  HUD_DONE_MS,
  HUD_LANGUAGE_MS,
  HUD_PERSISTENT_MS,
  HudModel,
  errorTitle,
  fixLabel,
  formatClock,
  formatWords,
  hudLabel,
  type HudClock,
  type HudFrame,
} from '../src/core/hudModel.js';
import type { DictationError, DictationErrorKind } from '../src/core/models.js';

/**
 * The HUD's view model: which view shows, for how long, and what a screen reader hears.
 * Driven with a fake clock so every timing rule (done 1.2 s, persistent 8 s, a language
 * confirmation covering a persistent view) is checked without waiting.
 */

class FakeClock implements HudClock {
  private time = 0;
  private nextId = 1;
  private timers = new Map<number, { at: number; callback: () => void }>();

  setTimeout(callback: () => void, ms: number): unknown {
    const id = this.nextId++;
    this.timers.set(id, { at: this.time + ms, callback });
    return id;
  }
  clearTimeout(handle: unknown): void {
    this.timers.delete(handle as number);
  }
  now(): number {
    return this.time;
  }
  get pending(): number {
    return this.timers.size;
  }
  advance(ms: number): void {
    const target = this.time + ms;
    for (;;) {
      const due = [...this.timers.entries()].filter(([, timer]) => timer.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      this.timers.delete(due[0]);
      this.time = due[1].at;
      due[1].callback();
    }
    this.time = target;
  }
}

function harness() {
  const clock = new FakeClock();
  const frames: Array<HudFrame | null> = [];
  const model = new HudModel((frame) => frames.push(frame), clock);
  return { clock, frames, model };
}

const offline: DictationError = { kind: 'offline', message: 'Could not reach Deepgram. Check your internet connection.', fix: 'retry' };

describe('HUD errors name the provider that failed', () => {
  it('names Gemini, ElevenLabs and Anthropic, never Deepgram, for their key and credit errors', () => {
    for (const provider of ['Gemini', 'ElevenLabs', 'Anthropic']) {
      expect(errorTitle({ kind: 'keyRejected', message: 'm', provider })).toBe(`${provider} key rejected`);
      expect(errorTitle({ kind: 'outOfCredits', message: 'm', provider })).toBe(`${provider} out of credits`);
    }
    expect(errorTitle({ kind: 'keyRejected', message: 'm' })).toBe('Deepgram key rejected');
  });
  it('shows a missing key or model message as it is', () => {
    expect(errorTitle({ kind: 'noProvider', message: 'Add your Gemini key in Settings.' })).toBe('Add your Gemini key in Settings.');
    expect(errorTitle({ kind: 'noProvider', message: 'Parakeet is not downloaded. Download it in Settings to use it.' })).toBe(
      'Parakeet is not downloaded. Download it in Settings to use it.',
    );
  });
  it('says Parakeet failed for a local failure and Timed out for a timeout', () => {
    expect(errorTitle({ kind: 'providerFailed', message: 'm', provider: 'Parakeet' })).toBe('Parakeet failed');
    expect(errorTitle({ kind: 'providerFailed', message: 'm', provider: 'Gemini' })).toBe('Transcription failed');
    expect(errorTitle({ kind: 'timedOut', message: 'm', provider: 'ElevenLabs' })).toBe('Timed out');
  });
});

describe('statuses', () => {
  it('maps each dictation state to its view', () => {
    const { model } = harness();
    model.status({ state: 'recording', elapsedSeconds: 3 });
    expect(model.frame).toMatchObject({ kind: 'recording', elapsedSeconds: 3 });
    model.status({ state: 'transcribing' });
    expect(model.frame?.kind).toBe('transcribing');
    model.status({ state: 'delivering', delivery: 'paste' });
    expect(model.frame?.kind).toBe('inserting');
    model.status({ state: 'delivering', delivery: 'copy' });
    expect(model.frame?.kind).toBe('saving');
  });

  it('gives every view a new sequence number so the window knows it is new', () => {
    const { model, frames } = harness();
    model.status({ state: 'recording' });
    model.status({ state: 'transcribing' });
    const seqs = frames.map((frame) => frame?.seq);
    expect(new Set(seqs).size).toBe(seqs.length);
    expect(seqs).toEqual([...seqs].sort((a, b) => (a ?? 0) - (b ?? 0)));
  });

  it('hides an in-flight view when idle arrives with no outcome (a dictation that ended without a word)', () => {
    const { model, frames } = harness();
    model.status({ state: 'recording' });
    model.status({ state: 'idle' });
    expect(model.frame).toBeNull();
    expect(frames.at(-1)).toBeNull();
  });

  it('keeps the done line when idle follows the outcome', () => {
    const { model } = harness();
    model.status({ state: 'delivering', delivery: 'paste' });
    model.outcome({ kind: 'delivered', words: 24, result: 'pasted' });
    model.status({ state: 'idle' });
    expect(model.frame).toMatchObject({ kind: 'done', words: 24, saved: false });
  });
});

describe('stale errors (WAS-54 item 5)', () => {
  it('replaces an error the moment the next recording starts', () => {
    const { model } = harness();
    model.status({ state: 'error', error: offline });
    expect(model.frame?.kind).toBe('error');
    model.status({ state: 'recording' });
    expect(model.frame?.kind).toBe('recording');
    expect(JSON.stringify(model.frame)).not.toContain('Deepgram');
  });

  it('replaces an error with the next dictation at every later stage too', () => {
    for (const next of [{ state: 'transcribing' }, { state: 'delivering', delivery: 'copy' }] as const) {
      const { model } = harness();
      model.status({ state: 'error', error: offline });
      model.status(next);
      expect(model.frame?.kind).not.toBe('error');
    }
  });

  it('replaces an error with a done line or a cancelled line', () => {
    const { model } = harness();
    model.status({ state: 'error', error: offline });
    model.outcome({ kind: 'delivered', words: 2, result: 'copied' });
    expect(model.frame).toMatchObject({ kind: 'done', saved: true });
    model.status({ state: 'error', error: offline });
    model.outcome({ kind: 'cancelled' });
    expect(model.frame?.kind).toBe('cancelled');
  });

  it('goes away on its own after 8 s, and a replaced error never hides the view that replaced it', () => {
    const { model, clock, frames } = harness();
    model.status({ state: 'error', error: offline });
    clock.advance(HUD_PERSISTENT_MS - 1);
    expect(model.frame?.kind).toBe('error');
    clock.advance(1);
    expect(model.frame).toBeNull();

    model.status({ state: 'error', error: offline });
    clock.advance(HUD_PERSISTENT_MS - 100);
    model.status({ state: 'recording' });
    // The old error's timer would have fired here; the recording must survive it.
    clock.advance(500);
    expect(model.frame?.kind).toBe('recording');
    expect(frames.at(-1)?.kind).toBe('recording');
  });

  it('is dismissed at once by the x or a fix button', () => {
    const { model } = harness();
    model.status({ state: 'error', error: offline });
    model.dismiss();
    expect(model.frame).toBeNull();
  });

  it('falls back to a generic provider error for a status with only a message', () => {
    const { model } = harness();
    model.status({ state: 'error', message: 'Something odd.' });
    expect(model.frame).toMatchObject({ kind: 'error', error: { kind: 'providerFailed', message: 'Something odd.' } });
  });
});

describe('outcomes and notice expiry (WAS-20)', () => {
  it('shows done for 1.2 s, then hides', () => {
    const { model, clock } = harness();
    model.outcome({ kind: 'delivered', words: 1, result: 'pasted' });
    expect(model.frame).toMatchObject({ kind: 'done', words: 1, saved: false });
    clock.advance(HUD_DONE_MS - 1);
    expect(model.frame?.kind).toBe('done');
    clock.advance(1);
    expect(model.frame).toBeNull();
  });

  it('marks a window or retry dictation as saved', () => {
    const { model } = harness();
    model.outcome({ kind: 'delivered', words: 5, result: 'copied' });
    expect(model.frame).toMatchObject({ kind: 'done', saved: true });
  });

  it('shows cancelled for 1.5 s', () => {
    const { model, clock } = harness();
    model.outcome({ kind: 'cancelled' });
    expect(model.frame?.kind).toBe('cancelled');
    clock.advance(HUD_CANCELLED_MS);
    expect(model.frame).toBeNull();
  });

  describe('the "Copied. Press Ctrl+V to paste" notice', () => {
    it('outlasts the idle status that follows it', () => {
      const { model, clock } = harness();
      model.status({ state: 'delivering', delivery: 'paste' });
      model.outcome({ kind: 'delivered', words: 9, result: 'copiedNotPasted' });
      model.status({ state: 'idle' });
      expect(model.frame?.kind).toBe('copied');
      clock.advance(HUD_PERSISTENT_MS - 1);
      expect(model.frame?.kind).toBe('copied');
    });

    it('clears after 8 s', () => {
      const { model, clock } = harness();
      model.outcome({ kind: 'delivered', words: 9, result: 'copiedNotPasted' });
      clock.advance(HUD_PERSISTENT_MS);
      expect(model.frame).toBeNull();
    });

    it('clears when the next dictation starts', () => {
      const { model } = harness();
      model.outcome({ kind: 'delivered', words: 9, result: 'copiedNotPasted' });
      model.status({ state: 'recording' });
      expect(model.frame?.kind).toBe('recording');
    });

    it('clears on the x', () => {
      const { model } = harness();
      model.outcome({ kind: 'delivered', words: 9, result: 'copiedNotPasted' });
      model.dismiss();
      expect(model.frame).toBeNull();
    });
  });
});

describe('telemetry', () => {
  it('updates the recording view in place, without a new sequence number', () => {
    const { model, frames } = harness();
    model.status({ state: 'recording', elapsedSeconds: 0 });
    const seq = model.frame?.seq;
    model.telemetry({ level: 0.2, elapsedSeconds: 7 });
    expect(model.frame).toMatchObject({ kind: 'recording', elapsedSeconds: 7, seq });
    expect(frames.at(-1)).toMatchObject({ elapsedSeconds: 7, seq });
  });

  it('emits nothing for an unchanged second, and nothing when no recording is showing', () => {
    const { model, frames } = harness();
    model.telemetry({ level: 0, elapsedSeconds: 1 });
    expect(frames).toHaveLength(0);
    model.status({ state: 'recording', elapsedSeconds: 1 });
    const count = frames.length;
    model.telemetry({ level: 0.5, elapsedSeconds: 1 });
    expect(frames).toHaveLength(count);
    model.status({ state: 'transcribing' });
    const after = frames.length;
    model.telemetry({ level: 0.5, elapsedSeconds: 9 });
    expect(frames).toHaveLength(after);
  });

  it('shows whichever auto-stop comes first as "stops in"', () => {
    const { model } = harness();
    model.status({ state: 'recording' });
    model.telemetry({ level: 0, elapsedSeconds: 1, silenceRemaining: 4 });
    expect(model.frame).toMatchObject({ stopsIn: 4 });
    model.telemetry({ level: 0, elapsedSeconds: 2, silenceRemaining: 4, maxRemaining: 2 });
    expect(model.frame).toMatchObject({ stopsIn: 2 });
    model.telemetry({ level: 0, elapsedSeconds: 3, maxRemaining: 1 });
    expect(model.frame).toMatchObject({ stopsIn: 1 });
  });

  it('removes the countdown once the speaker talks again', () => {
    const { model } = harness();
    model.status({ state: 'recording' });
    model.telemetry({ level: 0, elapsedSeconds: 1, silenceRemaining: 3 });
    expect(model.frame).toHaveProperty('stopsIn', 3);
    model.telemetry({ level: 0.4, elapsedSeconds: 2 });
    expect(model.frame).not.toHaveProperty('stopsIn');
  });
});

describe('language confirmation', () => {
  it('shows for 1 s and then hides when nothing was running', () => {
    const { model, clock } = harness();
    model.language('Deutsch');
    expect(model.frame).toMatchObject({ kind: 'language', name: 'Deutsch' });
    clock.advance(HUD_LANGUAGE_MS);
    expect(model.frame).toBeNull();
  });

  it('covers a recording and then gives it back', () => {
    const { model, clock } = harness();
    model.status({ state: 'recording', elapsedSeconds: 4 });
    model.language('Deutsch');
    expect(model.frame?.kind).toBe('language');
    model.telemetry({ level: 0, elapsedSeconds: 5 });
    clock.advance(HUD_LANGUAGE_MS);
    expect(model.frame).toMatchObject({ kind: 'recording', elapsedSeconds: 5 });
  });

  it('does not destroy a persistent error: it returns with only the time it had left', () => {
    const { model, clock } = harness();
    model.status({ state: 'error', error: offline });
    clock.advance(3000);
    model.language('Deutsch');
    clock.advance(HUD_LANGUAGE_MS);
    expect(model.frame?.kind).toBe('error');
    // 8 s from the start, not 8 s from the return.
    clock.advance(HUD_PERSISTENT_MS - 3000 - HUD_LANGUAGE_MS - 1);
    expect(model.frame?.kind).toBe('error');
    clock.advance(1);
    expect(model.frame).toBeNull();
  });

  it('stays hidden when the covered error ran out while it was covered', () => {
    const { model, clock } = harness();
    model.status({ state: 'error', error: offline });
    clock.advance(HUD_PERSISTENT_MS - 200);
    model.language('Deutsch');
    clock.advance(HUD_LANGUAGE_MS);
    expect(model.frame).toBeNull();
  });
});

describe('words', () => {
  it('formats the clock', () => {
    expect(formatClock(0)).toBe('0:00');
    expect(formatClock(12.9)).toBe('0:12');
    expect(formatClock(65)).toBe('1:05');
    expect(formatClock(-3)).toBe('0:00');
  });

  it('formats word counts with the singular and the German grouping', () => {
    expect(formatWords(1)).toBe('1 word');
    expect(formatWords(24)).toBe('24 words');
    expect(formatWords(1240)).toBe('1.240 words');
  });

  it('labels every view for the accessible name and the announcement', () => {
    expect(hudLabel({ kind: 'recording', elapsedSeconds: 12 })).toBe('Recording, 0:12');
    expect(hudLabel({ kind: 'transcribing' })).toBe('Transcribing');
    expect(hudLabel({ kind: 'inserting' })).toBe('Inserting');
    expect(hudLabel({ kind: 'saving' })).toBe('Saving');
    expect(hudLabel({ kind: 'done', words: 24, saved: false })).toBe('Inserted, 24 words');
    expect(hudLabel({ kind: 'done', words: 1, saved: true })).toBe('Saved and copied, 1 word');
    expect(hudLabel({ kind: 'copied' })).toBe('Copied. Press Ctrl+V to paste');
    expect(hudLabel({ kind: 'cancelled' })).toBe('Cancelled');
    expect(hudLabel({ kind: 'language', name: 'Deutsch' })).toBe('Language: Deutsch');
    expect(hudLabel({ kind: 'error', error: offline })).toBe('No connection');
  });

  it('keeps the ticking timer out of the label other than by the elapsed time it carries', () => {
    // The label is what a screen reader reads when the HUD is explored; the timer element
    // itself is aria-hidden in the window (checked in the E2E suite).
    expect(hudLabel({ kind: 'recording', elapsedSeconds: 0, stopsIn: 3 })).toBe('Recording, 0:00');
  });
});

describe('error kinds and their fix actions', () => {
  const kinds: Array<[DictationErrorKind, DictationError['fix'] | undefined, string | null]> = [
    ['micUnavailable', 'openMicrophoneSettings', 'Open settings'],
    ['stopFailed', undefined, null],
    ['noSpeech', undefined, null],
    ['tooShort', undefined, null],
    ['noProvider', 'openEngineSettings', 'Open settings'],
    ['keyRejected', 'openEngineSettings', 'Open settings'],
    ['outOfCredits', 'openEngineSettings', 'Open settings'],
    ['offline', 'retry', 'Retry last recording'],
    ['timedOut', 'retry', 'Retry last recording'],
    ['providerFailed', 'retry', 'Retry last recording'],
    ['deliveryFailed', undefined, null],
    ['saveFailed', undefined, null],
  ];

  it.each(kinds)('%s has a title, and the fix button %s reads %s', (kind, fix, label) => {
    const error: DictationError = fix ? { kind, message: 'm', fix } : { kind, message: 'm' };
    expect(errorTitle(error).length).toBeGreaterThan(0);
    expect(fixLabel(error)).toBe(label);
  });

  it('gives every kind a distinct title', () => {
    const titles = kinds.map(([kind]) => errorTitle({ kind, message: 'm' }));
    expect(new Set(titles).size).toBe(titles.length);
  });
});
