import { createHash, type Hash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, open, rename, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import type { PinnedModelFile } from '../../core/formatting/s1MiniModel.js';

/**
 * Fetches a pinned model file from Hugging Face with progress and resume. The Windows app
 * had no model downloader before (it only talks to Deepgram), so this is the Windows
 * counterpart of macOS `ModelDownloader`: same rules, same failure kinds.
 *
 * - The bytes stream to `<file>.partial`, never into memory, and only a file whose size and
 *   SHA-256 match the pins is renamed into place. A failed check deletes the partial, so a
 *   poisoned file is never left on disk.
 * - A partial from an earlier attempt resumes with a `Range` request. The bytes already on
 *   disk are hashed first, so the final SHA-256 still covers the whole file. A server that
 *   answers 200 instead of 206 starts the file again.
 * - The URL carries the pinned revision, so the bytes cannot change under the hash.
 */
export type ModelDownloadFailureKind = 'disk' | 'network' | 'http' | 'validation' | 'install';

export class ModelDownloadError extends Error {
  constructor(
    message: string,
    readonly kind: ModelDownloadFailureKind,
  ) {
    super(message);
    this.name = 'ModelDownloadError';
  }
}

export type DownloadFetch = (url: string, init: { headers: Record<string, string>; signal?: AbortSignal }) => Promise<Response>;

export interface DownloadOptions {
  fetchImpl?: DownloadFetch;
  onProgress?: (received: number, total: number) => void;
  signal?: AbortSignal;
}

/** `GGUF`, the first four bytes of every GGUF file. */
const GGUF_MAGIC = Buffer.from('GGUF');

export function modelFilePath(directory: string, model: PinnedModelFile): string {
  return path.join(directory, model.fileName);
}

export type ModelAvailability = 'missing' | 'usable' | 'invalid';

/**
 * Cheap check run on every dictation: the file has the pinned size and starts with the GGUF
 * magic. It never throws: any I/O error means the model is not usable. The SHA-256 was checked once, when the file was downloaded; hashing 484 MB per
 * dictation would defeat the point. `verifyModelFile` does the full check.
 */
export async function modelAvailability(directory: string, model: PinnedModelFile): Promise<ModelAvailability> {
  const file = modelFilePath(directory, model);
  try {
    if ((await stat(file)).size !== model.bytes) return 'invalid';
    // The file can vanish or be locked between the stat and the open: that is "not usable",
    // never an error for the caller (it runs on every dictation).
    const handle = await open(file, 'r');
    try {
      const head = Buffer.alloc(4);
      await handle.read(head, 0, 4, 0);
      return head.equals(GGUF_MAGIC) ? 'usable' : 'invalid';
    } finally {
      await handle.close().catch(() => undefined);
    }
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'ENOENT' ? 'missing' : 'invalid';
  }
}

export async function sha256OfFile(file: string): Promise<string> {
  const hash = createHash('sha256');
  await hashPrefix(file, undefined, hash);
  return hash.digest('hex');
}

/** Feeds the first `length` bytes of `file` (all of it when omitted) to `hash`. */
async function hashPrefix(file: string, length: number | undefined, hash: Hash): Promise<void> {
  if (length === 0) return;
  const options = length === undefined ? {} : { start: 0, end: length - 1 };
  for await (const chunk of createReadStream(file, options)) hash.update(chunk as Buffer);
}

/** The full check: pinned size and SHA-256. */
export async function verifyModelFile(directory: string, model: PinnedModelFile): Promise<boolean> {
  const file = modelFilePath(directory, model);
  try {
    if ((await stat(file)).size !== model.bytes) return false;
    return (await sha256OfFile(file)) === model.sha256;
  } catch {
    return false;
  }
}

const inFlight = new Map<string, Promise<string>>();

/**
 * Downloads the model into `directory` and returns its path. A model already in place is
 * kept. A second call for the same file while one is running joins it (its `onProgress` and
 * `signal` are not used), so two partial writers never share one `.partial`.
 */
export function downloadModel(directory: string, model: PinnedModelFile, options: DownloadOptions = {}): Promise<string> {
  const key = modelFilePath(directory, model);
  const running = inFlight.get(key);
  if (running) return running;
  const started = downloadOnce(directory, model, options).finally(() => inFlight.delete(key));
  inFlight.set(key, started);
  return started;
}

async function downloadOnce(directory: string, model: PinnedModelFile, options: DownloadOptions): Promise<string> {
  const fetchImpl: DownloadFetch = options.fetchImpl ?? ((url, init) => fetch(url, init));
  const finalPath = modelFilePath(directory, model);
  const partialPath = `${finalPath}.partial`;
  await guard('install', () => mkdir(directory, { recursive: true }));
  if ((await modelAvailability(directory, model)) === 'usable') return finalPath;

  let have = 0;
  try {
    have = (await stat(partialPath)).size;
  } catch {
    have = 0;
  }
  if (have > model.bytes) {
    await rm(partialPath, { force: true });
    have = 0;
  }

  let received = have;
  const digest = createHash('sha256');

  if (have < model.bytes) {
    let response: Response | null = null;
    for (let attempt = 0; attempt < 2 && !response; attempt++) {
      let candidate: Response;
      try {
        const headers: Record<string, string> = have > 0 ? { Range: `bytes=${have}-` } : {};
        candidate = await fetchImpl(model.url, options.signal ? { headers, signal: options.signal } : { headers });
      } catch (error) {
        throw new ModelDownloadError(`Could not reach the download server: ${message(error)}`, 'network');
      }
      if (candidate.status !== 200 && candidate.status !== 206) {
        throw new ModelDownloadError(`The download server answered ${candidate.status}`, 'http');
      }
      if (!candidate.body) throw new ModelDownloadError('The download server sent no data', 'network');
      if (have > 0 && candidate.status === 200) {
        // A server that ignores the range sends the whole file: start it again.
        have = 0;
      } else if (candidate.status === 206 && contentRangeStart(candidate) !== have) {
        // It answered with a range, but not the one asked for: appending would corrupt the file.
        await candidate.body.cancel().catch(() => undefined);
        await rm(partialPath, { force: true });
        have = 0;
        continue;
      }
      response = candidate;
    }
    if (!response?.body) throw new ModelDownloadError('The download server answered with the wrong range', 'http');
    received = have;
    await hashPrefix(partialPath, have, digest);

    const handle = await guard('disk', () => open(partialPath, have > 0 ? 'a' : 'w'));
    try {
      const reader = response.body.getReader();
      for (;;) {
        let step: ReadableStreamReadResult<Uint8Array>;
        try {
          step = await reader.read();
        } catch (error) {
          throw new ModelDownloadError(`The download was interrupted: ${message(error)}`, 'network');
        }
        if (step.done) break;
        if (received + step.value.length > model.bytes) {
          await reader.cancel().catch(() => undefined);
          await handle.close().catch(() => undefined);
          await rm(partialPath, { force: true });
          throw new ModelDownloadError(`The download is longer than the ${model.bytes} bytes expected`, 'validation');
        }
        const chunk = Buffer.from(step.value);
        let written = 0;
        while (written < chunk.length) {
          const { bytesWritten } = await guard('disk', () => handle.write(chunk, written, chunk.length - written));
          written += bytesWritten;
        }
        digest.update(chunk);
        received += chunk.length;
        options.onProgress?.(received, model.bytes);
      }
    } finally {
      await handle.close().catch(() => undefined);
    }
  } else {
    await hashPrefix(partialPath, have, digest);
  }

  if (received !== model.bytes) {
    // Keep the partial: the next attempt resumes from it.
    throw new ModelDownloadError(`The download ended at ${received} of ${model.bytes} bytes`, 'network');
  }
  if (digest.digest('hex') !== model.sha256) {
    await rm(partialPath, { force: true });
    throw new ModelDownloadError('The downloaded file does not match its checksum', 'validation');
  }
  // The hash covers the bytes we counted; this checks the file really holds them.
  if ((await guard('install', () => stat(partialPath))).size !== model.bytes) {
    await rm(partialPath, { force: true });
    throw new ModelDownloadError('The downloaded file is not the size that was written', 'validation');
  }
  await guard('install', () => rename(partialPath, finalPath));
  return finalPath;
}

/** The first byte of a 206 response's `Content-Range: bytes <start>-<end>/<total>`, or null. */
function contentRangeStart(response: Response): number | null {
  const match = /^bytes (\d+)-/.exec(response.headers.get('content-range') ?? '');
  return match ? Number(match[1]) : null;
}

async function guard<T>(kind: ModelDownloadFailureKind, work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (error) {
    if (error instanceof ModelDownloadError) throw error;
    const code = (error as NodeJS.ErrnoException).code;
    throw new ModelDownloadError(message(error), code === 'ENOSPC' ? 'disk' : kind);
  }
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
