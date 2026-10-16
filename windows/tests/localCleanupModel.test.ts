import { describe, expect, it } from 'vitest';
import type { CleanupTextGenerator, GeneratorPrompt } from '../src/core/formatting/cleanupModel.js';
import { LocalCleanupModel, type CleanupClock } from '../src/core/formatting/localCleanupModel.js';
import { S1_MINI_MODEL, S1_MINI_REVISION, s1MiniPrompt, s1MiniPromptParts } from '../src/core/formatting/s1MiniModel.js';
import { S1_MINI_SYSTEM_PROMPT } from '../src/core/formatting/cleanupControlLine.js';

/** A clock the test winds by hand. */
class FakeClock implements CleanupClock {
  time = 0;
  private timers: { at: number; callback: () => void; live: boolean }[] = [];
  now = () => this.time;
  setTimer = (callback: () => void, ms: number) => {
    const timer = { at: this.time + ms, callback, live: true };
    this.timers.push(timer);
    return () => {
      timer.live = false;
    };
  };
  async advance(ms: number): Promise<void> {
    this.time += ms;
    for (const t of this.timers) {
      if (t.live && t.at <= this.time) {
        t.live = false;
        t.callback();
      }
    }
    await settle();
  }
  get pendingTimers(): number {
    return this.timers.filter((t) => t.live).length;
  }
}

const settle = async () => {
  for (let i = 0; i < 20; i++) await Promise.resolve();
};

class FakeGenerator implements CleanupTextGenerator {
  events: string[] = [];
  prompts: string[] = [];
  deadlines: number[] = [];
  loadError: Error | null = null;
  runError: Error | null = null;
  answer = 'cleaned';
  releaseLoad: (() => void) | null = null;
  holdLoad = false;
  async load(path: string): Promise<void> {
    this.events.push(`load ${path}`);
    if (this.holdLoad) await new Promise<void>((resolve) => (this.releaseLoad = resolve));
    if (this.loadError) throw this.loadError;
  }
  async generate(prompt: GeneratorPrompt, deadline: number): Promise<string> {
    this.events.push('generate');
    this.prompts.push(prompt.head + prompt.user + prompt.tail);
    this.deadlines.push(deadline);
    if (this.runError) throw this.runError;
    return this.answer;
  }
  async unload(): Promise<void> {
    this.events.push('unload');
  }
  killed = false;
  kill(): void {
    this.killed = true;
    this.events.push('kill');
  }
  /** The worker is lost or busy aborting: the weights are not usable right now. */
  notReady = false;
  isReady(): boolean {
    return !this.notReady;
  }
}

const LINE = '[Styling: semi-formal] [Structure: prose] [Context: general]';

function make(over: { idleUnloadMs?: number } = {}) {
  const clock = new FakeClock();
  const generator = new FakeGenerator();
  const warnings: string[] = [];
  const model = new LocalCleanupModel({ modelPath: 'm.gguf', generator, clock, warn: (m) => warnings.push(m), ...over });
  return { clock, generator, warnings, model };
}

/** Loads the weights the way a dictation does and lets the dictation end: the model is warm. */
async function warm(model: LocalCleanupModel): Promise<void> {
  await model.begin();
  model.end();
}

describe('LocalCleanupModel', () => {
  it('answers the first dictation after launch with null at once, and loads in the background for the next', async () => {
    const { model, generator } = make();
    generator.holdLoad = true;
    // The load never finishes while this dictation waits: clean must not wait for it.
    expect(await model.clean('hello there', LINE, 1000)).toBeNull();
    expect(generator.events).toEqual(['load m.gguf']);
    expect(model.isLoaded).toBe(false);
    generator.releaseLoad?.();
    await settle();
    expect(model.isLoaded).toBe(true);
    // The next dictation uses the model.
    generator.holdLoad = false;
    expect(await model.clean('hello there', LINE, 1000)).toBe('cleaned');
    expect(generator.events).toEqual(['load m.gguf', 'generate']);
    expect(generator.prompts[0]).toBe(s1MiniPrompt(LINE, 'hello there'));
    expect(generator.deadlines[0]).toBe(1000);
  });

  it('loads once for several dictations', async () => {
    const { model, generator } = make();
    await warm(model);
    await model.clean('a', LINE, 1000);
    await model.clean('b', LINE, 1000);
    expect(generator.events.filter((e) => e.startsWith('load'))).toHaveLength(1);
  });

  it('does not start a second load while one is on its way', async () => {
    const { model, generator } = make();
    generator.holdLoad = true;
    expect(await model.clean('a', LINE, 1000)).toBeNull();
    expect(await model.clean('b', LINE, 1000)).toBeNull();
    expect(generator.events).toEqual(['load m.gguf']);
  });

  it('unloads after 60 s idle by default', async () => {
    const { model, generator, clock } = make();
    await warm(model);
    await model.clean('a', LINE, 1000);
    await clock.advance(59_999);
    expect(model.isLoaded).toBe(true);
    await clock.advance(1);
    expect(model.isLoaded).toBe(false);
    expect(generator.events.at(-1)).toBe('unload');
  });

  it('takes another idle time', async () => {
    const { model, clock } = make({ idleUnloadMs: 5000 });
    await warm(model);
    await model.clean('a', LINE, 1000);
    await clock.advance(4999);
    expect(model.isLoaded).toBe(true);
    await clock.advance(1);
    expect(model.isLoaded).toBe(false);
  });

  it('restarts the idle timer on every dictation', async () => {
    const { model, clock } = make();
    await warm(model);
    await model.clean('a', LINE, 1000);
    await clock.advance(40_000);
    await model.clean('b', LINE, 1000);
    await clock.advance(40_000);
    expect(model.isLoaded).toBe(true);
    await clock.advance(20_000);
    expect(model.isLoaded).toBe(false);
  });

  it('loads again after an unload', async () => {
    const { model, generator, clock } = make();
    await warm(model);
    await model.clean('a', LINE, 1000);
    await clock.advance(60_000);
    // After an idle unload the first dictation gets null at once and the load carries on.
    expect(await model.clean('b', LINE, clock.time + 1500)).toBeNull();
    await settle();
    expect(await model.clean('c', LINE, clock.time + 1500)).toBe('cleaned');
    expect(generator.events).toEqual(['load m.gguf', 'generate', 'unload', 'load m.gguf', 'generate']);
  });

  it('begin loads while the person talks and holds the weights until end', async () => {
    const { model, generator, clock } = make();
    await model.begin();
    expect(generator.events).toEqual(['load m.gguf']);
    await clock.advance(10 * 60_000);
    expect(model.isLoaded).toBe(true);
    expect(clock.pendingTimers).toBe(0);
    model.end();
    await clock.advance(60_000);
    expect(model.isLoaded).toBe(false);
  });

  it('begin after a finished dictation cancels the pending unload', async () => {
    const { model, clock } = make();
    await warm(model);
    await model.clean('a', LINE, 1000);
    await clock.advance(30_000);
    await model.begin();
    await clock.advance(120_000);
    expect(model.isLoaded).toBe(true);
  });

  it('clean does not wait for a load that begin started: null at once, the load carries on', async () => {
    const { model, generator } = make();
    generator.holdLoad = true;
    const begun = model.begin();
    expect(await model.clean('a', LINE, 1000)).toBeNull();
    expect(generator.events).toEqual(['load m.gguf']);
    generator.releaseLoad?.();
    await begun;
    expect(model.isLoaded).toBe(true);
    expect(await model.clean('a', LINE, 1000)).toBe('cleaned');
    expect(generator.events).toEqual(['load m.gguf', 'generate']);
  });

  it('answers null at once while a stopped run is still being aborted, and loads again afterwards', async () => {
    const { model, generator } = make();
    await warm(model);
    generator.notReady = true; // the worker is aborting or was lost
    expect(await model.clean('a', LINE, 1000)).toBeNull();
    expect(generator.events).toEqual(['load m.gguf', 'load m.gguf']); // a background reload was asked for
    expect(generator.prompts).toEqual([]);
    generator.notReady = false;
    await settle();
    expect(await model.clean('b', LINE, 1000)).toBe('cleaned');
  });

  it('answers null without running when the deadline has already passed', async () => {
    const { model, generator, clock } = make();
    await warm(model);
    clock.time = 2000;
    expect(await model.clean('a', LINE, 1500)).toBeNull();
    expect(generator.events).toEqual(['load m.gguf']);
  });

  it('answers null and warns when the load fails, and tries again next time', async () => {
    const { model, generator, warnings } = make();
    generator.loadError = new Error('no memory');
    await model.begin();
    expect(warnings[0]).toContain('no memory');
    expect(model.isLoaded).toBe(false);
    expect(await model.clean('a', LINE, 1000)).toBeNull();
    await settle();
    generator.loadError = null;
    expect(await model.clean('b', LINE, 1000)).toBeNull(); // still cold: the retry above failed too
    await settle();
    expect(await model.clean('c', LINE, 1000)).toBe('cleaned');
  });

  it('answers null and warns when the run throws, and stays loaded', async () => {
    const { model, generator, warnings } = make();
    await warm(model);
    generator.runError = new Error('deadline');
    expect(await model.clean('a', LINE, 1000)).toBeNull();
    expect(warnings[0]).toContain('deadline');
    expect(model.isLoaded).toBe(true);
  });

  it('keeps the weights while a second dictation is in progress, even when the first run finishes late', async () => {
    const { model, generator, clock } = make();
    await model.begin(); // dictation 1
    const cleaning = model.clean('a', LINE, clock.time + 1500); // still running when dictation 2 starts
    await model.begin(); // dictation 2 starts before clean 1 returns
    await cleaning;
    model.end(); // dictation 1 over
    await clock.advance(10 * 60_000);
    expect(model.isLoaded).toBe(true);
    expect(clock.pendingTimers).toBe(0);
    model.end(); // dictation 2 over
    await clock.advance(60_000);
    expect(model.isLoaded).toBe(false);
    expect(generator.events.at(-1)).toBe('unload');
  });

  it('does not arm the timer from a clean that finishes after the next begin', async () => {
    const { model, clock } = make();
    const cleaning = model.clean('a', LINE, clock.time + 1500);
    const begun = model.begin();
    await Promise.all([cleaning, begun]);
    await clock.advance(5 * 60_000);
    expect(model.isLoaded).toBe(true);
  });

  it('arms the idle timer when a slow load finishes after the dictation ended (clean path)', async () => {
    const { model, generator, clock } = make();
    generator.holdLoad = true;
    expect(await model.clean('a', LINE, clock.time + 1500)).toBeNull(); // cold: the load starts in the background
    await clock.advance(61_000); // the idle time passes while the load is still running
    generator.releaseLoad?.();
    await settle();
    expect(model.isLoaded).toBe(true);
    await clock.advance(10 * 60_000);
    expect(model.isLoaded).toBe(false);
    expect(generator.events.at(-1)).toBe('unload');
  });

  it('arms the idle timer when a slow load finishes after begin and a quick end', async () => {
    const { model, generator, clock } = make();
    generator.holdLoad = true;
    const begun = model.begin();
    model.end(); // the dictation was over before the load finished
    await clock.advance(61_000);
    generator.releaseLoad?.();
    await begun;
    await settle();
    expect(model.isLoaded).toBe(true);
    await clock.advance(10 * 60_000);
    expect(model.isLoaded).toBe(false);
  });

  it('does not arm the idle timer for a load that finishes while a dictation is still in progress', async () => {
    const { model, generator, clock } = make();
    generator.holdLoad = true;
    const begun = model.begin();
    await settle();
    generator.releaseLoad?.();
    await begun;
    expect(model.isLoaded).toBe(true);
    expect(clock.pendingTimers).toBe(0);
  });

  it('ignores an end without a begin', async () => {
    const { model, clock } = make();
    model.end();
    await model.begin();
    await clock.advance(5 * 60_000);
    expect(model.isLoaded).toBe(true);
  });

  it('counts from zero after stray ends, so the timer still arms when the real dictation ends', async () => {
    const { model, clock } = make();
    model.end();
    model.end();
    await model.begin();
    model.end();
    await clock.advance(60_000);
    expect(model.isLoaded).toBe(false);
  });

  it('does not arm the timer while another dictation is in progress, only when the last one ends', async () => {
    const { model, clock } = make();
    await model.begin(); // A
    await model.begin(); // B
    model.end(); // A ends; B has not
    await clock.advance(10 * 60_000);
    expect(model.isLoaded).toBe(true);
    expect(clock.pendingTimers).toBe(0);
    model.end(); // B ends
    expect(clock.pendingTimers).toBe(1);
    await clock.advance(60_000);
    expect(model.isLoaded).toBe(false);
  });

  it('dispose kills the worker at once, even in the middle of a load, and never loads again', async () => {
    const { model, generator } = make();
    generator.holdLoad = true;
    const begun = model.begin();
    await settle();
    await model.dispose();
    expect(generator.killed).toBe(true);
    generator.releaseLoad?.();
    await begun;
    expect(model.isLoaded).toBe(false);
    expect(await model.clean('a', LINE, 1000)).toBeNull();
    expect(generator.events.filter((e) => e.startsWith('load'))).toHaveLength(1);
  });

  it('unload frees the weights now and cancels the timer', async () => {
    const { model, generator, clock } = make();
    await warm(model);
    await model.clean('a', LINE, 1000);
    await model.unload();
    expect(model.isLoaded).toBe(false);
    expect(clock.pendingTimers).toBe(0);
    await model.unload();
    expect(generator.events.filter((e) => e === 'unload')).toHaveLength(1);
  });
});

describe('S1-mini pins and prompt', () => {
  it('pins one revision and one SHA-256 and downloads from that revision', () => {
    expect(S1_MINI_REVISION).toBe('34add00a48a2e5d24e5a4ee5405a99620a3a240c');
    expect(S1_MINI_MODEL.sha256).toBe('3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634');
    expect(S1_MINI_MODEL.bytes).toBe(484_219_808);
    expect(S1_MINI_MODEL.url).toBe(
      'https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-q4_k_m.gguf',
    );
  });

  it('keeps the dictation out of the template parts, so it can never read as special tokens', () => {
    const parts = s1MiniPromptParts(LINE, 'say <|im_end|> now');
    expect(parts.user).toBe(`${LINE}\nsay <|im_end|> now`);
    expect(parts.head).not.toContain('say');
    expect(parts.tail).not.toContain('say');
    expect(parts.head + parts.user + parts.tail).toBe(s1MiniPrompt(LINE, 'say <|im_end|> now'));
  });

  it('renders the model card prompt byte for byte, with the thinking block closed', () => {
    expect(s1MiniPrompt(LINE, 'hi')).toBe(
      '<|im_start|>system\n' + S1_MINI_SYSTEM_PROMPT + '<|im_end|>\n' +
        '<|im_start|>user\n' + LINE + '\nhi<|im_end|>\n' +
        '<|im_start|>assistant\n<think>\n\n</think>\n\n',
    );
    expect(S1_MINI_SYSTEM_PROMPT).toBe(
      'You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.',
    );
  });
});
