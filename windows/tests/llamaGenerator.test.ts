import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fork, type ChildProcess } from 'node:child_process';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { LlamaCleanupGenerator } from '../src/main/cleanupModel/llamaGenerator.js';

// A stand-in for cleanupWorker.js that speaks the same protocol. What it does with a
// prompt depends on the prompt, so each test picks a behaviour.
const FAKE_WORKER = `
let loads = 0;
process.on('message', (m) => {
  if (m.type === 'load') {
    if (m.path === 'bad.gguf') return process.send({ type: 'error', message: 'cannot open bad.gguf' });
    if (m.path === 'never.gguf') return;
    loads += 1;
    process.send({ type: 'loaded', loadMs: 1, prefix: m.prefix, pid: process.pid });
  } else if (m.type === 'generate') {
    if (m.user === 'parts') return process.send({ type: 'result', id: m.id, text: JSON.stringify({ head: m.head, user: m.user, tail: m.tail }), ms: 1 });
    if (m.user === 'echo') return process.send({ type: 'result', id: m.id, text: 'echo:' + process.pid, ms: 1 });
    if (m.user === 'throw') return process.send({ type: 'error', id: m.id, message: 'boom' });
    if (m.user === 'crash') return process.exit(3);
    if (m.user === 'ackAbort') { globalThis.pending = m.id; return; }
    if (m.user === 'hang') return;
  } else if (m.type === 'abort') {
    if (globalThis.pending === m.id) process.send({ type: 'error', id: m.id, message: 'aborted' });
  } else if (m.type === 'dispose') {
    process.exit(0);
  }
});
process.on('disconnect', () => process.exit(0));
`;

let dir = '';
let script = '';
let generator: LlamaCleanupGenerator;
const warnings: string[] = [];
const prompt = (user: string) => ({ head: '', user, tail: '' });
const FAR = () => performance.now() + 20_000;

beforeEach(async () => {
  dir = await mkdtemp(path.join(os.tmpdir(), 'uv-gen-'));
  script = path.join(dir, 'fake-worker.cjs');
  await writeFile(script, FAKE_WORKER);
  warnings.length = 0;
  generator = new LlamaCleanupGenerator({ workerScript: script, warn: (m) => warnings.push(m), abortGraceMs: 150, exitGraceMs: 2000 });
});
afterEach(async () => {
  await generator.unload();
  await rm(dir, { recursive: true, force: true });
});

describe('LlamaCleanupGenerator', () => {
  it('loads the model in a child process and returns what it generates', async () => {
    await generator.load('ok.gguf');
    expect(generator.isRunning).toBe(true);
    const text = await generator.generate(prompt('echo'), FAR());
    expect(text).toMatch(/^echo:\d+$/);
    expect(text).not.toBe(`echo:${process.pid}`);
  });

  it('sends the template and the dictation as separate parts', async () => {
    await generator.load('ok.gguf');
    const parts = { head: '<|im_start|>user\n', user: 'parts', tail: '<|im_end|>\n' };
    const echoed = JSON.parse(await generator.generate(parts, FAR())) as typeof parts;
    expect(echoed).toEqual(parts);
  });

  it('rejects a load the worker refuses, and runs nothing', async () => {
    await expect(generator.load('bad.gguf')).rejects.toThrow('cannot open bad.gguf');
    expect(generator.isRunning).toBe(false);
  });

  it('rejects a load that never answers, within the load timeout', async () => {
    const quick = new LlamaCleanupGenerator({ workerScript: script, loadTimeoutMs: 200 });
    await expect(quick.load('never.gguf')).rejects.toThrow('timed out loading the model');
    expect(quick.isRunning).toBe(false);
  });

  it('rejects a run the worker reports as failed, and keeps the worker', async () => {
    await generator.load('ok.gguf');
    await expect(generator.generate(prompt('throw'), FAR())).rejects.toThrow('boom');
    expect(generator.isRunning).toBe(true);
    expect(await generator.generate(prompt('echo'), FAR())).toMatch(/^echo:/);
  });

  it('rejects at the deadline and keeps the worker when it confirms the abort', async () => {
    await generator.load('ok.gguf');
    const before = await generator.generate(prompt('echo'), FAR());
    const started = performance.now();
    await expect(generator.generate(prompt('ackAbort'), started + 100)).rejects.toThrow('deadline');
    expect(performance.now() - started).toBeLessThan(400);
    expect(generator.isRunning).toBe(true);
    expect(await generator.generate(prompt('echo'), FAR())).toBe(before);
    expect(warnings).toEqual([]);
  });

  it('kills a worker that ignores the abort and starts a fresh one for the next run', async () => {
    await generator.load('ok.gguf');
    const before = await generator.generate(prompt('echo'), FAR());
    await expect(generator.generate(prompt('hang'), performance.now() + 80)).rejects.toThrow('deadline');
    const after = await generator.generate(prompt('echo'), FAR());
    expect(after).not.toBe(before);
    expect(warnings[0]).toContain('did not stop at the deadline');
  });

  it('rejects when the worker crashes, then loads a new one for the next run', async () => {
    await generator.load('ok.gguf');
    await expect(generator.generate(prompt('crash'), FAR())).rejects.toThrow('exited (3)');
    expect(generator.isRunning).toBe(false);
    expect(await generator.generate(prompt('echo'), FAR())).toMatch(/^echo:/);
  });

  it('refuses a run whose deadline has passed without touching the worker', async () => {
    await generator.load('ok.gguf');
    await expect(generator.generate(prompt('echo'), performance.now() - 1)).rejects.toThrow('deadline');
  });

  it('does not start a run when the reload after a crash used up the deadline', async () => {
    await generator.load('ok.gguf');
    await expect(generator.generate(prompt('crash'), FAR())).rejects.toThrow('exited (3)');
    await expect(generator.generate(prompt('echo'), performance.now() + 1)).rejects.toThrow('deadline');
    expect(generator.isRunning).toBe(true);
    expect(await generator.generate(prompt('echo'), FAR())).toMatch(/^echo:/);
  });

  it('kill ends the worker at once and rejects the run in flight', async () => {
    await generator.load('ok.gguf');
    const running = generator.generate(prompt('hang'), FAR());
    const rejected = expect(running).rejects.toThrow('exited');
    await new Promise((r) => setTimeout(r, 50));
    generator.kill();
    await rejected;
    expect(generator.isRunning).toBe(false);
  });

  it('kill during a load rejects the load', async () => {
    const loading = generator.load('never.gguf');
    const rejected = expect(loading).rejects.toThrow('exited');
    await new Promise((r) => setTimeout(r, 50));
    generator.kill();
    await rejected;
  });

  it('reports an error after the worker started as a failure, not a failed start, and never throws', async () => {
    let child: ChildProcess | null = null;
    const watched = new LlamaCleanupGenerator({
      workerScript: script,
      spawn: (file) => (child = fork(file, [], { execArgv: [], stdio: ['ignore', 'ignore', 'pipe', 'ipc'] })),
    });
    await watched.load('ok.gguf');
    const running = watched.generate(prompt('hang'), FAR());
    const rejected = expect(running).rejects.toThrow('the model worker failed: channel broke');
    await new Promise((r) => setTimeout(r, 50));
    child!.emit('error', new Error('channel broke'));
    child!.emit('error', new Error('second error with no waiter')); // `on`, so this must not throw
    await rejected;
    watched.kill();
  });

  it('refuses to send to a closed channel', async () => {
    await generator.load('ok.gguf');
    let child: ChildProcess | null = null;
    const closed = new LlamaCleanupGenerator({
      workerScript: script,
      spawn: (file) => (child = fork(file, [], { execArgv: [], stdio: ['ignore', 'ignore', 'pipe', 'ipc'] })),
    });
    await closed.load('ok.gguf');
    child!.disconnect();
    await expect(closed.generate(prompt('echo'), FAR())).rejects.toThrow();
    closed.kill();
  });

  it('refuses a run before any load', async () => {
    await expect(generator.generate(prompt('echo'), FAR())).rejects.toThrow('not loaded');
  });

  it('unload ends the worker process', async () => {
    await generator.load('ok.gguf');
    const text = await generator.generate(prompt('echo'), FAR());
    const pid = Number(text.split(':')[1]);
    await generator.unload();
    expect(generator.isRunning).toBe(false);
    expect(() => process.kill(pid, 0)).toThrow();
    await generator.unload();
  });
});
