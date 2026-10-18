import { describe, expect, it } from 'vitest';
import {
  MediaPausePolicy,
  TOUCH_TOLERANCE_MS,
  touchedSince,
  type HeldSession,
  type MediaEffects,
  type MediaSession,
} from '../src/core/media/mediaPausePolicy.js';

type Status = 'Playing' | 'Paused';
interface Fake {
  status: Status;
  position: number;
  updated: number;
}

/** A scripted desktop: sessions with a timeline, and what was asked of them, in order. */
function fakeMedia(initial: Record<string, Status>) {
  const sessions: Record<string, Fake> = {};
  for (const [id, status] of Object.entries(initial)) sessions[id] = { status, position: 10_000, updated: 1_000_000 };
  const calls: string[] = [];
  const gates: Array<() => void> = [];
  const state = { hold: false, failList: false, failPause: false, pauseLandsButThrows: false, failResume: false };
  const waitForGate = async (): Promise<void> => {
    if (!state.hold) return;
    await new Promise<void>((resolve) => gates.push(resolve));
  };
  const effects: MediaEffects = {
    async listPlaying() {
      calls.push('list');
      await waitForGate();
      if (state.failList) throw new Error('list failed');
      return Object.entries(sessions)
        .filter(([, s]) => s.status === 'Playing')
        .map(([id, s]): MediaSession => ({ id, position: s.position, updated: s.updated }));
    },
    async pause(ids) {
      calls.push(`pause:${ids.join(',')}`);
      await waitForGate();
      if (state.failPause) throw new Error('pause failed');
      const done: MediaSession[] = [];
      for (const id of ids) {
        const s = sessions[id];
        if (!s || s.status !== 'Playing') continue;
        s.status = 'Paused';
        done.push({ id, position: s.position, updated: s.updated });
      }
      // The pause landed, but the answer never arrives (a timeout, a slow await).
      if (state.pauseLandsButThrows) throw new Error('timed out after the pause landed');
      return done;
    },
    async resume(held: HeldSession[]) {
      calls.push(`resume:${held.map((h) => h.id).join(',')}`);
      await waitForGate();
      if (state.failResume) throw new Error('resume failed');
      // What the real script does: play only what is Paused and not touched since the pause.
      for (const h of held) {
        const s = sessions[h.id];
        if (s && s.status === 'Paused' && !touchedSince(h.settled, s)) s.status = 'Playing';
      }
    },
  };
  const status = (): Record<string, Status> => Object.fromEntries(Object.entries(sessions).map(([id, s]) => [id, s.status]));
  return {
    sessions,
    calls,
    effects,
    status,
    hold: () => {
      state.hold = true;
    },
    release: () => {
      state.hold = false;
      gates.splice(0).forEach((open) => open());
    },
    fail: (what: 'failList' | 'failPause' | 'pauseLandsButThrows' | 'failResume') => {
      state[what] = true;
    },
  };
}

function setup(initial: Record<string, Status>, enabled = true) {
  const media = fakeMedia(initial);
  const logs: string[] = [];
  const flags = { enabled };
  const policy = new MediaPausePolicy({
    effects: media.effects,
    enabled: () => flags.enabled,
    log: (message) => logs.push(message),
    // Short but real, so a press "inside the grace" is a real race against a real timer.
    graceMs: 30,
  });
  return { media, logs, flags, policy };
}

const resumes = (calls: string[]): string[] => calls.filter((call) => call.startsWith('resume'));
const pauses = (calls: string[]): string[] => calls.filter((call) => call.startsWith('pause'));
const tick = (ms = 0): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms));

describe('MediaPausePolicy', () => {
  it('pauses what is playing when a recording starts and plays it again when it ends', async () => {
    const { media, policy } = setup({ spotify: 'Playing', edge: 'Playing', podcast: 'Paused' });
    policy.recordingStarted();
    await policy.settled();
    expect(media.status()).toEqual({ spotify: 'Paused', edge: 'Paused', podcast: 'Paused' });
    policy.recordingEnded();
    await policy.settled();
    // The podcast was paused by the person, not by us: it stays paused.
    expect(media.status()).toEqual({ spotify: 'Playing', edge: 'Playing', podcast: 'Paused' });
    expect(media.calls).toEqual(['list', 'pause:spotify,edge', 'resume:spotify,edge']);
  });

  it('does not wait for the pause: recordingStarted returns at once', () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    media.hold();
    expect(policy.recordingStarted()).toBeUndefined();
    media.release();
  });

  it('does nothing when the setting is off', async () => {
    const { media, policy } = setup({ spotify: 'Playing' }, false);
    policy.recordingStarted();
    policy.recordingEnded();
    await policy.settled();
    expect(media.calls).toEqual([]);
    expect(media.status().spotify).toBe('Playing');
  });

  it('still plays what it paused when the setting is turned off mid-recording', async () => {
    const { media, flags, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    flags.enabled = false;
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Playing');
  });

  it('starts nothing when nothing was playing', async () => {
    const { media, policy } = setup({ spotify: 'Paused' });
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    await policy.settled();
    expect(media.calls).toEqual(['list']);
    expect(media.status().spotify).toBe('Paused');
  });

  it('resumes only what it paused, not sessions that started playing during the recording', async () => {
    const { media, policy } = setup({ spotify: 'Playing', other: 'Paused' });
    policy.recordingStarted();
    await policy.settled();
    media.sessions.other!.status = 'Playing';
    policy.recordingEnded();
    await policy.settled();
    expect(resumes(media.calls)).toEqual(['resume:spotify']);
  });

  it('resumes once per pause: an extra end does nothing', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    policy.recordingEnded();
    await policy.settled();
    expect(resumes(media.calls)).toEqual(['resume:spotify']);
  });
});

describe('a recording that ends before the pause', () => {
  it('pauses nothing when it ended before the pause got its turn', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    policy.recordingEnded();
    await policy.settled();
    expect(media.calls).toEqual([]);
    expect(media.status().spotify).toBe('Playing');
  });

  it('pauses nothing when it ended while the list was coming back (no late stutter)', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    media.hold();
    policy.recordingStarted();
    await tick();
    policy.recordingEnded();
    media.release();
    await policy.settled();
    expect(media.calls).toEqual(['list']);
    expect(media.status().spotify).toBe('Playing');
  });
});

describe('a pause whose answer is lost', () => {
  it('still resumes what landed, because it was held before the pause was sent', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    media.fail('pauseLandsButThrows');
    policy.recordingStarted();
    await policy.settled();
    expect(media.status().spotify).toBe('Paused');
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Playing');
    expect(logs).toEqual(['could not pause: timed out after the pause landed']);
  });

  it('leaves alone a session whose pause failed: it is still Playing', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    media.fail('failPause');
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Playing');
    expect(logs).toEqual(['could not pause: pause failed']);
  });

  it('logs a failed list and carries on', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    media.fail('failList');
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    await policy.settled();
    expect(logs).toEqual(['could not list the playing media: list failed']);
    expect(pauses(media.calls)).toEqual([]);
    expect(resumes(media.calls)).toEqual([]);
  });
});

describe('a session the person touched during the dictation', () => {
  it('is left alone when they played it again and paused it elsewhere (position moved on)', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.sessions.spotify!.position += TOUCH_TOLERANCE_MS + 5000;
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Paused');
  });

  it('is left alone when its timeline was updated after our pause', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.sessions.spotify!.updated += TOUCH_TOLERANCE_MS + 1;
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Paused');
  });

  it('is still resumed when the app only nudged its timeline within the tolerance', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.sessions.spotify!.position += 400;
    media.sessions.spotify!.updated += 400;
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Playing');
  });

  it('is resumed when the pause answer was lost, since there is nothing to compare against', async () => {
    expect(touchedSince(undefined, { position: 999_999, updated: 999_999_999 })).toBe(false);
  });

  it('only the touched one is left: the other session still resumes', async () => {
    const { media, policy } = setup({ spotify: 'Playing', edge: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.sessions.edge!.position += 60_000;
    policy.recordingEnded();
    await policy.settled();
    expect(media.status()).toEqual({ spotify: 'Playing', edge: 'Paused' });
  });
});

describe('back to back dictations', () => {
  it('keeps media paused when the next press lands inside the grace, and never pauses twice', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    await tick(5);
    policy.recordingStarted();
    await policy.settled();
    expect(media.status().spotify).toBe('Paused');
    expect(resumes(media.calls)).toEqual([]);
    expect(pauses(media.calls)).toEqual(['pause:spotify']);
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Playing');
    expect(resumes(media.calls)).toEqual(['resume:spotify']);
  });

  it('waits out the grace before it resumes', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    await tick(5);
    expect(media.status().spotify).toBe('Paused');
    await policy.settled();
    expect(media.status().spotify).toBe('Playing');
  });

  it('pauses again for a dictation that starts while a resume is already running', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.hold();
    policy.recordingEnded();
    await tick(60);
    policy.recordingStarted();
    media.release();
    await policy.settled();
    expect(media.status().spotify).toBe('Paused');
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Playing');
  });
});

describe('failures and quit', () => {
  it('logs a failed resume and drops those sessions in normal use', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.fail('failResume');
    policy.recordingEnded();
    await policy.settled();
    expect(logs).toEqual(['could not resume: resume failed']);
    policy.recordingStarted();
    policy.recordingEnded();
    await policy.settled();
    expect(resumes(media.calls)).toEqual(['resume:spotify']);
  });

  it('shutdown plays what is paused at once (no grace) and ignores everything after', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    expect(await policy.shutdown()).toBe(true);
    expect(media.status().spotify).toBe('Playing');
    policy.recordingStarted();
    await policy.settled();
    expect(pauses(media.calls)).toEqual(['pause:spotify']);
  });

  it('shutdown reports false and keeps the sessions held when the resume fails', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.fail('failResume');
    expect(await policy.shutdown()).toBe(false);
    expect(logs).toEqual(['could not resume: resume failed']);
  });

  it('shutdown reports false when the host does not answer within the budget', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.hold();
    expect(await policy.shutdown(30)).toBe(false);
    media.release();
  });

  it('never throws, even when the setting check does', async () => {
    const media = fakeMedia({ spotify: 'Playing' });
    const logs: string[] = [];
    const policy = new MediaPausePolicy({
      effects: media.effects,
      enabled: () => {
        throw new Error('settings broke');
      },
      log: (message) => logs.push(message),
      graceMs: 0,
    });
    expect(() => policy.recordingStarted()).not.toThrow();
    await policy.settled();
    expect(logs[0]).toContain('settings broke');
  });
});
