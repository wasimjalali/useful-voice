import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { runCleanupPipeline, type CleanupPipelineInput } from '../src/core/formatting/cleanupPipeline.js';
import type { CleanupModel } from '../src/core/formatting/cleanupModel.js';
import {
  CLEANUP_MODEL_ENV_KEY,
  CLEANUP_MODEL_SWITCH,
  decideCleanupModel,
  memoryAllowsCleanupModel,
  MINIMUM_CLEANUP_MEMORY_BYTES,
  resolveCleanupModelFlag,
  type CleanupGates,
} from '../src/core/formatting/cleanupModelPolicy.js';

const GiB = 1024 ** 3;
const ON: CleanupGates = { flagOn: true, modelInstalled: true, physicalMemoryBytes: 16 * GiB };

interface Call { text: string; controlLine: string; deadline: number }

/** A model whose answer, delay and failure the test decides. */
function fakeModel(answer: (call: Call) => Promise<string | null> | string | null) {
  const calls: Call[] = [];
  const model: CleanupModel = {
    async clean(text, controlLine, deadline) {
      const call = { text, controlLine, deadline };
      calls.push(call);
      return answer(call);
    },
  };
  return { model, calls };
}

function input(over: Partial<CleanupPipelineInput>): CleanupPipelineInput {
  return {
    raw: 'So um I need to send the report by Friday, no wait, Thursday.',
    language: 'en',
    category: 'email',
    style: null,
    gates: ON,
    model: null,
    now: () => Date.now(),
    ...over,
  };
}

// What the rules leave of the default raw text above, and a model answer the guard accepts.
const RULES_TEXT = 'So I need to send the report by Friday, no wait, Thursday.';
const GOOD_ANSWER = 'I need to send the report by Thursday.';

describe('runCleanupPipeline', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('uses the model answer when the guard accepts it', async () => {
    const { model, calls } = fakeModel(() => GOOD_ANSWER);
    const result = await runCleanupPipeline(input({ model }));
    expect(result).toEqual({ text: GOOD_ANSWER, source: 'model', model: { kind: 'accepted' } });
    expect(calls).toHaveLength(1);
    expect(calls[0]?.text).toBe(RULES_TEXT);
    expect(calls[0]?.controlLine).toBe('[Styling: semi-formal] [Structure: prose] [Context: email]');
  });

  it('hands the model an absolute deadline the default 1.5 s after the start', async () => {
    const { model, calls } = fakeModel(() => GOOD_ANSWER);
    await runCleanupPipeline(input({ model, now: () => 1000 }));
    expect(calls[0]?.deadline).toBe(2500);
    await runCleanupPipeline(input({ model, now: () => 1000, deadlineMs: 400 }));
    expect(calls[1]?.deadline).toBe(1400);
  });

  it('keeps the rules text and never calls the model with the flag off', async () => {
    const { model, calls } = fakeModel(() => GOOD_ANSWER);
    const result = await runCleanupPipeline(input({ model, gates: { ...ON, flagOn: false } }));
    expect(result).toEqual({ text: RULES_TEXT, source: 'rules', model: { kind: 'skipped', reason: 'flagOff' } });
    expect(calls).toHaveLength(0);
  });

  it('skips for a missing download, too little RAM, another language and no model', async () => {
    const { model, calls } = fakeModel(() => GOOD_ANSWER);
    const reason = async (over: Partial<CleanupPipelineInput>) =>
      (await runCleanupPipeline(input({ model, ...over }))).model;
    expect(await reason({ gates: { ...ON, modelInstalled: false } })).toEqual({ kind: 'skipped', reason: 'modelNotDownloaded' });
    expect(await reason({ gates: { ...ON, physicalMemoryBytes: 4 * GiB } })).toEqual({ kind: 'skipped', reason: 'notEnoughMemory' });
    expect(await reason({ language: 'de' })).toEqual({ kind: 'skipped', reason: 'notEnglish' });
    expect(await reason({ language: 'auto' })).toEqual({ kind: 'skipped', reason: 'notEnglish' });
    expect(await reason({ model: null })).toEqual({ kind: 'skipped', reason: 'noModel' });
    expect(calls).toHaveLength(0);
  });

  it('keeps the rules text when the model times out, without waiting for it', async () => {
    const { model } = fakeModel(() => new Promise<string>(() => undefined));
    const pending = runCleanupPipeline(input({ model }));
    await vi.advanceTimersByTimeAsync(1499);
    let settled = false;
    void pending.then(() => (settled = true));
    await vi.advanceTimersByTimeAsync(0);
    expect(settled).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    expect(await pending).toEqual({ text: RULES_TEXT, source: 'rules', model: { kind: 'timedOut' } });
  });

  it('drops a late answer after the timeout', async () => {
    const { model } = fakeModel(() => new Promise((resolve) => setTimeout(() => resolve(GOOD_ANSWER), 2000)));
    const pending = runCleanupPipeline(input({ model }));
    await vi.advanceTimersByTimeAsync(1500);
    expect((await pending).source).toBe('rules');
    await vi.advanceTimersByTimeAsync(1000);
  });

  it('keeps the rules text when the model errors', async () => {
    const { model } = fakeModel(() => {
      throw new Error('boom');
    });
    expect(await runCleanupPipeline(input({ model }))).toEqual({
      text: RULES_TEXT,
      source: 'rules',
      model: { kind: 'failed' },
    });
  });

  it('keeps the rules text when the model returns nothing', async () => {
    const { model } = fakeModel(() => null);
    expect((await runCleanupPipeline(input({ model }))).model).toEqual({ kind: 'failed' });
  });

  it('keeps the rules text when the model returns an empty string', async () => {
    const { model } = fakeModel(() => '');
    expect(await runCleanupPipeline(input({ model }))).toEqual({
      text: RULES_TEXT,
      source: 'rules',
      model: { kind: 'rejected', reason: 'empty' },
    });
  });

  it('keeps the rules text when the guard rejects the answer', async () => {
    const dropped = fakeModel(() => 'Thursday.');
    expect((await runCleanupPipeline(input({ model: dropped.model }))).model).toMatchObject({ kind: 'rejected' });
    const wrapped = fakeModel(() => 'Here is the cleaned text: I need to send the report by Thursday.');
    expect(await runCleanupPipeline(input({ model: wrapped.model }))).toMatchObject({
      text: RULES_TEXT,
      model: { kind: 'rejected', reason: 'wrapper' },
    });
    const invented = fakeModel(() => 'I need to send the report by Thursday, 42 pages.');
    expect((await runCleanupPipeline(input({ model: invented.model }))).text).toBe(RULES_TEXT);
  });

  it('returns the raw text when the rules leave nothing, without asking the model', async () => {
    const { model, calls } = fakeModel(() => GOOD_ANSWER);
    const result = await runCleanupPipeline(input({ raw: 'Um, uh.', model }));
    expect(result).toEqual({ text: 'Um, uh.', source: 'raw' });
    expect(calls).toHaveLength(0);
  });

  it('labels text the rules did not change as raw', async () => {
    const { model } = fakeModel(() => null);
    const result = await runCleanupPipeline(input({ raw: 'The meeting is at noon.', model }));
    expect(result).toEqual({ text: 'The meeting is at noon.', source: 'raw', model: { kind: 'failed' } });
  });

  it('still cleans with the rules alone for English when everything else is off', async () => {
    const result = await runCleanupPipeline(input({ gates: { flagOn: false, modelInstalled: false, physicalMemoryBytes: 0 } }));
    expect(result.text).toBe(RULES_TEXT);
  });
});

describe('cleanup model policy', () => {
  it('turns the model off below 8 GB and on at 8 GB', () => {
    expect(MINIMUM_CLEANUP_MEMORY_BYTES).toBe(8 * GiB);
    expect(memoryAllowsCleanupModel(8 * GiB - 1)).toBe(false);
    expect(memoryAllowsCleanupModel(8 * GiB)).toBe(true);
    expect(memoryAllowsCleanupModel(0)).toBe(false);
  });

  it('reports the first skip reason in order', () => {
    const off: CleanupGates = { flagOn: false, modelInstalled: false, physicalMemoryBytes: 0 };
    expect(decideCleanupModel(off, 'de')).toEqual({ run: false, reason: 'flagOff' });
    expect(decideCleanupModel({ ...off, flagOn: true }, 'de')).toEqual({ run: false, reason: 'modelNotDownloaded' });
    expect(decideCleanupModel({ ...off, flagOn: true, modelInstalled: true }, 'de')).toEqual({ run: false, reason: 'notEnoughMemory' });
    expect(decideCleanupModel({ ...ON }, 'de')).toEqual({ run: false, reason: 'notEnglish' });
    expect(decideCleanupModel({ ...ON }, null)).toEqual({ run: false, reason: 'notEnglish' });
    expect(decideCleanupModel({ ...ON }, 'en')).toEqual({ run: true });
    expect(decideCleanupModel({ ...ON }, 'EN-GB')).toEqual({ run: true });
  });

  it('reads the hidden flag from the switch or the environment, off by default', () => {
    expect(resolveCleanupModelFlag([], {})).toBe(false);
    expect(resolveCleanupModelFlag(['app.exe', CLEANUP_MODEL_SWITCH], {})).toBe(true);
    expect(resolveCleanupModelFlag([], { [CLEANUP_MODEL_ENV_KEY]: '1' })).toBe(true);
    expect(resolveCleanupModelFlag([], { [CLEANUP_MODEL_ENV_KEY]: ' TRUE ' })).toBe(true);
    expect(resolveCleanupModelFlag([], { [CLEANUP_MODEL_ENV_KEY]: 'yes' })).toBe(true);
    expect(resolveCleanupModelFlag([], { [CLEANUP_MODEL_ENV_KEY]: '0' })).toBe(false);
    expect(resolveCleanupModelFlag([], { [CLEANUP_MODEL_ENV_KEY]: '' })).toBe(false);
    expect(resolveCleanupModelFlag([CLEANUP_MODEL_SWITCH], { [CLEANUP_MODEL_ENV_KEY]: '0' })).toBe(false);
  });
});
