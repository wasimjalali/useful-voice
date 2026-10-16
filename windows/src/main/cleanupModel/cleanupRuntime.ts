import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { CleanupModel, CleanupTextGenerator } from '../../core/formatting/cleanupModel.js';
import {
  DEFAULT_CLEANUP_DEADLINE_MS,
  DEFAULT_CLEANUP_IDLE_UNLOAD_MS,
  decideCleanupModel,
  resolveCleanupModelFlag,
  type CleanupGates,
} from '../../core/formatting/cleanupModelPolicy.js';
import { runCleanupPipeline, type CleanupResult } from '../../core/formatting/cleanupPipeline.js';
import { LocalCleanupModel, type CleanupClock } from '../../core/formatting/localCleanupModel.js';
import { S1_MINI_MODEL } from '../../core/formatting/s1MiniModel.js';
import type { CleanupPort } from '../dictationService.js';
import { LlamaCleanupGenerator } from './llamaGenerator.js';
import { downloadModel, modelAvailability, modelFilePath, type DownloadOptions, type ModelAvailability } from './modelDownloader.js';

/**
 * Everything the app needs from the hidden S1-mini cleanup, behind one object. Phase 1 ships
 * it unwired. The hookup at the cleanup marker is:
 *
 *   const cleanup = createCleanupRuntime({ userDataDir: app.getPath('userData'), argv: process.argv, env: process.env });
 *   ...
 *   cleanup.beginDictation(language);               // hotkey down: load while the person talks
 *   const { text } = await cleanup.run({ raw, language, category, style });
 *   cleanup.endDictation();                         // dictation over or cancelled: idle timer
 *   ...
 *   await cleanup.dispose();                        // before quit
 *
 * Nothing here ever costs a dictation: `run` does not reject, whatever fails (the disk, the
 * worker, the model) it answers with the rules text, and its disk check is inside the
 * deadline. With the flag off (the default) nothing touches the disk, spawns a process or
 * loads node-llama-cpp: `run` is just the rules.
 */
export interface CleanupRuntimeOptions {
  userDataDir: string;
  argv: readonly string[];
  env: Record<string, string | undefined>;
  /** Total RAM in bytes. Defaults to `os.totalmem()`. */
  totalMemoryBytes?: number;
  deadlineMs?: number;
  idleUnloadMs?: number;
  warn?: (message: string) => void;
  /** Path of the compiled worker. Defaults to the one next to this file. */
  workerScript?: string;
  /** Test seams. */
  generator?: CleanupTextGenerator;
  checkModel?: (directory: string) => Promise<ModelAvailability>;
  clock?: CleanupClock;
}

export interface CleanupRunInput {
  raw: string;
  language: string | null | undefined;
  category: string | null | undefined;
  style: string | null | undefined;
}

export interface CleanupRuntime {
  readonly flagOn: boolean;
  readonly modelDirectory: string;
  /** The live gates: the hidden flag, the pinned weights present, this machine's RAM. Never rejects. */
  gates(): Promise<CleanupGates>;
  /**
   * A dictation started. Loads the model while the person talks, when it would be used.
   * Pass the language when it is known: a language other than English loads nothing.
   */
  beginDictation(language?: string | null): void;
  /** The dictation ended or was cancelled. */
  endDictation(): void;
  /** Never rejects. */
  run(input: CleanupRunInput): Promise<CleanupResult>;
  /** Fetches the pinned weights into `modelDirectory` (no UI in this phase). One at a time. */
  download(options?: DownloadOptions): Promise<string>;
  /** Frees the model now and for good. */
  dispose(): Promise<void>;
}

export function createCleanupRuntime(options: CleanupRuntimeOptions): CleanupRuntime {
  const flagOn = resolveCleanupModelFlag(options.argv, options.env);
  const modelDirectory = path.join(options.userDataDir, 'models');
  const physicalMemoryBytes = options.totalMemoryBytes ?? os.totalmem();
  const warn = options.warn ?? (() => undefined);
  const deadlineMs = options.deadlineMs ?? DEFAULT_CLEANUP_DEADLINE_MS;
  const checkModel = options.checkModel ?? ((directory: string) => modelAvailability(directory, S1_MINI_MODEL));

  let local: LocalCleanupModel | null = null;
  let disposed = false;
  const model = (): LocalCleanupModel | null => {
    if (!flagOn || disposed) return null;
    local ??= new LocalCleanupModel({
      modelPath: modelFilePath(modelDirectory, S1_MINI_MODEL),
      generator:
        options.generator ??
        new LlamaCleanupGenerator({
          workerScript: options.workerScript ?? fileURLToPath(new URL('./cleanupWorker.js', import.meta.url)),
          warn,
        }),
      idleUnloadMs: options.idleUnloadMs ?? DEFAULT_CLEANUP_IDLE_UNLOAD_MS,
      ...(options.clock ? { clock: options.clock } : {}),
      warn,
    });
    return local;
  };

  // Once the file has been seen usable it stays that way for this run; a file deleted later
  // makes the load fail, which is a null answer. "Not usable" is never cached, so a finished
  // download is seen at once.
  let seenInstalled = false;
  const installed = async (): Promise<boolean> => {
    if (!flagOn) return false;
    if (seenInstalled) return true;
    try {
      seenInstalled = (await checkModel(modelDirectory)) === 'usable';
    } catch (error) {
      warn(`cleanup model check failed: ${error instanceof Error ? error.message : String(error)}`);
    }
    return seenInstalled;
  };

  const gates = async (): Promise<CleanupGates> => ({
    flagOn,
    modelInstalled: await installed(),
    physicalMemoryBytes,
  });

  /** Gates, but never later than `ms`: a slow disk counts as "model not installed". */
  const gatesWithin = (ms: number): Promise<CleanupGates> =>
    new Promise((resolve) => {
      const timer = setTimeout(() => resolve({ flagOn, modelInstalled: false, physicalMemoryBytes }), ms);
      gates().then(
        (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        () => {
          clearTimeout(timer);
          resolve({ flagOn, modelInstalled: false, physicalMemoryBytes });
        },
      );
    });

  /** The rules, and nothing else. What every failure falls back to. */
  const rulesOnly = async (input: CleanupRunInput): Promise<CleanupResult> => {
    try {
      return await runCleanupPipeline({
        ...input,
        gates: { flagOn: false, modelInstalled: false, physicalMemoryBytes },
        model: null,
      });
    } catch (error) {
      warn(`cleanup rules failed: ${error instanceof Error ? error.message : String(error)}`);
      return { text: input.raw, source: 'raw' };
    }
  };

  // Dictations in progress, newest last. A preload that finds its dictation already over
  // (the gates took longer than the dictation) loads nothing.
  const open: { ended: boolean; began: boolean }[] = [];

  return {
    flagOn,
    modelDirectory,
    gates: async () => {
      try {
        return await gates();
      } catch {
        return { flagOn, modelInstalled: false, physicalMemoryBytes };
      }
    },
    beginDictation(language) {
      if (!flagOn || disposed) return;
      const session = { ended: false, began: false };
      open.push(session);
      void (async () => {
        const g = await gates();
        if (session.ended || !g.modelInstalled) return;
        // An unknown language (undefined) preloads; a known one must be English, as in `run`.
        if (!decideCleanupModel(g, language === undefined ? 'en' : language).run) return;
        const target = model();
        if (!target) return;
        session.began = true;
        void target.begin();
      })().catch((error: unknown) => warn(`cleanup model preload failed: ${error instanceof Error ? error.message : String(error)}`));
    },
    endDictation() {
      const session = open.pop();
      if (!session) return;
      session.ended = true;
      if (session.began) local?.end();
    },
    async run(input) {
      try {
        const started = performance.now();
        const current = await gatesWithin(deadlineMs);
        const active: CleanupModel | null = current.flagOn && current.modelInstalled ? model() : null;
        return await runCleanupPipeline({
          ...input,
          gates: current,
          model: active,
          // The disk check came out of the same budget as the model.
          deadlineMs: Math.max(0, deadlineMs - (performance.now() - started)),
        });
      } catch (error) {
        warn(`cleanup failed, using the rules text: ${error instanceof Error ? error.message : String(error)}`);
        return rulesOnly(input);
      }
    },
    download: (downloadOptions) => downloadModel(modelDirectory, S1_MINI_MODEL, downloadOptions),
    async dispose() {
      disposed = true;
      try {
        await local?.dispose();
      } catch (error) {
        warn(`cleanup model dispose failed: ${error instanceof Error ? error.message : String(error)}`);
      }
    },
  };
}

/**
 * What the dictation service gets. Undefined with the flag off, so the service runs its
 * own cleanup-rules step exactly as it did before this feature existed; there is no
 * "off" mode of the model path, only the absence of it.
 */
export function cleanupPortFor(runtime: CleanupRuntime): CleanupPort | undefined {
  return runtime.flagOn ? { run: (input) => runtime.run(input) } : undefined;
}

/** The pinned language to preload for, or undefined when it is not known before the audio. */
export function preloadLanguage(languagePin: string): string | undefined {
  const pin = languagePin.trim().toLowerCase();
  return pin === '' || pin === 'auto' || pin === 'multi' ? undefined : pin;
}
