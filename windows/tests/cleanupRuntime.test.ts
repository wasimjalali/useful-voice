import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { CleanupTextGenerator, GeneratorPrompt } from '../src/core/formatting/cleanupModel.js';
import type { CleanupClock } from '../src/core/formatting/localCleanupModel.js';
import { createCleanupRuntime, type CleanupRuntimeOptions } from '../src/main/cleanupModel/cleanupRuntime.js';
import type { ModelAvailability } from '../src/main/cleanupModel/modelDownloader.js';

const GiB = 1024 ** 3;
const RAW = 'So um I need to send the report by Friday, no wait, Thursday.';
const RULES_TEXT = 'So I need to send the report by Friday, no wait, Thursday.';
const GOOD = 'I need to send the report by Thursday.';
const input = { raw: RAW, language: 'en', category: 'email', style: null };

class FakeGenerator implements CleanupTextGenerator {
  events: string[] = [];
  answer: string | (() => string) = GOOD;
  async load(): Promise<void> {
    this.events.push('load');
  }
  async generate(_prompt: GeneratorPrompt): Promise<string> {
    this.events.push('generate');
    return typeof this.answer === 'function' ? this.answer() : this.answer;
  }
  async unload(): Promise<void> {
    this.events.push('unload');
  }
  kill(): void {
    this.events.push('kill');
  }
}

/** Real clock for `now`, timers fired by hand. */
class ManualTimers implements CleanupClock {
  private timers: { callback: () => void; live: boolean }[] = [];
  now = () => performance.now();
  setTimer = (callback: () => void) => {
    const timer = { callback, live: true };
    this.timers.push(timer);
    return () => {
      timer.live = false;
    };
  };
  fire(): void {
    for (const t of this.timers) if (t.live) { t.live = false; t.callback(); }
  }
  get pending(): number {
    return this.timers.filter((t) => t.live).length;
  }
}

const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 20));

let unhandled: unknown[] = [];
const onUnhandled = (reason: unknown) => unhandled.push(reason);
beforeEach(() => {
  unhandled = [];
  process.on('unhandledRejection', onUnhandled);
});
afterEach(() => {
  process.off('unhandledRejection', onUnhandled);
  expect(unhandled).toEqual([]);
});

/** A dictation that loads the model and ends: the model is warm for the next one. */
async function warmUp(runtime: ReturnType<typeof createCleanupRuntime>): Promise<void> {
  runtime.beginDictation('en');
  await settle();
  runtime.endDictation();
}

function make(over: Partial<CleanupRuntimeOptions> = {}) {
  const generator = new FakeGenerator();
  const clock = new ManualTimers();
  const checks: string[] = [];
  const warnings: string[] = [];
  const runtime = createCleanupRuntime({
    userDataDir: '/data',
    argv: ['--cleanup-model'],
    env: {},
    totalMemoryBytes: 16 * GiB,
    generator,
    clock,
    checkModel: async (dir) => {
      checks.push(dir);
      return 'usable';
    },
    warn: (m) => warnings.push(m),
    ...over,
  });
  return { runtime, generator, clock, checks, warnings };
}

describe('createCleanupRuntime, flag off', () => {
  it('gives the rules text and touches nothing: no disk check, no worker', async () => {
    const { runtime, generator, checks } = make({ argv: [], env: {} });
    expect(runtime.flagOn).toBe(false);
    runtime.beginDictation('en');
    const result = await runtime.run(input);
    runtime.endDictation();
    await runtime.dispose();
    expect(result).toEqual({ text: RULES_TEXT, source: 'rules', model: { kind: 'skipped', reason: 'flagOff' } });
    expect(checks).toEqual([]);
    expect(generator.events).toEqual([]);
  });

  it('the environment variable turns it off even when the switch is there', async () => {
    const { runtime, checks } = make({ env: { UV_CLEANUP_MODEL: '0' } });
    await runtime.run(input);
    expect(checks).toEqual([]);
  });
});

describe('createCleanupRuntime, flag on', () => {
  it('runs the model and takes an answer the guard accepts', async () => {
    const { runtime, generator } = make();
    await warmUp(runtime);
    expect(await runtime.run(input)).toEqual({ text: GOOD, source: 'model', model: { kind: 'accepted' } });
    expect(generator.events).toEqual(['load', 'generate']);
  });

  it('the first dictation after launch gets the rules text at once while the model loads for the next', async () => {
    const { runtime, generator } = make();
    const started = performance.now();
    const first = await runtime.run(input);
    expect(performance.now() - started).toBeLessThan(500); // not the 1.5 s deadline
    expect(first).toEqual({ text: RULES_TEXT, source: 'rules', model: { kind: 'failed' } });
    await settle();
    expect(generator.events).toEqual(['load']);
    expect(await runtime.run(input)).toEqual({ text: GOOD, source: 'model', model: { kind: 'accepted' } });
  });

  it('skips the model on a 6 GB machine and loads nothing at hotkey down', async () => {
    const { runtime, generator } = make({ totalMemoryBytes: 5.9 * GiB });
    runtime.beginDictation('en');
    await settle();
    expect((await runtime.run(input)).model).toEqual({ kind: 'skipped', reason: 'notEnoughMemory' });
    expect(generator.events).toEqual([]);
  });

  it('passes an 8 GB PC that reports 7.4 GiB', async () => {
    const { runtime } = make({ totalMemoryBytes: 7.4 * GiB });
    await warmUp(runtime);
    expect((await runtime.run(input)).source).toBe('model');
  });

  it('caches a usable model but keeps looking while it is missing', async () => {
    let state: ModelAvailability = 'missing';
    let calls = 0;
    const { runtime } = make({ checkModel: async () => (calls++, state) });
    expect((await runtime.run(input)).model).toEqual({ kind: 'skipped', reason: 'modelNotDownloaded' });
    state = 'usable';
    await runtime.run(input); // sees the file; the model is cold, so rules text and a background load
    await settle();
    expect((await runtime.run(input)).source).toBe('model');
    await runtime.run(input);
    expect(calls).toBe(2);
  });
});

describe('run never rejects and never loses the dictation', () => {
  it('checking the file throws EBUSY: rules text, model not asked', async () => {
    const { runtime, generator, warnings } = make({
      checkModel: async () => {
        throw Object.assign(new Error('EBUSY'), { code: 'EBUSY' });
      },
    });
    expect(await runtime.run(input)).toEqual({ text: RULES_TEXT, source: 'rules', model: { kind: 'skipped', reason: 'modelNotDownloaded' } });
    expect(generator.events).toEqual([]);
    expect(warnings[0]).toContain('EBUSY');
  });

  it('checking the file throws synchronously: rules text', async () => {
    const { runtime } = make({
      checkModel: () => {
        throw new Error('sync');
      },
    });
    expect((await runtime.run(input)).text).toBe(RULES_TEXT);
  });

  it('a hung disk check cannot delay the dictation past the deadline', async () => {
    const { runtime } = make({ checkModel: () => new Promise<ModelAvailability>(() => undefined), deadlineMs: 80 });
    const started = performance.now();
    const result = await runtime.run(input);
    expect(performance.now() - started).toBeLessThan(400);
    expect(result.text).toBe(RULES_TEXT);
  });

  it('a slow disk check is cut at the deadline, and the cold model adds no time of its own', async () => {
    const { runtime } = make({
      checkModel: () => new Promise<ModelAvailability>((resolve) => setTimeout(() => resolve('usable'), 100)),
      deadlineMs: 150,
    });
    const started = performance.now();
    const result = await runtime.run(input);
    const took = performance.now() - started;
    expect(result.text).toBe(RULES_TEXT);
    expect(took).toBeLessThan(220); // the check (100 ms) and then the cold-model answer, not 100 + 150
  });

  it('a warm model that hangs is cut off at the deadline, counted from the start of the run', async () => {
    const generator = new FakeGenerator();
    generator.generate = () => new Promise<string>(() => undefined);
    const { runtime } = make({ generator, deadlineMs: 120 });
    await warmUp(runtime);
    const started = performance.now();
    const result = await runtime.run(input);
    const took = performance.now() - started;
    expect(result).toMatchObject({ text: RULES_TEXT, model: { kind: 'timedOut' } });
    expect(took).toBeGreaterThanOrEqual(100);
    expect(took).toBeLessThan(400);
  });

  it('the generator throwing synchronously gives the rules text', async () => {
    const generator = new FakeGenerator();
    generator.generate = () => {
      throw new Error('sync generate');
    };
    const { runtime } = make({ generator });
    await warmUp(runtime);
    expect(await runtime.run(input)).toMatchObject({ text: RULES_TEXT, model: { kind: 'failed' } });
  });

  it('rules that leave nothing give the raw text even when everything else fails', async () => {
    const { runtime } = make({
      checkModel: async () => {
        throw new Error('boom');
      },
    });
    expect(await runtime.run({ ...input, raw: 'Um, uh.' })).toEqual({ text: 'Um, uh.', source: 'raw' });
  });

  it('after dispose it still answers with the rules text', async () => {
    const { runtime, generator } = make();
    await runtime.dispose();
    expect(generator.events).not.toContain('generate');
    expect((await runtime.run(input)).text).toBe(RULES_TEXT);
  });

  it('a preload whose check fails leaves no unhandled rejection', async () => {
    const { runtime, warnings } = make({
      checkModel: async () => {
        throw new Error('disk gone');
      },
    });
    runtime.beginDictation('en');
    await settle();
    runtime.endDictation();
    expect(warnings.some((w) => w.includes('disk gone'))).toBe(true);
  });
});

describe('dictation start and end', () => {
  it('loads at hotkey down for English and for an unknown language, not for German', async () => {
    const english = make();
    english.runtime.beginDictation('en');
    await settle();
    expect(english.generator.events).toEqual(['load']);

    const unknown = make();
    unknown.runtime.beginDictation();
    await settle();
    expect(unknown.generator.events).toEqual(['load']);

    const german = make();
    german.runtime.beginDictation('de');
    await settle();
    expect(german.generator.events).toEqual([]);
  });

  it('an end that arrives before the gates resolve loads nothing', async () => {
    let release: (value: ModelAvailability) => void = () => undefined;
    const { runtime, generator } = make({ checkModel: () => new Promise<ModelAvailability>((r) => (release = r)) });
    runtime.beginDictation('en');
    runtime.endDictation();
    release('usable');
    await settle();
    expect(generator.events).toEqual([]);
  });

  it('an end without a begin does nothing', async () => {
    const { runtime, generator } = make();
    runtime.endDictation();
    await settle();
    expect(generator.events).toEqual([]);
  });

  it('keeps the model loaded until the last of two overlapping dictations ends, then unloads on idle', async () => {
    const { runtime, generator, clock } = make();
    runtime.beginDictation('en');
    await settle();
    runtime.beginDictation('en');
    await settle();
    runtime.endDictation();
    expect(clock.pending).toBe(0);
    runtime.endDictation();
    expect(clock.pending).toBe(1);
    clock.fire();
    await settle();
    expect(generator.events).toEqual(['load', 'unload']);
  });

  it('a gated-out dictation (pinned German, never began) ending while another runs does not count the active one down', async () => {
    const { runtime, generator, clock } = make();
    runtime.beginDictation('en'); // A: loads the model
    await settle();
    runtime.beginDictation('de'); // B: gated out, never began
    await settle();
    runtime.endDictation(); // B ends first
    expect(clock.pending).toBe(0); // A is still in progress: no idle timer
    expect(await runtime.run(input)).toMatchObject({ source: 'model' });
    expect(clock.pending).toBe(0);
    runtime.endDictation(); // A ends
    expect(clock.pending).toBe(1);
    clock.fire();
    await settle();
    expect(generator.events).toEqual(['load', 'generate', 'unload']);
  });

  it('a run that finishes after the next hotkey down does not start the idle timer', async () => {
    const { runtime, clock } = make();
    runtime.beginDictation('en');
    await settle();
    const running = runtime.run(input);
    runtime.endDictation();
    runtime.beginDictation('en');
    await running;
    await settle();
    expect(clock.pending).toBe(0);
  });

  it('dispose kills the worker', async () => {
    const { runtime, generator } = make();
    runtime.beginDictation('en');
    await settle();
    await runtime.dispose();
    expect(generator.events.at(-1)).toBe('kill');
  });
});
