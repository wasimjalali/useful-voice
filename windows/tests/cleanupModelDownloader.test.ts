import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import {
  downloadModel,
  modelAvailability,
  modelFilePath,
  ModelDownloadError,
  verifyModelFile,
} from '../src/main/cleanupModel/modelDownloader.js';
import type { PinnedModelFile } from '../src/core/formatting/s1MiniModel.js';

// A small file that looks like a GGUF, served by a real local HTTP server, so the real
// fetch, Range and streaming code runs. 3 MiB so a resume has something to resume.
const body = Buffer.concat([Buffer.from('GGUF'), Buffer.alloc(3 * 1024 * 1024 - 4, 0x5a)]);
for (let i = 4; i < body.length; i += 97) body[i] = i % 251;
const sha = createHash('sha256').update(body).digest('hex');

type Mode = 'range' | 'ignoreRange' | 'truncate' | 'status404' | 'corrupt';
let mode: Mode = 'range';
let requests: { range: string | undefined }[] = [];
let server: http.Server;
let base = '';

beforeAll(async () => {
  server = http.createServer((req, res) => {
    requests.push({ range: req.headers.range });
    if (mode === 'status404') {
      res.writeHead(404).end();
      return;
    }
    const source = mode === 'corrupt' ? Buffer.concat([body.subarray(0, 100), Buffer.from('X'), body.subarray(101)]) : body;
    const match = /bytes=(\d+)-/.exec(req.headers.range ?? '');
    if (match && mode !== 'ignoreRange') {
      const from = Number(match[1]);
      res.writeHead(206, { 'Content-Length': source.length - from, 'Content-Range': `bytes ${from}-${source.length - 1}/${source.length}` });
      res.end(source.subarray(from));
      return;
    }
    if (mode === 'truncate') {
      res.writeHead(200, { 'Content-Length': source.length });
      res.write(source.subarray(0, 1_000_000));
      setTimeout(() => res.destroy(), 20);
      return;
    }
    res.writeHead(200, { 'Content-Length': source.length });
    res.end(source);
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
afterAll(() => new Promise<void>((resolve) => server.close(() => resolve())));

let dir = '';
const pin = (): PinnedModelFile => ({ id: 't', fileName: 't.gguf', url: `${base}/t.gguf`, bytes: body.length, sha256: sha });

beforeEach(async () => {
  dir = await mkdtemp(path.join(os.tmpdir(), 'uv-dl-'));
  mode = 'range';
  requests = [];
});
afterEach(() => rm(dir, { recursive: true, force: true }));

describe('downloadModel', () => {
  it('downloads, verifies the SHA-256 and moves the file into place', async () => {
    const progress: number[] = [];
    const file = await downloadModel(dir, pin(), { onProgress: (received) => progress.push(received) });
    expect(file).toBe(modelFilePath(dir, pin()));
    expect((await readFile(file)).equals(body)).toBe(true);
    expect(await stat(`${file}.partial`).catch(() => null)).toBeNull();
    expect(progress.at(-1)).toBe(body.length);
    expect(await modelAvailability(dir, pin())).toBe('usable');
    expect(await verifyModelFile(dir, pin())).toBe(true);
  });

  it('keeps a model already in place without a request', async () => {
    await downloadModel(dir, pin());
    requests = [];
    await downloadModel(dir, pin());
    expect(requests).toHaveLength(0);
  });

  it('resumes a partial file with a Range request and still checks the whole file', async () => {
    await writeFile(`${modelFilePath(dir, pin())}.partial`, body.subarray(0, 1_200_000));
    const file = await downloadModel(dir, pin());
    expect(requests).toEqual([{ range: 'bytes=1200000-' }]);
    expect((await readFile(file)).equals(body)).toBe(true);
  });

  it('starts again when the server ignores the range', async () => {
    mode = 'ignoreRange';
    await writeFile(`${modelFilePath(dir, pin())}.partial`, body.subarray(0, 1_200_000));
    const file = await downloadModel(dir, pin());
    expect((await readFile(file)).equals(body)).toBe(true);
  });

  it('finishes a partial that already holds every byte without a request', async () => {
    await writeFile(`${modelFilePath(dir, pin())}.partial`, body);
    const file = await downloadModel(dir, pin());
    expect(requests).toHaveLength(0);
    expect((await readFile(file)).equals(body)).toBe(true);
  });

  it('throws a validation error and deletes the file when the checksum is wrong', async () => {
    mode = 'corrupt';
    const error = await downloadModel(dir, pin()).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ModelDownloadError);
    expect((error as ModelDownloadError).kind).toBe('validation');
    expect(await stat(modelFilePath(dir, pin())).catch(() => null)).toBeNull();
    expect(await stat(`${modelFilePath(dir, pin())}.partial`).catch(() => null)).toBeNull();
  });

  it('drops an oversized partial and downloads fresh', async () => {
    await writeFile(`${modelFilePath(dir, pin())}.partial`, Buffer.concat([body, Buffer.from('more')]));
    const file = await downloadModel(dir, pin());
    expect((await readFile(file)).equals(body)).toBe(true);
  });

  it('keeps the partial after a dropped connection, then resumes from it', async () => {
    mode = 'truncate';
    const error = await downloadModel(dir, pin()).catch((e: unknown) => e);
    expect((error as ModelDownloadError).kind).toBe('network');
    const partial = (await stat(`${modelFilePath(dir, pin())}.partial`)).size;
    expect(partial).toBeGreaterThan(0);
    expect(partial).toBeLessThan(body.length);
    mode = 'range';
    requests = [];
    const file = await downloadModel(dir, pin());
    expect(requests[0]?.range).toBe(`bytes=${partial}-`);
    expect((await readFile(file)).equals(body)).toBe(true);
  });

  it('reports an http error and a dead server', async () => {
    mode = 'status404';
    const http404 = await downloadModel(dir, pin()).catch((e: unknown) => e);
    expect((http404 as ModelDownloadError).kind).toBe('http');
    const dead = await downloadModel(dir, { ...pin(), url: 'http://127.0.0.1:1/none' }).catch((e: unknown) => e);
    expect((dead as ModelDownloadError).kind).toBe('network');
  });
});

describe('modelAvailability', () => {
  it('tells missing, wrong size and wrong magic from usable', async () => {
    expect(await modelAvailability(dir, pin())).toBe('missing');
    await writeFile(modelFilePath(dir, pin()), body.subarray(0, 100));
    expect(await modelAvailability(dir, pin())).toBe('invalid');
    await writeFile(modelFilePath(dir, pin()), Buffer.concat([Buffer.from('NOPE'), body.subarray(4)]));
    expect(await modelAvailability(dir, pin())).toBe('invalid');
    await writeFile(modelFilePath(dir, pin()), body);
    expect(await modelAvailability(dir, pin())).toBe('usable');
  });

  it('verifyModelFile catches a same-size file with other bytes', async () => {
    await writeFile(modelFilePath(dir, pin()), Buffer.concat([body.subarray(0, 10), Buffer.from('X'), body.subarray(11)]));
    expect(await modelAvailability(dir, pin())).toBe('usable');
    expect(await verifyModelFile(dir, pin())).toBe(false);
  });
});
