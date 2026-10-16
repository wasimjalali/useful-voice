import { promises as fs } from 'node:fs';
import path from 'node:path';

/**
 * How a load attempt ended.
 *
 * The macOS implementation collapsed three very different situations into "no
 * data": the file is absent (fine), the file is unreadable RIGHT NOW (transient —
 * a lock held by a backup or sync tool), and the file is genuinely corrupt. In the
 * first and second cases the store started empty and the next mutation wrote that
 * empty state over the real file, so one transient read error at launch became
 * permanent loss of the user's dictionary.
 */
export type LoadOutcome =
  | { status: 'fresh' }
  | { status: 'loaded'; migratedFrom?: number }
  | { status: 'unreadable'; error: string }
  | { status: 'corrupt'; quarantinedTo: string }
  | { status: 'incompatible'; version: number };

export interface LoadResult<T> {
  outcome: LoadOutcome;
  value: T | null;
  /**
   * Whether writing is allowed. False for an unreadable or newer-version file:
   * saving would destroy data we could not read.
   */
  writable: boolean;
}

/** Read and JSON-parse a file, distinguishing the failure modes. */
export async function readJson<T>(filePath: string): Promise<LoadResult<T>> {
  let text: string;
  try {
    text = await fs.readFile(filePath, 'utf8');
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    if (code === 'ENOENT') {
      // Never saved yet: a clean start, and writing is fine.
      return { outcome: { status: 'fresh' }, value: null, writable: true };
    }
    // Anything else is a real read failure. Keep the file, do NOT allow writes:
    // the on-disk data is presumably intact and the next save would clobber it
    // with an empty store.
    return {
      outcome: { status: 'unreadable', error: describe(error) },
      value: null,
      writable: false,
    };
  }

  try {
    return { outcome: { status: 'loaded' }, value: JSON.parse(text) as T, writable: true };
  } catch {
    // Parsing failed, so the content really is malformed. Move it aside under a
    // TIMESTAMPED name rather than a fixed ".bak": a fixed name meant a second
    // incident destroyed the first one's evidence before quarantining the new
    // file, leaving only one generation.
    // Two incidents inside one millisecond would share the timestamp, so a taken
    // name gets a counter instead of being overwritten.
    const base = `${filePath}.corrupt-${timestampSlug()}`;
    let quarantinedTo = base;
    for (let n = 1; await exists(quarantinedTo); n += 1) quarantinedTo = `${base}-${n}`;
    try {
      await fs.rename(filePath, quarantinedTo);
    } catch {
      // Quarantine is best-effort. Refusing to write is the important part.
      return {
        outcome: { status: 'corrupt', quarantinedTo: '' },
        value: null,
        writable: false,
      };
    }
    return {
      outcome: { status: 'corrupt', quarantinedTo },
      value: null,
      writable: false,
    };
  }
}

/** Makes each temp name unique: two writes in the same millisecond would otherwise share one. */
let tempCounter = 0;

/**
 * Write JSON atomically: a temp file in the same directory, then a rename.
 *
 * Throws on failure rather than swallowing it. A silent failure used to let the UI
 * report "Saved" while nothing reached disk, so the user discovered the loss at
 * the next launch.
 */
export async function writeJsonAtomic(filePath: string, value: unknown): Promise<void> {
  const directory = path.dirname(filePath);
  await fs.mkdir(directory, { recursive: true });
  const temp = `${filePath}.tmp-${process.pid}-${Date.now()}-${(tempCounter += 1)}`;
  try {
    await retryingLocks(() => fs.writeFile(temp, JSON.stringify(value, null, 2), 'utf8'));
    await retryingLocks(() => fs.rename(temp, filePath));
  } catch (error) {
    await fs.rm(temp, { force: true }).catch(() => undefined);
    throw error;
  }
}

/**
 * What Windows returns for a write or rename while another process has the file open: an
 * antivirus scan, the indexer, a backup or sync tool, or anything reading the file.
 * The lock usually clears within milliseconds. Giving up on the first one dropped the
 * write while the app already showed the change as saved.
 *
 * Windows reports ERROR_ACCESS_DENIED as EPERM, so a read-only or ACL-denied file is
 * indistinguishable from a lock and is retried for the same second before it fails.
 * (A missing folder, or a directory where the file should be, still fails at once on POSIX.)
 */
const LOCKED_CODES = new Set(['EPERM', 'EACCES', 'EBUSY']);
/** About one second in all, then the error goes to the caller. */
const LOCK_RETRY_DELAYS_MS = [10, 20, 40, 80, 160, 250, 250, 250];

async function retryingLocks(operation: () => Promise<void>): Promise<void> {
  for (let attempt = 0; ; attempt += 1) {
    try {
      await operation();
      return;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      const delay = LOCK_RETRY_DELAYS_MS[attempt];
      if (delay === undefined || code === undefined || !LOCKED_CODES.has(code)) throw error;
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }
}

/** A temp file this old belongs to a write that died: no live write takes a minute. */
const STALE_TEMP_AGE_MS = 60_000;

/**
 * Remove `<name>.tmp-*` files left beside `filePath` by a write whose cleanup failed
 * (a lock on the temp file itself). Failures are reported to `onError`, never thrown.
 */
export async function removeStaleTempFiles(
  filePath: string,
  onError: (message: string) => void,
  now: number = Date.now(),
): Promise<void> {
  const directory = path.dirname(filePath);
  const prefix = `${path.basename(filePath)}.tmp-`;
  let names: string[];
  try {
    names = await fs.readdir(directory);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
      onError(`could not look for leftover temp files in ${directory}: ${describe(error)}`);
    }
    return;
  }
  for (const name of names) {
    if (!name.startsWith(prefix)) continue;
    const target = path.join(directory, name);
    try {
      const stats = await fs.stat(target);
      if (!stats.isFile() || now - stats.mtimeMs < STALE_TEMP_AGE_MS) continue;
      await fs.rm(target, { force: true });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') continue;
      onError(`could not remove the leftover temp file ${name}: ${describe(error)}`);
    }
  }
}

/**
 * Free space check, used before starting a recording.
 *
 * Recording into a full disk used to fail silently and upload a truncated file
 * that the user was told was a complete transcript.
 */
export async function hasFreeSpace(directory: string, requiredBytes: number): Promise<boolean> {
  try {
    const stats = await fs.statfs(directory);
    const available = Number(stats.bavail) * Number(stats.bsize);
    return available >= requiredBytes;
  } catch {
    // Cannot determine: do not block the recording on a missing API.
    return true;
  }
}

function describe(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

async function exists(target: string): Promise<boolean> {
  try {
    await fs.access(target);
    return true;
  } catch {
    return false;
  }
}

function timestampSlug(now: Date = new Date()): string {
  return now.toISOString().replace(/[:.]/g, '-');
}
