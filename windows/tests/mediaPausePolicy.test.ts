import { describe, expect, it } from 'vitest';
import { MediaPausePolicy, type MediaEffects } from '../src/core/media/mediaPausePolicy.js';

/** A scripted desktop: which sessions play, and what was asked of them, in order. */
function fakeMedia(initial: Record<string, 'Playing' | 'Paused'>) {
  const status = { ...initial };
  const calls: string[] = [];
  const gates: Array<() => void> = [];
  const state = { hold: false, failPause: false, failResume: false };
  const waitForGate = async (): Promise<void> => {
    if (!state.hold) return;
    await new Promise<void>((resolve) => gates.push(resolve));
  };
  const effects: MediaEffects = {
    async pausePlaying() {
      calls.push('pause');
      await waitForGate();
      if (state.failPause) throw new Error('pause failed');
      const ids = Object.keys(status).filter((id) => status[id] === 'Playing');
      for (const id of ids) status[id] = 'Paused';
      return ids;
    },
    async resume(ids) {
      calls.push(`resume:${ids.join(',')}`);
      await waitForGate();
      if (state.failResume) throw new Error('resume failed');
      // The real script plays only what is still paused.
      for (const id of ids) if (status[id] === 'Paused') status[id] = 'Playing';
    },
  };
  return {
    status,
    calls,
    effects,
    hold: () => {
      state.hold = true;
    },
    release: () => {
      state.hold = false;
      gates.splice(0).forEach((open) => open());
    },
    failPause: () => {
      state.failPause = true;
    },
    failResume: () => {
      state.failResume = true;
    },
  };
}

function setup(initial: Record<string, 'Playing' | 'Paused'>, enabled = true) {
  const media = fakeMedia(initial);
  const logs: string[] = [];
  const flags = { enabled };
  const policy = new MediaPausePolicy({
    effects: media.effects,
    enabled: () => flags.enabled,
    log: (message) => logs.push(message),
  });
  return { media, logs, flags, policy };
}

const resumes = (calls: string[]): string[] => calls.filter((call) => call.startsWith('resume'));

describe('MediaPausePolicy', () => {
  it('pauses what is playing when a recording starts and plays it again when it ends', async () => {
    const { media, policy } = setup({ spotify: 'Playing', edge: 'Playing', podcast: 'Paused' });
    policy.recordingStarted();
    await policy.settled();
    expect(media.status).toEqual({ spotify: 'Paused', edge: 'Paused', podcast: 'Paused' });
    policy.recordingEnded();
    await policy.settled();
    // The podcast was paused by the person, not by us: it stays paused.
    expect(media.status).toEqual({ spotify: 'Playing', edge: 'Playing', podcast: 'Paused' });
    expect(media.calls).toEqual(['pause', 'resume:spotify,edge']);
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
    expect(media.status.spotify).toBe('Playing');
  });

  it('still plays what it paused when the setting is turned off mid-recording', async () => {
    const { media, flags, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    flags.enabled = false;
    policy.recordingEnded();
    await policy.settled();
    expect(media.status.spotify).toBe('Playing');
  });

  it('starts nothing when nothing was playing', async () => {
    const { media, policy } = setup({ spotify: 'Paused' });
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    await policy.settled();
    expect(media.calls).toEqual(['pause']);
    expect(media.status.spotify).toBe('Paused');
  });

  it('leaves alone a session the person played again themselves', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.status.spotify = 'Playing';
    policy.recordingEnded();
    await policy.settled();
    // The resume was asked, and the effect (like the script) only touches what is paused.
    expect(media.status.spotify).toBe('Playing');
    expect(media.calls).toEqual(['pause', 'resume:spotify']);
  });

  it('resumes only what it paused, not sessions that started playing during the recording', async () => {
    const { media, policy } = setup({ spotify: 'Playing', other: 'Paused' });
    policy.recordingStarted();
    await policy.settled();
    media.status.other = 'Playing';
    policy.recordingEnded();
    await policy.settled();
    expect(media.calls).toEqual(['pause', 'resume:spotify']);
  });

  it('resumes once per pause: an extra end does nothing', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    policy.recordingEnded();
    await policy.settled();
    expect(media.calls).toEqual(['pause', 'resume:spotify']);
  });

  it('pauses nothing when the recording is cancelled before the pause got its turn', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    policy.recordingEnded();
    await policy.settled();
    expect(media.status.spotify).toBe('Playing');
    expect(resumes(media.calls)).toEqual([]);
  });

  it('plays what a slow pause caught once it finishes, when the recording already ended', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    media.hold();
    policy.recordingStarted();
    await Promise.resolve();
    policy.recordingEnded();
    media.release();
    await policy.settled();
    expect(media.status.spotify).toBe('Playing');
  });

  it('keeps media paused between back-to-back dictations and never pauses twice', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    // The first one ends and the next begins before the resume has gone out.
    policy.recordingEnded();
    policy.recordingStarted();
    await policy.settled();
    expect(media.status.spotify).toBe('Paused');
    expect(resumes(media.calls)).toEqual([]);
    policy.recordingEnded();
    await policy.settled();
    expect(media.status.spotify).toBe('Playing');
    expect(resumes(media.calls)).toEqual(['resume:spotify']);
  });

  it('pauses again for a dictation that starts while a resume is already running', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.hold();
    policy.recordingEnded();
    await Promise.resolve();
    policy.recordingStarted();
    media.release();
    await policy.settled();
    expect(media.status.spotify).toBe('Paused');
    policy.recordingEnded();
    await policy.settled();
    expect(media.status.spotify).toBe('Playing');
  });

  it('logs a failed pause under "media" and carries on', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    media.failPause();
    policy.recordingStarted();
    await policy.settled();
    policy.recordingEnded();
    await policy.settled();
    expect(logs).toEqual(['could not pause: pause failed']);
    expect(media.calls).toEqual(['pause']);
  });

  it('logs a failed resume, forgets those sessions and does not retry', async () => {
    const { media, logs, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    media.failResume();
    policy.recordingEnded();
    await policy.settled();
    expect(logs).toEqual(['could not resume: resume failed']);
    policy.recordingStarted();
    policy.recordingEnded();
    await policy.settled();
    expect(resumes(media.calls)).toEqual(['resume:spotify']);
  });

  it('shutdown plays what is paused and ignores everything after', async () => {
    const { media, policy } = setup({ spotify: 'Playing' });
    policy.recordingStarted();
    await policy.settled();
    await policy.shutdown();
    expect(media.status.spotify).toBe('Playing');
    policy.recordingStarted();
    await policy.settled();
    expect(media.calls).toEqual(['pause', 'resume:spotify']);
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
    });
    expect(() => policy.recordingStarted()).not.toThrow();
    await policy.settled();
    expect(logs[0]).toContain('settings broke');
  });
});
