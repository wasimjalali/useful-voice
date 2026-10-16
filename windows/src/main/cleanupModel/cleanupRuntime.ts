import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { CleanupModel } from '../../core/formatting/cleanupModel.js';
import {
  DEFAULT_CLEANUP_DEADLINE_MS,
  DEFAULT_CLEANUP_IDLE_UNLOAD_MS,
  memoryAllowsCleanupModel,
  resolveCleanupModelFlag,
  type CleanupGates,
} from '../../core/formatting/cleanupModelPolicy.js';
import { runCleanupPipeline, type CleanupResult } from '../../core/formatting/cleanupPipeline.js';
import { LocalCleanupModel } from '../../core/formatting/localCleanupModel.js';
import { S1_MINI_MODEL } from '../../core/formatting/s1MiniModel.js';
import { LlamaCleanupGenerator } from './llamaGenerator.js';
import { downloadModel, modelAvailability, modelFilePath, type DownloadOptions } from './modelDownloader.js';

/**
 * Everything the app needs from the hidden S1-mini cleanup, behind one object. Phase 1 ships
 * it unwired. The hookup at the cleanup marker is:
 *
 *   const cleanup = createCleanupRuntime({ userDataDir: app.getPath('userData'), argv: process.argv, env: process.env });
 *   ...
 *   cleanup.beginDictation();                       // hotkey down: load while the person talks
 *   const { text } = await cleanup.run({ raw, language, category, style });
 *   cleanup.endDictation();                         // dictation over or cancelled: idle timer
 *   ...
 *   await cleanup.dispose();                        // before quit
 *
 * With the flag off (the default) nothing here touches the disk, spawns a process or loads
 * node-llama-cpp: `run` is just the rules.
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
  /** The live gates: the hidden flag, the pinned weights present, this machine's RAM. */
  gates(): Promise<CleanupGates>;
  beginDictation(): void;
  endDictation(): void;
  run(input: CleanupRunInput): Promise<CleanupResult>;
  /** Fetches the pinned weights into `modelDirectory` (no UI in this phase). */
  download(options?: DownloadOptions): Promise<string>;
  /** Frees the model now. */
  dispose(): Promise<void>;
}

export function createCleanupRuntime(options: CleanupRuntimeOptions): CleanupRuntime {
  const flagOn = resolveCleanupModelFlag(options.argv, options.env);
  const modelDirectory = path.join(options.userDataDir, 'models');
  const physicalMemoryBytes = options.totalMemoryBytes ?? os.totalmem();
  const warn = options.warn ?? (() => undefined);

  let local: LocalCleanupModel | null = null;
  const model = (): LocalCleanupModel | null => {
    if (!flagOn) return null;
    local ??= new LocalCleanupModel({
      modelPath: modelFilePath(modelDirectory, S1_MINI_MODEL),
      generator: new LlamaCleanupGenerator({
        workerScript: options.workerScript ?? fileURLToPath(new URL('./cleanupWorker.js', import.meta.url)),
        warn,
      }),
      idleUnloadMs: options.idleUnloadMs ?? DEFAULT_CLEANUP_IDLE_UNLOAD_MS,
      warn,
    });
    return local;
  };

  const gates = async (): Promise<CleanupGates> => ({
    flagOn,
    modelInstalled: flagOn && (await modelAvailability(modelDirectory, S1_MINI_MODEL)) === 'usable',
    physicalMemoryBytes,
  });

  return {
    flagOn,
    modelDirectory,
    gates,
    beginDictation() {
      // Load only when the pipeline would run the model, so a machine that can't or won't
      // use it never pays for the load.
      if (!flagOn) return;
      void gates().then((g) => {
        if (g.modelInstalled && memoryAllowsCleanupModel(g.physicalMemoryBytes)) void model()?.begin();
      });
    },
    endDictation() {
      local?.end();
    },
    async run(input) {
      const current: CleanupGates = await gates();
      const active: CleanupModel | null = current.flagOn && current.modelInstalled ? model() : null;
      return runCleanupPipeline({
        ...input,
        gates: current,
        model: active,
        deadlineMs: options.deadlineMs ?? DEFAULT_CLEANUP_DEADLINE_MS,
      });
    },
    download: (downloadOptions) => downloadModel(modelDirectory, S1_MINI_MODEL, downloadOptions),
    async dispose() {
      await local?.unload();
    },
  };
}
