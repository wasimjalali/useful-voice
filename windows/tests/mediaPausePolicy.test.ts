import { describe, expect, it } from 'vitest';
import {
  MediaPausePolicy,
  TOUCH_TOLERANCE_MS,
  resumeVerdict,
  touchedSince,
  type HeldSession,
  type MediaEffects,
  type MediaSession,
  type PauseResult,
  type ResumeResult,
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
  const state = {
    hold: false,
    failList: false,
    failPause: false,
    pauseLandsButThrows: false,
    failResume: false,
    refusePause: false,
    refuseResume: false,
    /** The pause answer leaves this id out, as if the session had been paused by the person first. */
    omitFromAnswer: '',
    /** Whether the app publishes a timeline update when it pauses (many browsers publish none). */
    publishesTimeline: true,
  };
  const clock = { now: 5_000_000 };
  const quits: string[] = [];
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
      const result: PauseResult = { confirmed: [], refused: [] };
      for (const id of ids) {
        const s = sessions[id];
        if (!s || s.status !== 'Playing') continue;
        if (state.refusePause) {
          result.refused.push(id);
          continue;
        }
        s.status = 'Paused';
        if (state.publishesTimeline) s.updated = clock.now;
        if (id !== state.omitFromAnswer) result.confirmed.push({ id, position: s.position, updated: s.updated });
      }
      // The pause landed, but the answer never arrives (a timeout, a slow await).
      if (state.pauseLandsButThrows) throw new Error('timed out after the pause landed');
      return result;
    },
    async resume(held: HeldSession[]) {
      calls.push(`resume:${held.map((h) => h.id).join(',')}`);
      await waitForGate();
      if (state.failResume) throw new Error('resume failed');
      // What the real script does: play only what is Paused and passes the verdict.
      const result: ResumeResult = { refused: [], touched: [], unconfirmed: [] };
      for (const h of held) {
        const s = sessions[h.id];
        if (!s || s.status !== 'Paused') continue;
        const verdict = resumeVerdict(h, s);
        if (verdict === 'touched') result.touched.push(h.id);
        else if (verdict === 'unconfirmed') result.unconfirmed.push(h.id);
        else if (state.refuseResume) result.refused.push(h.id);
        else s.status = 'Playing';
      }
      return result;
    },
    beginQuit() {
      quits.push('quit');
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
    fail: (what: 'failList' | 'failPause' | 'pauseLandsButThrows' | 'failResume' | 'refusePause' | 'refuseResume') => {
      state[what] = true;
    },
    omitFromAnswer: (id: string) => {
      state.omitFromAnswer = id;
    },
    noTimeline: () => {
      state.publishesTimeline = false;
    },
    clock,
    quits,
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
    now: () => media.clock.now,
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

describe('only a pause that was confirmed is undone', () => {
  it('leaves alone and logs a session Windows refused to pause, and never tries to play it', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    media.fail('refusePause');
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    await policy.settled();
    expect(logs).toEqual(['Could not pause spotify: Windows refused the request']);
    expect(resumes(media.calls)).toEqual([]);
    expect(media.status().spotify).toBe('Playing');
  });

  it('leaves alone a session the answer does not confirm (the person paused it first), and logs it', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing', edge: 'Playing' });
    media.omitFromAnswer('edge');
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    await policy.settled();
    expect(resumes(media.calls)).toEqual(['resume:spotify']);
    expect(logs).toEqual(['Left edge alone: its pause was not confirmed']);
  });

  it('counts a lost answer as ours when the app updated its timeline just after our request', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    media.fail('pauseLandsButThrows');
    policy.recordingStarted();
    await policy.settled();
    media.clock.now += 400;
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Playing');
    expect(logs).toEqual(['could not pause: timed out after the pause landed']);
  });

  it('leaves a lost-answer session paused when its timeline cannot show the pause was ours, and logs it', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    media.noTimeline();
    media.fail('pauseLandsButThrows');
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Paused');
    expect(logs).toEqual(['could not pause: timed out after the pause landed', 'Left spotify paused: its pause was never confirmed']);
  });

  it('does not take as ours a timeline update that came long after the request', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    media.fail('pauseLandsButThrows');
    media.noTimeline();
    policy.recordingStarted();
    await policy.settled();
    media.sessions.spotify!.updated = media.clock.now + TOUCH_TOLERANCE_MS + 1;
    policy.recordingEnded();
    await policy.settled();
    expect(media.status().spotify).toBe('Paused');
  });

  it('logs a play that Windows refused', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.fail('refuseResume');
    policy.recordingEnded();
    await policy.settled();
    expect(logs).toEqual(['Could not resume spotify: Windows refused the request']);
  });

  it('logs a session left paused because the person moved it', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.sessions.spotify!.position += 60_000;
    policy.recordingEnded();
    await policy.settled();
    expect(logs).toEqual(['Left spotify paused: it was moved after the pause']);
  });
});

describe('resumeVerdict', () => {
  const now = { position: 10_000, updated: 5_000_100 };
  it('plays a confirmed session with no reading to compare (quit cut the settle short)', () => {
    expect(resumeVerdict({ id: 'a', confirmed: true, requestedAt: 5_000_000 }, now)).toBe('play');
  });
  it('calls an unconfirmed session ours only when updated at or after the request, within the tolerance', () => {
    const held = { id: 'a', confirmed: false, requestedAt: 5_000_000 };
    expect(resumeVerdict(held, { position: 0, updated: 5_000_000 })).toBe('play');
    expect(resumeVerdict(held, { position: 0, updated: 5_000_000 + TOUCH_TOLERANCE_MS })).toBe('play');
    expect(resumeVerdict(held, { position: 0, updated: 4_999_999 })).toBe('unconfirmed');
    expect(resumeVerdict(held, { position: 0, updated: 5_000_000 + TOUCH_TOLERANCE_MS + 1 })).toBe('unconfirmed');
  });
});

describe('quit', () => {
  it('tells the effects once, so they can cut their waits short', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    await policy.shutdown();
    await policy.shutdown();
    expect(media.quits).toEqual(['quit']);
  });

  it('is idempotent: a second shutdown shares the first and resumes nothing twice', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    const [first, second] = await Promise.all([policy.shutdown(), policy.shutdown()]);
    expect(first).toBe(true);
    expect(second).toBe(true);
    expect(resumes(media.calls)).toEqual(['resume:spotify']);
  });

  it('starts no pause once the quit began, even if the list was still coming back', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    media.hold();
    policy.recordingStarted();
    await tick();
    const quitting = policy.shutdown(500);
    media.release();
    expect(await quitting).toBe(true);
    expect(pauses(media.calls)).toEqual([]);
    expect(media.status().spotify).toBe('Playing');
  });
});
