import { spawn } from 'node:child_process';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { ParakeetState, ParakeetVersion } from '../core/models/parakeet.js';
import type { ParakeetWorkerRequest, ParakeetWorkerResponse } from '../core/models/parakeetProtocol.js';
import {
  checkParakeetLanguage,
  PARAKEET_FILES,
  parakeetArchiveUrl,
  parseWavToFloat32,
} from '../core/models/parakeetSupport.js';
import type { Transcript } from '../core/transcription/deepgramProvider.js';
import { ProviderError } from '../core/transcription/deepgramProvider.js';

/** A running recognition process. The default is an Electron utilityProcess. */
export interface ParakeetWorkerHandle {
  postMessage(message: ParakeetWorkerRequest): void;
  onMessage(listener: (message: ParakeetWorkerResponse) => void): void;
  /** Fires once when the process ends for any reason, including kill(). */
  onExit(listener: (reason: string) => void): void;
  kill(): void;
}

export interface ParakeetDeps {
  fetch?: typeof fetch;
  /** Unpack `archive` into the existing empty folder `destDir`. Throws on a bad archive. */
  extract?: (archive: string, destDir: string, signal: AbortSignal) => Promise<void>;
  spawnWorker?: () => Promise<ParakeetWorkerHandle>;
  /** Idle time before the worker is stopped. Default 5 minutes. */
  idleMs?: number;
  /** Time allowed for one recognition. Default 30 s plus the audio length. */
  requestTimeoutMs?: (audioSeconds: number) => number;
}

const MANIFEST = 'parakeet.json';
const PARAKEET_PROVIDER = { provider: 'Parakeet' } as const;
const IDLE_MS = 5 * 60_000;

interface Manifest {
  version: ParakeetVersion;
  files: Record<string, number>;
}

function readState(dir: string, version: ParakeetVersion): ParakeetState {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(dir, MANIFEST), 'utf8')) as Manifest;
    if (manifest.version !== version) return { status: 'notDownloaded' };
    let total = 0;
    for (const name of PARAKEET_FILES) {
      const expected = manifest.files?.[name];
      const actual = fs.statSync(path.join(dir, name)).size;
      if (typeof expected !== 'number' || expected <= 0 || actual !== expected) return { status: 'notDownloaded' };
      total += actual;
    }
    return { status: 'ready', sizeBytes: total };
  } catch {
    return { status: 'notDownloaded' };
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

class Cancelled extends Error {}

/** Windows' own bsdtar reads .tar.bz2; elsewhere `tar` does the same. */
export function defaultExtract(archive: string, destDir: string, signal: AbortSignal): Promise<void> {
  const windowsTar = path.join(process.env.SystemRoot ?? 'C:\\Windows', 'System32', 'tar.exe');
  const exe = process.platform === 'win32' && fs.existsSync(windowsTar) ? windowsTar : 'tar';
  return new Promise((resolve, reject) => {
    // Relative names and cwd keep a drive letter out of the arguments.
    const child = spawn(exe, ['-xjf', path.basename(archive), '-C', path.basename(destDir)], {
      cwd: path.dirname(archive),
      windowsHide: true,
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    let stderr = '';
    child.stderr.on('data', (d: Buffer) => (stderr = (stderr + d.toString()).slice(-500)));
    const onAbort = () => child.kill();
    signal.addEventListener('abort', onAbort, { once: true });
    child.on('error', (e) => {
      signal.removeEventListener('abort', onAbort);
      reject(new Error(`Couldn't start tar: ${e.message}`));
    });
    child.on('close', (code) => {
      signal.removeEventListener('abort', onAbort);
      if (signal.aborted) reject(new Cancelled());
      else if (code === 0) resolve();
      else reject(new Error(`tar failed (${code}): ${stderr.trim()}`));
    });
  });
}

async function defaultSpawnWorker(): Promise<ParakeetWorkerHandle> {
  const { utilityProcess } = await import('electron');
  const script = path.join(path.dirname(fileURLToPath(import.meta.url)), 'parakeetWorker.js');
  const child = utilityProcess.fork(script, [], { serviceName: 'Parakeet' });
  return {
    postMessage: (m) => child.postMessage(m),
    onMessage: (l) => child.on('message', (m: ParakeetWorkerResponse) => l(m)),
    onExit: (l) => child.once('exit', (code) => l(`exit code ${code}`)),
    kill: () => void child.kill(),
  };
}

/**
 * Downloads, deletes and runs the Parakeet models in the main process.
 * Recognition itself runs in a utility process (parakeetWorker.ts).
 */
export class ParakeetModels {
  private readonly listeners = new Set<(states: Record<ParakeetVersion, ParakeetState>) => void>();
  private current: Record<ParakeetVersion, ParakeetState>;
  private readonly active = new Map<ParakeetVersion, { controller: AbortController; promise: Promise<void> }>();
  private readonly fetchImpl: typeof fetch;
  private readonly extractImpl: NonNullable<ParakeetDeps['extract']>;
  private readonly spawnWorker: NonNullable<ParakeetDeps['spawnWorker']>;
  private readonly idleMs: number;
  private readonly timeoutFor: NonNullable<ParakeetDeps['requestTimeoutMs']>;

  private worker: ParakeetWorkerHandle | null = null;
  private starting: Promise<ParakeetWorkerHandle> | null = null;
  private nextId = 1;
  private readonly pending = new Map<number, (response: ParakeetWorkerResponse | Error) => void>();
  private idleTimer: ReturnType<typeof setTimeout> | null = null;
  private disposed = false;
  private readonly inflight = new Map<number, ParakeetVersion>();
  private preloading: Promise<void> | null = null;
  private pinned: ParakeetVersion | null = null;
  /** The version whose model the running worker last loaded. */
  private workerVersion: ParakeetVersion | null = null;

  /** `dataDir` is the app's data folder; models live in `<dataDir>/models/parakeet-<version>/`. */
  constructor(
    readonly dataDir: string,
    deps: ParakeetDeps = {},
  ) {
    this.fetchImpl = deps.fetch ?? fetch;
    this.extractImpl = deps.extract ?? defaultExtract;
    this.spawnWorker = deps.spawnWorker ?? defaultSpawnWorker;
    this.idleMs = deps.idleMs ?? IDLE_MS;
    this.timeoutFor = deps.requestTimeoutMs ?? ((seconds) => 30_000 + Math.ceil(seconds) * 1000);
    this.current = {
      v2: readState(this.modelDir('v2'), 'v2'),
      v3: readState(this.modelDir('v3'), 'v3'),
    };
  }

  states(): Record<ParakeetVersion, ParakeetState> {
    return { v2: { ...this.current.v2 }, v3: { ...this.current.v3 } };
  }

  /** Called with every state change (download progress included). Returns an unsubscribe. */
  onChange(listener: (states: Record<ParakeetVersion, ParakeetState>) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** Starts or resumes a download. Failures land in the `failed` state; this doesn't throw for them. */
  download(version: ParakeetVersion): Promise<void> {
    const running = this.active.get(version);
    if (running) return running.promise;
    if (this.current[version].status === 'ready') return Promise.resolve();
    const controller = new AbortController();
    const promise = this.runDownload(version, controller.signal).finally(() => this.active.delete(version));
    this.active.set(version, { controller, promise });
    return promise;
  }

  /** Stops a download. The partial file is kept so the next download resumes. */
  cancel(version: ParakeetVersion): void {
    this.active.get(version)?.controller.abort();
  }

  async remove(version: ParakeetVersion): Promise<void> {
    const running = this.active.get(version);
    if (running) {
      running.controller.abort();
      await running.promise;
    }
    // Only stop the worker if it holds this model or is working on it; the other version keeps running.
    const versions = [...this.inflight.values()];
    if (versions.includes(version) || (this.workerVersion === version && versions.length === 0)) this.stopWorker();
    await fsp.rm(this.modelDir(version), { recursive: true, force: true });
    await fsp.rm(this.partialPath(version), { force: true });
    this.set(version, { status: 'notDownloaded' });
  }

  /**
   * Transcribe a 16 kHz mono 16-bit WAV. Throws ProviderError('notConfigured') when the model
   * isn't downloaded. Honors `signal`. `language` is the person's pin ('auto' or a code); a
   * language the model doesn't speak fails before any work.
   */
  async transcribe(
    wav: Uint8Array,
    version: ParakeetVersion,
    signal?: AbortSignal,
    language?: string,
  ): Promise<Transcript> {
    const pin = checkParakeetLanguage(version, language);
    if (this.current[version].status !== 'ready') {
      throw new ProviderError('notConfigured', 'Parakeet is not downloaded. Download it in Settings to use it.', PARAKEET_PROVIDER);
    }
    if (signal?.aborted) throw new ProviderError('cancelled', 'Transcription was cancelled.', PARAKEET_PROVIDER);
    const audio = parseWavToFloat32(wav);
    if (audio.samples.length === 0) return { text: '', durationSeconds: 0, detectedLanguage: pin };

    // A preload in flight loads the model once; wait for it rather than loading twice.
    if (this.preloading) await this.preloading;
    const response = await this.exchange(version, audio.samples, audio.sampleRate, audio.durationSeconds, signal, false);
    if (!response.ok) {
      throw new ProviderError('transport', `Parakeet couldn't transcribe: ${response.error}`, PARAKEET_PROVIDER);
    }
    return { text: response.text, durationSeconds: audio.durationSeconds, detectedLanguage: pin };
  }

  /**
   * Start the worker and load the model in the background when it is downloaded and not loaded.
   * A no-op otherwise. Never throws; failures are logged.
   */
  preload(version: ParakeetVersion): void {
    if (this.disposed || this.preloading || this.current[version].status !== 'ready') return;
    if (this.worker && this.workerVersion === version) return;
    const task = this.exchange(version, new Float32Array(0), 16000, 0, undefined, true)
      .then((r) => {
        if (!r.ok) console.warn(`Parakeet ${version} preload failed: ${r.error}`);
      })
      .catch((e: unknown) => console.warn(`Parakeet ${version} preload failed: ${errorMessage(e)}`))
      .finally(() => {
        if (this.preloading === task) this.preloading = null;
      });
    this.preloading = task;
  }

  /** The pinned version's worker is never stopped by the idle timer. Null unpins. */
  setPinned(version: ParakeetVersion | null): void {
    this.pinned = version;
    this.armIdle();
  }

  private async exchange(
    version: ParakeetVersion,
    samples: Float32Array,
    sampleRate: number,
    seconds: number,
    signal: AbortSignal | undefined,
    loadOnly: boolean,
  ): Promise<ParakeetWorkerResponse> {
    const worker = await this.ensureWorker();
    if (signal?.aborted) throw new ProviderError('cancelled', 'Transcription was cancelled.', PARAKEET_PROVIDER);
    this.clearIdle();

    const id = this.nextId++;
    this.inflight.set(id, version);
    return new Promise<ParakeetWorkerResponse>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const finish = () => {
        if (timer) clearTimeout(timer);
        signal?.removeEventListener('abort', onAbort);
        this.pending.delete(id);
        this.inflight.delete(id);
      };
      // The result of a cancelled request is dropped, the process keeps its loaded model.
      const onAbort = () => {
        finish();
        reject(new ProviderError('cancelled', 'Transcription was cancelled.', PARAKEET_PROVIDER));
      };
      this.pending.set(id, (r) => {
        finish();
        if (r instanceof Error) reject(r);
        else {
          if (r.ok && this.worker === worker) this.workerVersion = version;
          resolve(r);
        }
      });
      signal?.addEventListener('abort', onAbort, { once: true });
      timer = setTimeout(() => {
        finish();
        // A stuck recognition can't be interrupted, so the process goes and the next request restarts it.
        this.stopWorker();
        reject(new ProviderError('timedOut', 'Parakeet took too long. Try again.', PARAKEET_PROVIDER));
      }, this.timeoutFor(seconds));
      try {
        worker.postMessage({ id, modelDir: this.modelDir(version), samples, sampleRate, loadOnly });
      } catch (e) {
        finish();
        reject(new ProviderError('transport', `Parakeet couldn't start: ${errorMessage(e)}`, PARAKEET_PROVIDER));
      }
    }).finally(() => this.armIdle());
  }

  /** Stop any worker process and downloads. Called at quit. */
  dispose(): void {
    this.disposed = true;
    for (const { controller } of this.active.values()) controller.abort();
    this.stopWorker();
    this.listeners.clear();
  }

  // MARK: worker

  private async ensureWorker(): Promise<ParakeetWorkerHandle> {
    if (this.disposed) throw new ProviderError('cancelled', 'Parakeet is shutting down.', PARAKEET_PROVIDER);
    if (this.worker) return this.worker;
    this.starting ??= this.spawnWorker()
      .then((w) => {
        w.onMessage((m) => this.pending.get(m.id)?.(m));
        w.onExit((reason) => {
          if (this.worker !== w) return;
          this.worker = null;
          this.workerVersion = null;
          this.clearIdle();
          this.failPending(reason);
        });
        if (this.disposed) {
          w.kill();
          throw new ProviderError('cancelled', 'Parakeet is shutting down.', PARAKEET_PROVIDER);
        }
        this.worker = w;
        return w;
      })
      .catch((e: unknown) => {
        throw e instanceof ProviderError
          ? e
          : new ProviderError('transport', `Couldn't start the Parakeet engine: ${errorMessage(e)}`, PARAKEET_PROVIDER);
      })
      .finally(() => {
        this.starting = null;
      });
    return this.starting;
  }

  private failPending(reason: string): void {
    console.warn(`Parakeet worker ended: ${reason}`);
    const error = new ProviderError('transport', 'Parakeet stopped unexpectedly. Try again.', PARAKEET_PROVIDER);
    for (const resolve of [...this.pending.values()]) resolve(error);
  }

  private stopWorker(): void {
    this.clearIdle();
    const worker = this.worker;
    this.worker = null;
    this.workerVersion = null;
    if (worker) worker.kill();
    if (this.pending.size > 0) this.failPending('stopped');
  }

  private armIdle(): void {
    this.clearIdle();
    if (!this.worker || this.pending.size > 0) return;
    if (this.pinned !== null && this.pinned === this.workerVersion) return;
    this.idleTimer = setTimeout(() => this.stopWorker(), this.idleMs);
    this.idleTimer.unref?.();
  }

  private clearIdle(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = null;
  }

  // MARK: paths and state

  private modelsRoot(): string {
    return path.join(this.dataDir, 'models');
  }

  private modelDir(version: ParakeetVersion): string {
    return path.join(this.modelsRoot(), `parakeet-${version}`);
  }

  private partialPath(version: ParakeetVersion): string {
    return path.join(this.modelsRoot(), `parakeet-${version}.partial`);
  }

  private set(version: ParakeetVersion, state: ParakeetState): void {
    this.current = { ...this.current, [version]: state };
    if (this.disposed) return;
    const snapshot = this.states();
    for (const listener of [...this.listeners]) listener(snapshot);
  }

  // MARK: download

  private async runDownload(version: ParakeetVersion, signal: AbortSignal): Promise<void> {
    const root = this.modelsRoot();
    const partial = this.partialPath(version);
    const tmp = path.join(root, `.parakeet-${version}.extract`);
    this.set(version, { status: 'downloading', progress: null });
    try {
      await fsp.mkdir(root, { recursive: true });
      await this.fetchArchive(version, partial, signal);
      // Progress stays at the end while the archive unpacks.
      await fsp.rm(tmp, { recursive: true, force: true });
      await fsp.mkdir(tmp);
      try {
        await this.extractImpl(partial, tmp, signal);
      } catch (e) {
        if (signal.aborted) throw new Cancelled();
        await fsp.rm(partial, { force: true });
        throw new Error(`The download is damaged and was removed. Try again. (${errorMessage(e)})`);
      }
      if (signal.aborted) throw new Cancelled();
      const source = await this.findModelFolder(tmp);
      const manifest = await this.verify(source, version);
      await fsp.writeFile(path.join(source, MANIFEST), JSON.stringify(manifest), 'utf8');
      const final = this.modelDir(version);
      await fsp.rm(final, { recursive: true, force: true });
      await fsp.rename(source, final);
      await fsp.rm(tmp, { recursive: true, force: true });
      await fsp.rm(partial, { force: true });
      this.set(version, readState(final, version));
      this.preload(version);
    } catch (error) {
      await fsp.rm(tmp, { recursive: true, force: true }).catch(() => undefined);
      if (error instanceof Cancelled || signal.aborted) {
        this.set(version, readState(this.modelDir(version), version));
      } else {
        this.set(version, { status: 'failed', message: errorMessage(error) });
      }
    }
  }

  private async fetchArchive(version: ParakeetVersion, partial: string, signal: AbortSignal): Promise<void> {
    let have = 0;
    try {
      have = (await fsp.stat(partial)).size;
    } catch {
      have = 0;
    }
    let response: Response;
    try {
      response = await this.fetchImpl(parakeetArchiveUrl(version), {
        signal,
        headers: have > 0 ? { Range: `bytes=${have}-` } : {},
      });
    } catch (e) {
      if (signal.aborted) throw new Cancelled();
      throw new Error(`Couldn't reach the download server. Check your connection and try again. (${errorMessage(e)})`);
    }
    if (response.status === 416 && have > 0) {
      // The partial file is not usable for this archive; start over.
      await fsp.rm(partial, { force: true });
      return this.fetchArchive(version, partial, signal);
    }
    if (response.status !== 200 && response.status !== 206) {
      throw new Error(`The download failed (HTTP ${response.status}). Try again later.`);
    }
    const resumed = response.status === 206 && have > 0;
    if (!resumed) have = 0;
    const length = Number(response.headers.get('content-length'));
    const total = Number.isFinite(length) && length > 0 ? have + length : null;
    if (!response.body) throw new Error('The download server sent no data.');

    const handle = await fsp.open(partial, resumed ? 'a' : 'w');
    let received = have;
    let lastEmit = 0;
    try {
      const reader = response.body.getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        await handle.write(value);
        received += value.byteLength;
        const now = Date.now();
        if (now - lastEmit >= 200) {
          lastEmit = now;
          this.set(version, { status: 'downloading', progress: total ? Math.min(1, received / total) : null });
        }
      }
    } catch (e) {
      if (signal.aborted) throw new Cancelled();
      throw new Error(`The download was interrupted. Try again to continue. (${errorMessage(e)})`);
    } finally {
      await handle.close();
    }
    if (total !== null && received !== total) {
      throw new Error('The download was cut short. Try again to continue.');
    }
    this.set(version, { status: 'downloading', progress: 1 });
  }

  /** The archive holds one folder; accept the files at the top level too. */
  private async findModelFolder(tmp: string): Promise<string> {
    const candidates = [tmp];
    for (const entry of await fsp.readdir(tmp, { withFileTypes: true })) {
      if (entry.isDirectory()) candidates.push(path.join(tmp, entry.name));
    }
    for (const dir of candidates) {
      if (fs.existsSync(path.join(dir, PARAKEET_FILES[0]))) return dir;
    }
    throw new Error('The download is missing model files. Try again.');
  }

  private async verify(dir: string, version: ParakeetVersion): Promise<Manifest> {
    const files: Record<string, number> = {};
    for (const name of PARAKEET_FILES) {
      let size = 0;
      try {
        size = (await fsp.stat(path.join(dir, name))).size;
      } catch {
        size = 0;
      }
      if (size <= 0) throw new Error(`The download is missing ${name}. Try again.`);
      files[name] = size;
    }
    return { version, files };
  }
}
