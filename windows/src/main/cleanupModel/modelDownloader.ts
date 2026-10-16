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
 * magic. The SHA-256 was checked once, when the file was downloaded; hashing 484 MB per
 * dictation would defeat the point. `verifyModelFile` does the full check.
 */
export async function modelAvailability(directory: string, model: PinnedModelFile): Promise<ModelAvailability> {
  const file = modelFilePath(directory, model);
  let size: number;
  try {
    size = (await stat(file)).size;
  } catch {
    return 'missing';
  }
  if (size !== model.bytes) return 'invalid';
  const handle = await open(file, 'r');
  try {
    const head = Buffer.alloc(4);
    await handle.read(head, 0, 4, 0);
    return head.equals(GGUF_MAGIC) ? 'usable' : 'invalid';
  } finally {
    await handle.close();
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

/** Downloads the model into `directory` and returns its path. A model already in place is kept. */
export async function downloadModel(directory: string, model: PinnedModelFile, options: DownloadOptions = {}): Promise<string> {
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
    let response: Response;
    try {
      const headers: Record<string, string> = have > 0 ? { Range: `bytes=${have}-` } : {};
      response = await fetchImpl(model.url, options.signal ? { headers, signal: options.signal } : { headers });
    } catch (error) {
      throw new ModelDownloadError(`Could not reach the download server: ${message(error)}`, 'network');
    }
    if (response.status !== 200 && response.status !== 206) {
      throw new ModelDownloadError(`The download server answered ${response.status}`, 'http');
    }
    if (!response.body) throw new ModelDownloadError('The download server sent no data', 'network');
    // A server that ignores the range answers 200 with the whole file: start it again.
    if (have > 0 && response.status === 200) have = 0;
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
        const chunk = Buffer.from(step.value);
        await guard('disk', () => handle.write(chunk));
        digest.update(chunk);
        received += chunk.length;
        options.onProgress?.(received, model.bytes);
      }
    } finally {
      await handle.close();
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
  await guard('install', () => rename(partialPath, finalPath));
  return finalPath;
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
