import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { encodeWav } from '../src/core/audio/wav.js';
import type { ParakeetState } from '../src/core/models/parakeet.js';
import type { ParakeetWorkerRequest, ParakeetWorkerResponse } from '../src/core/models/parakeetProtocol.js';
import { checkParakeetLanguage, parseWavToFloat32 } from '../src/core/models/parakeetSupport.js';
import { ProviderError } from '../src/core/transcription/deepgramProvider.js';
import { classifyTranscriptionFailure, describeTranscriptionFailure } from '../src/main/dictationService.js';
import { ParakeetModels, type ParakeetWorkerHandle } from '../src/main/parakeet.js';

const FILES = ['encoder.int8.onnx', 'decoder.int8.onnx', 'joiner.int8.onnx', 'tokens.txt'];

let dir: string;
beforeEach(() => {
  // A finished download preloads; without a worker in the test that logs a warning.
  vi.spyOn(console, 'warn').mockImplementation(() => undefined);
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'uv-parakeet-'));
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
  fs.rmSync(dir, { recursive: true, force: true });
});

function wav(seconds = 1): Uint8Array {
  const samples = new Float32Array(16000 * seconds);
  for (let i = 0; i < samples.length; i += 1) samples[i] = Math.sin(i / 20) * 0.3;
  return encodeWav(samples, 16000);
}

/** A fake archive: the extractor writes these files (a missing name leaves it out). */
function extractorWith(names: string[], sub = 'sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8') {
  return async (_archive: string, dest: string) => {
    const root = path.join(dest, sub);
    fs.mkdirSync(root, { recursive: true });
    for (const n of names) fs.writeFileSync(path.join(root, n), `data-${n}`);
  };
}

function fetchOf(body: Uint8Array, init: { status?: number; chunk?: number; failAfter?: number } = {}) {
  const calls: Array<{ range: string | null }> = [];
  const impl = (async (_url: unknown, opts?: RequestInit) => {
    const headers = new Headers(opts?.headers);
    calls.push({ range: headers.get('range') });
    const status = init.status ?? 200;
    if (status !== 200 && status !== 206) return new Response('nope', { status });
    const start = status === 206 ? Number(/bytes=(\d+)-/.exec(headers.get('range') ?? '')?.[1] ?? 0) : 0;
    const part = body.slice(start);
    const chunk = init.chunk ?? 4;
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (opts?.signal?.aborted) return controller.error(new DOMException('aborted', 'AbortError'));
        if (init.failAfter !== undefined && sent >= init.failAfter) return controller.error(new Error('socket reset'));
        if (sent >= part.length) return controller.close();
        controller.enqueue(part.slice(sent, sent + chunk));
        sent += chunk;
      },
    });
    return new Response(stream, { status, headers: { 'content-length': String(part.length) } });
  }) as unknown as typeof fetch;
  return { impl, calls };
}

function seedReady(version: 'v2' | 'v3' = 'v2') {
  const model = path.join(dir, 'models', `parakeet-${version}`);
  fs.mkdirSync(model, { recursive: true });
  const files: Record<string, number> = {};
  for (const n of FILES) {
    fs.writeFileSync(path.join(model, n), `data-${n}`);
    files[n] = `data-${n}`.length;
  }
  fs.writeFileSync(path.join(model, 'parakeet.json'), JSON.stringify({ version, files }));
  return model;
}

describe('WAV parsing', () => {
  it('rejects files that are not 16 kHz mono 16-bit PCM', () => {
    expect(() => parseWavToFloat32(new Uint8Array(5))).toThrow(/too short/);
    expect(() => parseWavToFloat32(new Uint8Array(64))).toThrow(/not a WAV/);
    const stereo = wav();
    new DataView(stereo.buffer).setUint16(22, 2, true);
    expect(() => parseWavToFloat32(stereo)).toThrow(/mono/);
    const rate = wav();
    new DataView(rate.buffer).setUint32(24, 44100, true);
    expect(() => parseWavToFloat32(rate)).toThrow(/16 kHz/);
    const bits = wav();
    new DataView(bits.buffer).setUint16(34, 8, true);
    expect(() => parseWavToFloat32(bits)).toThrow(/16-bit/);
  });

  it('reads samples, skips extra chunks and trusts the bytes when the size is wrong', () => {
    const base = wav(1);
    expect(base.length).toBe(44 + 32000);
    const parsed = parseWavToFloat32(base);
    expect(parsed.samples.length).toBe(16000);
    expect(parsed.durationSeconds).toBeCloseTo(1, 5);
    expect(parsed.samples[100]).toBeCloseTo(Math.sin(100 / 20) * 0.3, 3);

    // A LIST chunk before data, and a data size of 0 (streamed file).
    const list = new Uint8Array([...'LIST'].map((c) => c.charCodeAt(0)).concat([4, 0, 0, 0, 1, 2, 3, 4]));
    const withList = new Uint8Array(base.length + list.length);
    withList.set(base.subarray(0, 36));
    withList.set(list, 36);
    withList.set(base.subarray(36), 36 + list.length);
    new DataView(withList.buffer).setUint32(36 + list.length + 4, 0, true);
    expect(parseWavToFloat32(withList).samples.length).toBe(16000);
  });
});

describe('language gating', () => {
  it('v2 speaks English only', () => {
    expect(checkParakeetLanguage('v2', 'auto')).toBeNull();
    expect(checkParakeetLanguage('v2', undefined)).toBeNull();
    expect(checkParakeetLanguage('v2', 'en-GB')).toBe('en-GB');
    expect(() => checkParakeetLanguage('v2', 'de')).toThrow(/only speaks English/);
  });

  it('v3 covers 25 European languages and refuses the rest', () => {
    for (const code of ['de', 'fr', 'es', 'uk', 'el', 'mt', 'pt-BR']) {
      expect(checkParakeetLanguage('v3', code)).toBe(code);
    }
    expect(() => checkParakeetLanguage('v3', 'ja')).toThrow(/doesn't speak Japanese/);
    expect(() => checkParakeetLanguage('v3', 'ar')).toThrowError(ProviderError);
  });

  it('transcribe fails fast on a wrong pin, before touching the worker', async () => {
    seedReady('v2');
    const spawnWorker = vi.fn();
    const models = new ParakeetModels(dir, { spawnWorker });
    await expect(models.transcribe(wav(), 'v2', undefined, 'fr')).rejects.toMatchObject({ kind: 'badRequest' });
    expect(spawnWorker).not.toHaveBeenCalled();
  });
});

describe('state from disk', () => {
  it('is notDownloaded for an empty folder, a partial download or an incomplete model', () => {
    expect(new ParakeetModels(dir).states()).toEqual({ v2: { status: 'notDownloaded' }, v3: { status: 'notDownloaded' } });
    fs.mkdirSync(path.join(dir, 'models'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'models', 'parakeet-v2.partial'), 'half');
    expect(new ParakeetModels(dir).states().v2.status).toBe('notDownloaded');

    const model = seedReady('v3');
    fs.rmSync(path.join(model, 'joiner.int8.onnx'));
    expect(new ParakeetModels(dir).states().v3.status).toBe('notDownloaded');
  });

  it('is notDownloaded when a file changed size since it was recorded', () => {
    const model = seedReady('v2');
    fs.appendFileSync(path.join(model, 'encoder.int8.onnx'), 'x');
    expect(new ParakeetModels(dir).states().v2.status).toBe('notDownloaded');
  });

  it('is ready with the total size when every file matches', () => {
    seedReady('v2');
    const total = FILES.reduce((n, f) => n + `data-${f}`.length, 0);
    expect(new ParakeetModels(dir).states().v2).toEqual({ status: 'ready', sizeBytes: total });
  });

  it('transcribe refuses a model that is not downloaded', async () => {
    await expect(new ParakeetModels(dir).transcribe(wav(), 'v2')).rejects.toMatchObject({ kind: 'notConfigured' });
  });
});

describe('download', () => {
  const body = new Uint8Array(40).map((_, i) => i);

  it('fails with a readable message on an HTTP error and on a dead network', async () => {
    const http = new ParakeetModels(dir, { fetch: fetchOf(body, { status: 404 }).impl, extract: extractorWith(FILES) });
    await http.download('v2');
    expect(http.states().v2).toEqual({ status: 'failed', message: expect.stringContaining('HTTP 404') });

    const dead = new ParakeetModels(dir, {
      fetch: (async () => {
        throw new TypeError('fetch failed');
      }) as unknown as typeof fetch,
    });
    await dead.download('v2');
    expect(dead.states().v2).toMatchObject({ status: 'failed', message: expect.stringContaining('Check your connection') });
  });

  it('keeps the partial file when the connection drops, then resumes with a Range request', async () => {
    const first = new ParakeetModels(dir, { fetch: fetchOf(body, { failAfter: 16 }).impl, extract: extractorWith(FILES) });
    await first.download('v2');
    expect(first.states().v2.status).toBe('failed');
    const partial = path.join(dir, 'models', 'parakeet-v2.partial');
    expect(fs.statSync(partial).size).toBe(16);
    expect(first.states().v2.status).not.toBe('ready');

    const second = fetchOf(body);
    const models = new ParakeetModels(dir, { fetch: second.impl, extract: extractorWith(FILES) });
    await models.download('v2');
    expect(second.calls[0]?.range).toBe('bytes=16-');
    expect(models.states().v2.status).toBe('ready');
    expect(fs.existsSync(partial)).toBe(false);
  });

  it('restarts when the server ignores Range and sends the whole file', async () => {
    fs.mkdirSync(path.join(dir, 'models'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'models', 'parakeet-v2.partial'), new Uint8Array(10));
    let archiveBytes = 0;
    const models = new ParakeetModels(dir, {
      fetch: (async () => fetchOf(body).impl('', {})) as unknown as typeof fetch,
      extract: async (archive, dest) => {
        archiveBytes = fs.statSync(archive).size;
        await extractorWith(FILES)(archive, dest);
      },
    });
    await models.download('v2');
    expect(archiveBytes).toBe(40);
    expect(models.states().v2.status).toBe('ready');
  });

  it('drops a damaged partial that the server rejects with 416 and starts over', async () => {
    fs.mkdirSync(path.join(dir, 'models'), { recursive: true });
    fs.writeFileSync(path.join(dir, 'models', 'parakeet-v2.partial'), new Uint8Array(99));
    let n = 0;
    const ok = fetchOf(body).impl;
    const models = new ParakeetModels(dir, {
      fetch: (async (u: unknown, o?: RequestInit) => (n++ === 0 ? new Response('', { status: 416 }) : ok(u as string, o))) as typeof fetch,
      extract: extractorWith(FILES),
    });
    await models.download('v2');
    expect(models.states().v2.status).toBe('ready');
  });

  it('rejects an archive with a missing file, never moves it into place and removes the bad partial', async () => {
    const models = new ParakeetModels(dir, {
      fetch: fetchOf(body).impl,
      extract: extractorWith(FILES.filter((f) => f !== 'tokens.txt')),
    });
    await models.download('v2');
    expect(models.states().v2).toEqual({ status: 'failed', message: expect.stringContaining('tokens.txt') });
    expect(fs.existsSync(path.join(dir, 'models', 'parakeet-v2'))).toBe(false);
    expect(fs.existsSync(path.join(dir, 'models', '.parakeet-v2.extract'))).toBe(false);
  });

  it('rejects an empty model file', async () => {
    const models = new ParakeetModels(dir, {
      fetch: fetchOf(body).impl,
      extract: async (_a, dest) => {
        fs.mkdirSync(path.join(dest, 'x'));
        for (const n of FILES) fs.writeFileSync(path.join(dest, 'x', n), n === 'decoder.int8.onnx' ? '' : 'ok');
      },
    });
    await models.download('v2');
    expect(models.states().v2).toMatchObject({ status: 'failed', message: expect.stringContaining('decoder.int8.onnx') });
  });

  it('turns a failing extractor into a failed state and deletes the corrupt archive', async () => {
    const models = new ParakeetModels(dir, {
      fetch: fetchOf(body).impl,
      extract: async () => {
        throw new Error('bzip2: data error');
      },
    });
    await models.download('v2');
    expect(models.states().v2).toMatchObject({ status: 'failed', message: expect.stringContaining('damaged') });
    expect(fs.existsSync(path.join(dir, 'models', 'parakeet-v2.partial'))).toBe(false);
  });

  it('reports progress, records sizes and ends ready', async () => {
    const seen: ParakeetState[] = [];
    const models = new ParakeetModels(dir, { fetch: fetchOf(body, { chunk: 1000 }).impl, extract: extractorWith(FILES) });
    models.onChange((s) => seen.push(s.v2));
    await models.download('v2');
    expect(seen[0]).toEqual({ status: 'downloading', progress: null });
    expect(seen).toContainEqual({ status: 'downloading', progress: 1 });
    const total = FILES.reduce((n, f) => n + `data-${f}`.length, 0);
    expect(seen.at(-1)).toEqual({ status: 'ready', sizeBytes: total });
    const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'models', 'parakeet-v2', 'parakeet.json'), 'utf8'));
    expect(manifest.files['tokens.txt']).toBe('data-tokens.txt'.length);
    expect(new ParakeetModels(dir).states().v2.status).toBe('ready');
  });

  it('cancel stops the download, keeps the partial and leaves the state notDownloaded', async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const impl = (async (_u: unknown, opts?: RequestInit) => {
      const stream = new ReadableStream<Uint8Array>({
        async pull(controller) {
          controller.enqueue(new Uint8Array(8));
          await gate;
          if (opts?.signal?.aborted) controller.error(new DOMException('aborted', 'AbortError'));
        },
      });
      return new Response(stream, { status: 200, headers: { 'content-length': '1000' } });
    }) as unknown as typeof fetch;
    const extract = vi.fn();
    const models = new ParakeetModels(dir, { fetch: impl, extract });
    const done = models.download('v2');
    await vi.waitFor(() => expect(fs.existsSync(path.join(dir, 'models', 'parakeet-v2.partial'))).toBe(true));
    models.cancel('v2');
    release();
    await done;
    expect(models.states().v2).toEqual({ status: 'notDownloaded' });
    expect(fs.existsSync(path.join(dir, 'models', 'parakeet-v2.partial'))).toBe(true);
    expect(extract).not.toHaveBeenCalled();
  });

  it('remove deletes the model and any partial', async () => {
    seedReady('v2');
    fs.writeFileSync(path.join(dir, 'models', 'parakeet-v2.partial'), 'x');
    const models = new ParakeetModels(dir);
    expect(models.states().v2.status).toBe('ready');
    await models.remove('v2');
    expect(models.states().v2).toEqual({ status: 'notDownloaded' });
    expect(fs.existsSync(path.join(dir, 'models', 'parakeet-v2'))).toBe(false);
    expect(fs.existsSync(path.join(dir, 'models', 'parakeet-v2.partial'))).toBe(false);
  });
});

describe('worker handling', () => {
  class FakeWorker implements ParakeetWorkerHandle {
    requests: ParakeetWorkerRequest[] = [];
    killed = false;
    private messageListener: ((m: ParakeetWorkerResponse) => void) | null = null;
    private exitListener: ((reason: string) => void) | null = null;
    constructor(private readonly onRequest: (w: FakeWorker, r: ParakeetWorkerRequest) => void) {}
    postMessage(m: ParakeetWorkerRequest) {
      this.requests.push(m);
      this.onRequest(this, m);
    }
    onMessage(l: (m: ParakeetWorkerResponse) => void) {
      this.messageListener = l;
    }
    onExit(l: (r: string) => void) {
      this.exitListener = l;
    }
    kill() {
      if (this.killed) return;
      this.killed = true;
      queueMicrotask(() => this.exitListener?.('killed'));
    }
    reply(r: ParakeetWorkerResponse) {
      this.messageListener?.(r);
    }
    crash() {
      this.exitListener?.('exit code 139');
    }
  }

  const echo = (w: FakeWorker, r: ParakeetWorkerRequest) =>
    queueMicrotask(() => w.reply({ id: r.id, ok: true, text: 'hello world', loadMs: 1, decodeMs: 1 }));

  function setup(onRequest: (w: FakeWorker, r: ParakeetWorkerRequest) => void, extra: object = {}) {
    seedReady('v2');
    const workers: FakeWorker[] = [];
    const spawnWorker = vi.fn(async () => {
      const w = new FakeWorker(onRequest);
      workers.push(w);
      return w;
    });
    return { workers, spawnWorker, models: new ParakeetModels(dir, { spawnWorker, ...extra }) };
  }

  it('returns the transcript, sends the model folder and samples, and reuses the worker', async () => {
    const { models, workers, spawnWorker } = setup(echo);
    const t = await models.transcribe(wav(2), 'v2', undefined, 'en');
    expect(t).toEqual({ text: 'hello world', durationSeconds: 2, detectedLanguage: 'en' });
    await models.transcribe(wav(), 'v2');
    expect(spawnWorker).toHaveBeenCalledTimes(1);
    expect(workers[0]!.requests[0]!.modelDir).toBe(path.join(dir, 'models', 'parakeet-v2'));
    expect(workers[0]!.requests[0]!.samples.length).toBe(32000);
    expect((await models.transcribe(wav(), 'v2')).detectedLanguage).toBeNull();
  });

  it('turns a worker error into a readable ProviderError and keeps the worker', async () => {
    const { models, spawnWorker } = setup((w, r) =>
      queueMicrotask(() => w.reply({ id: r.id, ok: false, error: 'cannot load encoder' })),
    );
    await expect(models.transcribe(wav(), 'v2')).rejects.toMatchObject({
      kind: 'transport',
      message: expect.stringContaining('cannot load encoder'),
    });
    await expect(models.transcribe(wav(), 'v2')).rejects.toBeInstanceOf(ProviderError);
    expect(spawnWorker).toHaveBeenCalledTimes(1);
  });

  it('fails the request in flight when the worker crashes, and restarts on the next one', async () => {
    let n = 0;
    const { models, workers, spawnWorker } = setup((w, r) => {
      if (n++ === 0) queueMicrotask(() => w.crash());
      else echo(w, r);
    });
    await expect(models.transcribe(wav(), 'v2')).rejects.toMatchObject({
      kind: 'transport',
      message: expect.stringContaining('stopped unexpectedly'),
    });
    expect((await models.transcribe(wav(), 'v2')).text).toBe('hello world');
    expect(spawnWorker).toHaveBeenCalledTimes(2);
    expect(workers).toHaveLength(2);
  });

  it('fails with a readable error when the worker cannot start', async () => {
    seedReady('v2');
    const models = new ParakeetModels(dir, {
      spawnWorker: async () => {
        throw new Error('spawn EACCES');
      },
    });
    await expect(models.transcribe(wav(), 'v2')).rejects.toMatchObject({
      kind: 'transport',
      message: expect.stringContaining("Couldn't start the Parakeet engine"),
    });
  });

  it('times out a stuck recognition, kills the worker and restarts for the next request', async () => {
    let n = 0;
    const { models, workers } = setup(
      (w, r) => {
        if (n++ > 0) echo(w, r);
      },
      { requestTimeoutMs: () => 30 },
    );
    await expect(models.transcribe(wav(), 'v2')).rejects.toMatchObject({ kind: 'timedOut' });
    expect(workers[0]!.killed).toBe(true);
    expect((await models.transcribe(wav(), 'v2')).text).toBe('hello world');
    expect(workers).toHaveLength(2);
  });

  it('honors an abort mid-recognition and drops the late result', async () => {
    let held!: () => void;
    const { models, workers } = setup((w, r) => {
      held = () => w.reply({ id: r.id, ok: true, text: 'late', loadMs: 0, decodeMs: 0 });
    });
    const controller = new AbortController();
    const result = models.transcribe(wav(), 'v2', controller.signal);
    await vi.waitFor(() => expect(workers[0]?.requests).toHaveLength(1));
    controller.abort();
    await expect(result).rejects.toMatchObject({ kind: 'cancelled' });
    held(); // the answer arrives after the abort and is ignored
    expect(workers[0]!.killed).toBe(false);
  });

  it('refuses an already-aborted signal without starting a worker', async () => {
    const { models, spawnWorker } = setup(echo);
    const controller = new AbortController();
    controller.abort();
    await expect(models.transcribe(wav(), 'v2', controller.signal)).rejects.toMatchObject({ kind: 'cancelled' });
    expect(spawnWorker).not.toHaveBeenCalled();
  });

  it('stops the worker after the idle time and starts a new one on the next request', async () => {
    vi.useFakeTimers();
    const { models, workers } = setup(echo, { idleMs: 5 * 60_000 });
    await models.transcribe(wav(), 'v2');
    await vi.advanceTimersByTimeAsync(4 * 60_000);
    expect(workers[0]!.killed).toBe(false);
    await vi.advanceTimersByTimeAsync(61_000);
    expect(workers[0]!.killed).toBe(true);
    await models.transcribe(wav(), 'v2');
    expect(workers).toHaveLength(2);
  });

  it('preload loads the downloaded model in the background and is a no-op once loaded', async () => {
    const { models, workers, spawnWorker } = setup(echo);
    models.preload('v2');
    await vi.waitFor(() => expect(workers[0]?.requests).toHaveLength(1));
    expect(workers[0]!.requests[0]).toMatchObject({ loadOnly: true, modelDir: path.join(dir, 'models', 'parakeet-v2') });
    await vi.waitFor(() => expect(models['workerVersion' as keyof typeof models]).toBe('v2'));
    models.preload('v2');
    await models.transcribe(wav(), 'v2');
    expect(spawnWorker).toHaveBeenCalledTimes(1);
    expect(workers[0]!.requests.filter((r) => r.loadOnly)).toHaveLength(1);
  });

  it('preload does nothing for a model that is not downloaded and never throws on failure', async () => {
    const spawnWorker = vi.fn(async () => {
      throw new Error('spawn EACCES');
    });
    const none = new ParakeetModels(dir, { spawnWorker });
    none.preload('v3');
    expect(spawnWorker).not.toHaveBeenCalled();

    seedReady('v2');
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    const bad = new ParakeetModels(dir, { spawnWorker });
    expect(() => bad.preload('v2')).not.toThrow();
    await vi.waitFor(() => expect(warn).toHaveBeenCalled());
    expect(String(warn.mock.calls[0]![0])).toContain('preload failed');
    warn.mockRestore();
  });

  it('a transcribe during a preload waits for it instead of loading twice', async () => {
    let releaseLoad!: () => void;
    const { models, workers } = setup((w, r) => {
      if (r.loadOnly) releaseLoad = () => w.reply({ id: r.id, ok: true, text: '', loadMs: 1, decodeMs: 0 });
      else echo(w, r);
    });
    models.preload('v2');
    await vi.waitFor(() => expect(workers[0]?.requests).toHaveLength(1));
    const result = models.transcribe(wav(), 'v2');
    await new Promise((r) => setTimeout(r, 20));
    expect(workers[0]!.requests).toHaveLength(1); // transcribe has not been sent yet
    releaseLoad();
    expect((await result).text).toBe('hello world');
    expect(workers).toHaveLength(1);
    expect(workers[0]!.requests.map((r) => Boolean(r.loadOnly))).toEqual([true, false]);
  });

  it('the pinned version is never stopped by the idle timer, an unpinned one is', async () => {
    vi.useFakeTimers();
    const { models, workers } = setup(echo, { idleMs: 60_000 });
    models.setPinned('v2');
    await models.transcribe(wav(), 'v2');
    await vi.advanceTimersByTimeAsync(10 * 60_000);
    expect(workers[0]!.killed).toBe(false);
    models.setPinned(null);
    await vi.advanceTimersByTimeAsync(61_000);
    expect(workers[0]!.killed).toBe(true);
  });

  it('pinning a different version than the loaded one does not protect the worker', async () => {
    vi.useFakeTimers();
    const { models, workers } = setup(echo, { idleMs: 60_000 });
    models.setPinned('v3');
    await models.transcribe(wav(), 'v2');
    await vi.advanceTimersByTimeAsync(61_000);
    expect(workers[0]!.killed).toBe(true);
  });

  it('a finished download preloads the new model', async () => {
    const workers: FakeWorker[] = [];
    const spawnWorker = vi.fn(async () => {
      const w = new FakeWorker(echo);
      workers.push(w);
      return w;
    });
    const models = new ParakeetModels(dir, {
      spawnWorker,
      fetch: fetchOf(new Uint8Array(8)).impl,
      extract: extractorWith(FILES),
    });
    await models.download('v2');
    await vi.waitFor(() => expect(workers[0]?.requests[0]?.loadOnly).toBe(true));
    expect(spawnWorker).toHaveBeenCalledTimes(1);
  });

  it('every failure carries the Parakeet provider and reads as a local engine problem', async () => {
    seedReady('v2');
    const errors: unknown[] = [];
    const grab = async (p: Promise<unknown>) => p.catch((e) => errors.push(e));

    // crash
    const crash = new ParakeetModels(dir, {
      spawnWorker: async () => new FakeWorker((w) => queueMicrotask(() => w.crash())),
    });
    await grab(crash.transcribe(wav(), 'v2'));
    // timeout
    const slow = new ParakeetModels(dir, {
      spawnWorker: async () => new FakeWorker(() => undefined),
      requestTimeoutMs: () => 20,
    });
    await grab(slow.transcribe(wav(), 'v2'));
    // load failure reported by the worker
    const broken = new ParakeetModels(dir, {
      spawnWorker: async () => new FakeWorker((w, r) => queueMicrotask(() => w.reply({ id: r.id, ok: false, error: 'bad model' }))),
    });
    await grab(broken.transcribe(wav(), 'v2'));
    // start failure, language, not downloaded, bad WAV
    await grab(new ParakeetModels(dir, { spawnWorker: async () => { throw new Error('x'); } }).transcribe(wav(), 'v2'));
    await grab(broken.transcribe(wav(), 'v2', undefined, 'fr'));
    await grab(new ParakeetModels(path.join(dir, 'empty')).transcribe(wav(), 'v2'));
    await grab(broken.transcribe(new Uint8Array(3), 'v2'));
    const aborted = new AbortController();
    aborted.abort();
    await grab(broken.transcribe(wav(), 'v2', aborted.signal));

    expect(errors).toHaveLength(8);
    for (const e of errors) expect(e).toMatchObject({ name: 'ProviderError', provider: 'Parakeet' });
    expect((errors[0] as Error).message).toBe('Parakeet stopped unexpectedly. Try again.');
    expect((errors[1] as Error).message).toBe('Parakeet took too long. Try again.');
    // None of them is shown as a network problem.
    for (const e of errors) {
      expect(describeTranscriptionFailure(e)).not.toMatch(/internet|Could not reach|Deepgram/i);
      expect(classifyTranscriptionFailure(e).kind).not.toBe('offline');
    }
  });

  it('remove stops the worker only when it holds that version; the other keeps running', async () => {
    seedReady('v2');
    seedReady('v3');
    let release!: () => void;
    const workers: FakeWorker[] = [];
    const models = new ParakeetModels(dir, {
      spawnWorker: async () => {
        const w = new FakeWorker((fw, r) => {
          if (r.modelDir.endsWith('parakeet-v3')) release = () => fw.reply({ id: r.id, ok: true, text: 'v3 text', loadMs: 0, decodeMs: 0 });
          else echo(fw, r);
        });
        workers.push(w);
        return w;
      },
    });
    await models.transcribe(wav(), 'v2'); // worker holds v2
    const running = models.transcribe(wav(), 'v3'); // v3 in flight
    await vi.waitFor(() => expect(workers[0]!.requests).toHaveLength(2));
    await models.remove('v2'); // v2 files go, v3 keeps decoding
    expect(workers[0]!.killed).toBe(false);
    release();
    expect((await running).text).toBe('v3 text');

    // Now the worker holds v3: removing v3 stops it, removing the other would not have.
    await models.remove('v3');
    expect(workers[0]!.killed).toBe(true);
  });

  it('remove stops the worker when it holds that version and nothing else is running', async () => {
    const { models, workers } = setup(echo);
    await models.transcribe(wav(), 'v2');
    await models.remove('v3');
    expect(workers[0]!.killed).toBe(false);
    await models.remove('v2');
    expect(workers[0]!.killed).toBe(true);
  });

  it('dispose kills the worker and fails what is pending', async () => {
    const { models, workers } = setup(() => undefined);
    const result = models.transcribe(wav(), 'v2');
    await vi.waitFor(() => expect(workers[0]?.requests).toHaveLength(1));
    models.dispose();
    await expect(result).rejects.toMatchObject({ kind: 'transport' });
    expect(workers[0]!.killed).toBe(true);
    await expect(models.transcribe(wav(), 'v2')).rejects.toMatchObject({ kind: 'cancelled' });
  });
});
