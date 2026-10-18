import { describe, expect, it } from 'vitest';
import { MediaPausePolicy, type MediaEffects } from '../src/core/media/mediaPausePolicy.js';
import { QuitCoordinator, type QuitEvent } from '../src/main/quitCoordinator.js';

/**
 * Drives the quit handlers with fake Electron events and the real media policy, and asserts
 * what matters: the paused media plays again before the process exits, on a logoff or
 * shutdown (`session-end`), on an `app.quit()` from anywhere, and once.
 *
 * `exit` is recorded only where the real app ends: `runQuit`'s `app.exit`, or Electron
 * finishing its own quit when nothing holds `will-quit`.
 */
function setup() {
  const order: string[] = [];
  const player = { spotify: 'Playing' as 'Playing' | 'Paused' };
  const effects: MediaEffects = {
    async listPlaying() {
      return player.spotify === 'Playing' ? [{ id: 'spotify', position: 0, updated: 0 }] : [];
    },
    async pause() {
      player.spotify = 'Paused';
      return { confirmed: [{ id: 'spotify', position: 0, updated: 0 }], refused: [], skipped: [] };
    },
    async resume() {
      // A real resume takes a moment: the exit must wait for it.
      await new Promise((resolve) => setTimeout(resolve, 20));
      player.spotify = 'Playing';
      order.push('media resumed');
      return { refused: [], touched: [], unconfirmed: [] };
    },
  };
  const media = new MediaPausePolicy({ effects, enabled: () => true, log: () => undefined, graceMs: 0 });

  let quits = 0;
  let appQuits = 0;
  let quitting: Promise<void> | null = null;
  const orderlyQuit = (): Promise<void> => {
    quits += 1;
    quitting ??= (async () => {
      await media.shutdown(2500);
      order.push('exit (app.exit)');
    })();
    return quitting;
  };

  const event = (): QuitEvent & { prevented: boolean } => ({
    prevented: false,
    preventDefault() {
      this.prevented = true;
    },
  });

  const handlers: { beforeQuit?: { prevented: boolean }; willQuit?: { prevented: boolean } } = {};
  const coordinator: QuitCoordinator = new QuitCoordinator({
    quit: orderlyQuit,
    requestAppQuit: () => {
      appQuits += 1;
      electronQuit();
    },
    shutdownMedia: (budget) => media.shutdown(budget),
  });
  /** What `app.quit()` does: before-quit, then (if nobody stopped it) will-quit, then exit. */
  function electronQuit(): void {
    const before = event();
    handlers.beforeQuit = before;
    coordinator.onBeforeQuit(before);
    if (before.prevented) return;
    const will = event();
    handlers.willQuit = will;
    coordinator.onWillQuit(will);
    if (will.prevented) return;
    order.push('exit (electron finished its quit)');
  }
  const settle = async (): Promise<void> => {
    await quitting;
    await media.settled();
  };
  return {
    order,
    player,
    media,
    coordinator,
    electronQuit,
    settle,
    counts: () => ({ quits, appQuits }),
    handlers,
    async dictating(): Promise<void> {
      media.recordingStarted();
      await media.settled();
      expect(player.spotify).toBe('Paused');
    },
  };
}

describe('a logoff or shutdown (session-end)', () => {
  it('plays the media again before the process exits, and the exit is the orderly quit, not Electron', async () => {
    const ctx = setup();
    await ctx.dictating();
    ctx.coordinator.onSessionEnd();
    await ctx.settle();
    expect(ctx.player.spotify).toBe('Playing');
    expect(ctx.order).toEqual(['media resumed', 'exit (app.exit)']);
  });

  it('lets Electron start its own quit (so Windows sees the app quitting) and holds the exit until the media is back', () => {
    const ctx = setup();
    ctx.coordinator.onSessionEnd();
    // before-quit was let through, will-quit was held.
    expect(ctx.handlers.beforeQuit?.prevented).toBe(false);
    expect(ctx.handlers.willQuit?.prevented).toBe(true);
    expect(ctx.counts().appQuits).toBe(1);
  });

  it('runs once however many windows report it', async () => {
    const ctx = setup();
    await ctx.dictating();
    ctx.coordinator.onSessionEnd();
    ctx.coordinator.onSessionEnd();
    ctx.coordinator.onSessionEnd();
    await ctx.settle();
    expect(ctx.counts()).toEqual({ quits: 1, appQuits: 1 });
    expect(ctx.order).toEqual(['media resumed', 'exit (app.exit)']);
  });

  it('does nothing to media that was never paused', async () => {
    const ctx = setup();
    ctx.coordinator.onSessionEnd();
    await ctx.settle();
    expect(ctx.player.spotify).toBe('Playing');
    expect(ctx.order).toEqual(['exit (app.exit)']);
  });
});

describe('an app.quit() from anywhere else', () => {
  it('is stopped at before-quit and becomes the orderly quit, which plays the media first', async () => {
    const ctx = setup();
    await ctx.dictating();
    ctx.electronQuit();
    await ctx.settle();
    expect(ctx.handlers.beforeQuit?.prevented).toBe(true);
    expect(ctx.order).toEqual(['media resumed', 'exit (app.exit)']);
    expect(ctx.counts().quits).toBe(1);
  });

  it('holds a second quit that arrives while the first is running, so it cannot cut the resume short', async () => {
    const ctx = setup();
    await ctx.dictating();
    ctx.electronQuit();
    ctx.electronQuit();
    await ctx.settle();
    expect(ctx.order).toEqual(['media resumed', 'exit (app.exit)']);
    expect(ctx.counts().quits).toBe(2);
  });

  it('does not ask Electron to quit itself: only a session end does that', async () => {
    const ctx = setup();
    ctx.electronQuit();
    await ctx.settle();
    expect(ctx.counts().appQuits).toBe(0);
  });
});
