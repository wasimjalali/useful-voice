/**
 * The numbers and gates that decide whether the local cleanup model runs. Mirrors
 * `Sources/UsefulVoiceCore/CleanupModel/CleanupModelPolicy.swift` rule for rule.
 */

/** How long the pipeline waits for the model before it uses the rules-only text. */
export const DEFAULT_CLEANUP_DEADLINE_MS = 1500;

/** How long the model stays loaded after the last dictation. */
export const DEFAULT_CLEANUP_IDLE_UNLOAD_MS = 60_000;

/**
 * AI cleanup stays off below 8 GB of RAM. The check is "at least 7 GiB reported", on both
 * platforms: a PC sold with 8 GB reports 7.0 to 7.9 GiB from `os.totalmem()` because the
 * hardware reserves some (integrated graphics, firmware), while a Mac sold with 8 GB reports
 * exactly 8 GiB. A 6 GB machine reports at most about 5.9 GiB, so it stays off.
 */
export const MINIMUM_CLEANUP_MEMORY_BYTES = 7 * 1024 ** 3;

export function memoryAllowsCleanupModel(physicalMemoryBytes: number): boolean {
  return physicalMemoryBytes >= MINIMUM_CLEANUP_MEMORY_BYTES;
}

export type CleanupSkipReason = 'flagOff' | 'modelNotDownloaded' | 'notEnoughMemory' | 'notEnglish' | 'noModel';

export type CleanupModelDecision = { run: true } | { run: false; reason: CleanupSkipReason };

export interface CleanupGates {
  flagOn: boolean;
  modelInstalled: boolean;
  physicalMemoryBytes: number;
}

/**
 * Whether the model step runs. Checked in this order, so the reason reported is the first
 * one that applies. The model is English only, like the rules.
 */
export function decideCleanupModel(gates: CleanupGates, language: string | null | undefined): CleanupModelDecision {
  if (!gates.flagOn) return { run: false, reason: 'flagOff' };
  if (!gates.modelInstalled) return { run: false, reason: 'modelNotDownloaded' };
  if (!memoryAllowsCleanupModel(gates.physicalMemoryBytes)) return { run: false, reason: 'notEnoughMemory' };
  const code = language?.toLowerCase();
  if (code !== 'en' && !code?.startsWith('en-')) return { run: false, reason: 'notEnglish' };
  return { run: true };
}

/** The `--cleanup-model` switch and the environment variable that turn the hidden flag on. */
export const CLEANUP_MODEL_SWITCH = '--cleanup-model';
export const CLEANUP_MODEL_ENV_KEY = 'UV_CLEANUP_MODEL';

const TRUTHY = new Set(['1', 'true', 'yes', 'on']);

/**
 * The hidden flag. There is no visible control in this phase: it is read once at launch
 * from the `--cleanup-model` switch or the `UV_CLEANUP_MODEL` environment variable, and it
 * is off by default. The variable wins when it is set, so `UV_CLEANUP_MODEL=0` turns off a
 * switch left in a shortcut; macOS reads its environment variable the same way.
 */
export function resolveCleanupModelFlag(argv: readonly string[], env: Record<string, string | undefined>): boolean {
  const raw = env[CLEANUP_MODEL_ENV_KEY];
  if (raw !== undefined) return TRUTHY.has(raw.trim().toLowerCase());
  return argv.includes(CLEANUP_MODEL_SWITCH);
}
