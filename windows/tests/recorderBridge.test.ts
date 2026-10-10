import { afterEach, describe, expect, it, vi } from 'vitest';
import { RecorderBridge, validateCapture } from '../src/main/recorderBridge.js';
import { CaptureStartTracker } from '../src/core/audio/captureStart.js';
import { DictationService, type CapturedAudio } from '../src/main/dictationService.js';
import { DEFAULT_SETTINGS, emptySnapshot } from '../src/core/models.js';

/**
 * The main-process end of the hidden recorder window, as pure logic.
 *
 * Ways it can fail:
 *  1. start() resolves before the microphone is open, so a blocked mic is only
 *     discovered at stop and never becomes micUnavailable.
 *  2. The renderer never answers start(): the dictation hangs in "recording".
 *  3. An error reported while nobody waits (the device dies mid-recording) is dropped.
 *  4. A late capture or error from an earlier recording resolves or kills the next one.
 *  5. Cancel leaves the renderer encoding and sending audio nobody wants.
 *  6. An ack that arrives after the start timeout resurrects a dead start.
 *  7. A start that timed out while getUserMedia was still pending leaves the microphone
 *     open: the late ack is dropped, and the next recording is bound to the stale stream.
 *  8. A stop that times out never tells the renderer, so the capture keeps running.
 *  9. An error without a token lets any renderer kill a live recording.
 * 10. A capture that is not audio at all (wrong type, absurd size) reaches the pipeline.
 * 11. The renderer cancels a start that is still waiting for the microphone permission and
 *     opens the stream anyway afterwards.
 */

function audio(): CapturedAudio {
  return { wav: new Uint8Array(64_000), durationSeconds: 2, peak: 0.5, hadSpeech: true };
}

function setup(options: { startTimeoutMs?: number; stopTimeoutMs?: number } = {}) {
  const sent: Array<{ channel: string; payload: unknown }> = [];
  const unclaimed: Error[] = [];
  let counter = 0;
  const bridge = new RecorderBridge({
    send: (channel, payload) => sent.push({ channel, payload }),
    onUnclaimedError: (error) => unclaimed.push(error),
    newToken: () => `t${(counter += 1)}`,
    ...options,
  });
  return { bridge, sent, unclaimed };
}

afterEach(() => {
  vi.useRealTimers();
});

describe('start', () => {
  it('resolves only when the renderer acknowledges the matching token', async () => {
    const { bridge, sent } = setup();
    let done = false;
    const starting = bridge.start().then(() => {
      done = true;
    });
    expect(sent).toEqual([{ channel: 'audio:start', payload: { token: 't1' } }]);
    bridge.handleStarted('other');
    await Promise.resolve();
    expect(done).toBe(false);
    bridge.handleStarted('t1');
    await starting;
    expect(done).toBe(true);
  });

  it('rejects with the renderer message when the microphone is blocked', async () => {
    const { bridge } = setup();
    const starting = bridge.start();
    bridge.handleError('t1', 'Permission denied: microphone access is blocked.');
    await expect(starting).rejects.toThrow('Permission denied');
  });

  it('rejects when the renderer never answers, and tells it to discard', async () => {
    vi.useFakeTimers();
    const { bridge, sent } = setup({ startTimeoutMs: 1000 });
    const starting = bridge.start();
    const assertion = expect(starting).rejects.toThrow('did not respond');
    await vi.advanceTimersByTimeAsync(1001);
    await assertion;
    expect(sent.at(-1)).toEqual({ channel: 'audio:stop', payload: { token: 't1', discard: true } });
    expect(vi.getTimerCount()).toBe(0);
    // A late ack must not bring it back.
    bridge.handleStarted('t1');
    await expect(bridge.stop()).rejects.toThrow();
  });

  it('becomes micUnavailable through the service when the mic is blocked', async () => {
    const { bridge } = setup();
    const statuses: Array<{ state: string; error?: { kind: string; fix?: string } }> = [];
    const service = new DictationService({
      recorder: bridge,
      transcriber: { transcribe: async () => ({ text: 'x', durationSeconds: 1, detectedLanguage: null }) },
      sink: { deliver: async () => ({ delivered: true, clipboardFallback: false }) },
      settings: () => DEFAULT_SETTINGS,
      memory: () => emptySnapshot(),
      apiKey: async () => 'k',
      onStatus: (status) => statuses.push(status),
    });
    const toggling = service.toggle({ source: 'hotkey' });
    bridge.handleError('t1', 'Permission denied: microphone access is blocked.');
    await toggling;
    expect(statuses.at(-1)?.state).toBe('error');
    expect(statuses.at(-1)?.error).toMatchObject({ kind: 'micUnavailable', fix: 'openMicrophoneSettings' });
  });
});

describe('errors while recording', () => {
  it('reports an error nobody is waiting for', async () => {
    const { bridge, unclaimed } = setup();
    const starting = bridge.start();
    bridge.handleStarted('t1');
    await starting;
    bridge.handleError('t1', 'device lost');
    expect(unclaimed.map((error) => error.message)).toEqual(['device lost']);
  });

  it('ignores an error from an earlier recording', async () => {
    const { bridge, unclaimed } = setup();
    const first = bridge.start();
    bridge.handleStarted('t1');
    await first;
    await bridge.cancel();
    const second = bridge.start();
    bridge.handleStarted('t2');
    await second;
    bridge.handleError('t1', 'stale');
    expect(unclaimed).toEqual([]);
  });
});

describe('stop', () => {
  it('resolves with the capture of the same token and no other', async () => {
    const { bridge, sent } = setup();
    const starting = bridge.start();
    bridge.handleStarted('t1');
    await starting;
    const stopping = bridge.stop();
    expect(sent.at(-1)).toEqual({ channel: 'audio:stop', payload: { token: 't1', discard: false } });
    const late = audio();
    bridge.handleCaptured('t0', late); // a capture from before
    let settled = false;
    void stopping.then(() => {
      settled = true;
    });
    await Promise.resolve();
    expect(settled).toBe(false);
    const wanted = audio();
    bridge.handleCaptured('t1', wanted);
    await expect(stopping).resolves.toBe(wanted);
  });

  it('does not let the late capture of a cancelled recording resolve the next stop', async () => {
    const { bridge } = setup();
    const first = bridge.start();
    bridge.handleStarted('t1');
    await first;
    await bridge.cancel();

    const second = bridge.start();
    bridge.handleStarted('t2');
    await second;
    const stopping = bridge.stop();
    bridge.handleCaptured('t1', audio());
    const wanted = audio();
    bridge.handleCaptured('t2', wanted);
    await expect(stopping).resolves.toBe(wanted);
  });

  it('rejects when no audio comes back in time', async () => {
    vi.useFakeTimers();
    const { bridge } = setup({ stopTimeoutMs: 500 });
    const starting = bridge.start();
    bridge.handleStarted('t1');
    await starting;
    const stopping = bridge.stop();
    const assertion = expect(stopping).rejects.toThrow('did not return any audio');
    await vi.advanceTimersByTimeAsync(501);
    await assertion;
    expect(vi.getTimerCount()).toBe(0);
  });

  it('rejects when there is nothing to stop', async () => {
    const { bridge } = setup();
    await expect(bridge.stop()).rejects.toThrow();
  });
});

describe('cancel', () => {
  it('tells the renderer to discard, ends a pending stop and clears the timers', async () => {
    vi.useFakeTimers();
    const { bridge, sent } = setup();
    const starting = bridge.start();
    bridge.handleStarted('t1');
    await starting;
    const stopping = bridge.stop();
    const assertion = expect(stopping).rejects.toThrow('cancelled');
    await bridge.cancel();
    await assertion;
    expect(sent.at(-1)).toEqual({ channel: 'audio:stop', payload: { token: 't1', discard: true } });
    expect(vi.getTimerCount()).toBe(0);
  });

  it('is a no-op when nothing is recording', async () => {
    const { bridge, sent } = setup();
    await bridge.cancel();
    expect(sent).toEqual([]);
  });
});

describe('late acknowledgements', () => {
  it('tells the renderer to discard an ack for a start that already timed out', async () => {
    vi.useFakeTimers();
    const { bridge, sent } = setup({ startTimeoutMs: 1000 });
    const starting = bridge.start();
    const assertion = expect(starting).rejects.toThrow('did not respond');
    await vi.advanceTimersByTimeAsync(1001);
    await assertion;
    sent.length = 0;
    // getUserMedia finally resolved in the renderer, which opened the stream.
    bridge.handleStarted('t1');
    expect(sent).toEqual([{ channel: 'audio:stop', payload: { token: 't1', discard: true } }]);
  });

  it('discards an ack for a token it never issued, but not the one it is waiting for', async () => {
    const { bridge, sent } = setup();
    const starting = bridge.start();
    bridge.handleStarted('stranger');
    expect(sent.at(-1)).toEqual({ channel: 'audio:stop', payload: { token: 'stranger', discard: true } });
    bridge.handleStarted('t1');
    await starting;
    expect(sent.filter((message) => message.channel === 'audio:stop')).toHaveLength(1);
  });

  it('leaves a repeated ack for the live recording alone', async () => {
    const { bridge, sent } = setup();
    const starting = bridge.start();
    bridge.handleStarted('t1');
    await starting;
    bridge.handleStarted('t1');
    expect(sent.filter((message) => message.channel === 'audio:stop')).toEqual([]);
  });
});

describe('stop timeout', () => {
  it('tells the renderer to discard when no audio came back in time', async () => {
    vi.useFakeTimers();
    const { bridge, sent } = setup({ stopTimeoutMs: 500 });
    const starting = bridge.start();
    bridge.handleStarted('t1');
    await starting;
    const stopping = bridge.stop();
    const assertion = expect(stopping).rejects.toThrow('did not return any audio');
    await vi.advanceTimersByTimeAsync(501);
    await assertion;
    expect(sent.at(-1)).toEqual({ channel: 'audio:stop', payload: { token: 't1', discard: true } });
  });
});

describe('validateCapture', () => {
  const meta = { durationSeconds: 2, peak: 0.5, hadSpeech: true };

  it('accepts an ArrayBuffer or a Uint8Array of a sane size', () => {
    const fromBuffer = validateCapture(new ArrayBuffer(64_000), meta);
    expect(fromBuffer).toMatchObject({ durationSeconds: 2, peak: 0.5, hadSpeech: true });
    expect((fromBuffer as { wav: Uint8Array }).wav.byteLength).toBe(64_000);
    expect(validateCapture(new Uint8Array(64_000), meta)).toMatchObject({ hadSpeech: true });
  });

  it('refuses anything that is not audio bytes', () => {
    for (const wav of ['audio', 42, null, undefined, {}, [1, 2, 3]]) {
      expect(validateCapture(wav, meta)).toBeInstanceOf(Error);
    }
  });

  it('refuses an empty payload and one larger than the longest recording', () => {
    expect(validateCapture(new ArrayBuffer(0), meta)).toBeInstanceOf(Error);
    expect(validateCapture(new ArrayBuffer(100 * 1024 * 1024), meta)).toBeInstanceOf(Error);
  });

  it('refuses malformed metadata', () => {
    for (const bad of [null, {}, { ...meta, durationSeconds: Number.NaN }, { ...meta, peak: 'loud' }, { ...meta, hadSpeech: 1 }]) {
      expect(validateCapture(new ArrayBuffer(64_000), bad)).toBeInstanceOf(Error);
    }
  });
});

describe('CaptureStartTracker (the renderer side of a start)', () => {
  it('cancels the start in progress when a discard for its token arrives', () => {
    const tracker = new CaptureStartTracker();
    const ticket = tracker.begin('a');
    expect(ticket.cancelled).toBe(false);
    tracker.discard('a');
    expect(ticket.cancelled).toBe(true);
  });

  it('ignores a discard for another token', () => {
    const tracker = new CaptureStartTracker();
    const ticket = tracker.begin('a');
    tracker.discard('b');
    expect(ticket.cancelled).toBe(false);
  });

  it('cancels an older start when a newer one begins', () => {
    const tracker = new CaptureStartTracker();
    const first = tracker.begin('a');
    const second = tracker.begin('b');
    expect(first.cancelled).toBe(true);
    expect(second.cancelled).toBe(false);
  });

  it('forgets a start once it has finished, so a later discard cannot touch it', () => {
    const tracker = new CaptureStartTracker();
    const ticket = tracker.begin('a');
    tracker.finish(ticket);
    tracker.discard('a');
    expect(ticket.cancelled).toBe(false);
  });
});
