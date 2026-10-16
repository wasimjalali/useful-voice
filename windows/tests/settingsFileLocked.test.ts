import { promises as realFs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';

// A settings save while another process has settings.json open. On Windows the rename
// that replaces the file fails with EPERM, EACCES or EBUSY for as long as a reader, an
// antivirus scan, the indexer or a sync tool holds it, usually a few milliseconds. The
// renaming write used to give up at once: two typing switches flipped quickly left the
// first switch's file on disk while the page (and main's memory) said both were off.
// Failure modes, written before the fix:
//  1. the last of two quick saves meets a held file once: the file must end with both changes
//  2. EACCES and EBUSY are the same transient lock and must land the same way
//  3. a file held for good must still fail loudly (reject), never report success, and leave no temp file
//  4. an error that is not a lock (ENOENT, EISDIR) fails at once, without waiting
//  5. a newer settings change made while an older write waits out a lock lands last, so it wins on disk
//  6. data.json flushes queued behind a write waiting out a lock run one at a time afterwards,
//     never together, and the file ends with the newest state (a stale snapshot must never rename last)
//  7. two writes to one file in the same millisecond use different temp files

const failures: string[] = [];
const renames: Array<[string, string]> = [];
/** Blocks the next rename until `release()`, so a test queues later work behind it without relying on timing. */
let held: { entered: () => void; gate: Promise<void> } | null = null;
function holdNextRename(): { entered: Promise<void>; release: () => void } {
  let release!: () => void;
  let entered!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  const reached = new Promise<void>((resolve) => (entered = resolve));
  held = { entered, gate };
  return { entered: reached, release };
}
/** Temp files written and not yet renamed or removed: more than one means two writes overlap. */
const writes = { active: 0, most: 0 };
vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs')>();
  const isTemp = (file: unknown) => String(file).includes('.tmp-');
  const writeFile = (async (file: string, ...rest: unknown[]) => {
    if (isTemp(file)) writes.most = Math.max(writes.most, ++writes.active);
    return (actual.promises.writeFile as (...args: unknown[]) => Promise<void>)(file, ...rest);
  }) as typeof actual.promises.writeFile;
  const rename = async (from: string, to: string): Promise<void> => {
    renames.push([from, to]);
    const hold = held;
    held = null;
    if (hold) {
      hold.entered();
      await hold.gate;
    }
    const code = failures.shift();
    if (code) throw Object.assign(new Error(`${code}: held open, rename '${from}' -> '${to}'`), { code });
    await actual.promises.rename(from, to);
    if (isTemp(from)) writes.active -= 1;
  };
  const rm = (async (file: string, ...rest: unknown[]) => {
    if (isTemp(file)) writes.active -= 1;
    return (actual.promises.rm as (...args: unknown[]) => Promise<void>)(file, ...rest);
  }) as typeof actual.promises.rm;
  return { ...actual, promises: { ...actual.promises, writeFile, rename, rm } };
});
vi.mock('electron', () => ({
  app: { getPath: () => os.tmpdir() },
  safeStorage: { isEncryptionAvailable: () => true, encryptString: (value: string) => Buffer.from(value), decryptString: String },
}));

const { SettingsStore } = await import('../src/main/settingsStore.js');
const { writeJsonAtomic } = await import('../src/core/settings/jsonStore.js');
const { DataStore } = await import('../src/core/settings/dataStore.js');

async function storeWith(typeOutApps: string[]): Promise<{ dir: string; store: InstanceType<typeof SettingsStore> }> {
  const dir = await realFs.mkdtemp(path.join(os.tmpdir(), 'uv-settings-locked-'));
  await realFs.writeFile(path.join(dir, 'settings.json'), JSON.stringify({ version: 1, settings: { typeOutApps, languagePin: 'de' } }));
  const store = new SettingsStore(dir);
  await store.load();
  return { dir, store };
}
const saved = async (dir: string) =>
  (JSON.parse(await realFs.readFile(path.join(dir, 'settings.json'), 'utf8')) as { settings: Record<string, unknown> }).settings;
/** The outcome of the write `update` starts on its own (it saves without being asked twice). */
const nextWrite = (store: InstanceType<typeof SettingsStore>) =>
  new Promise<{ ok: boolean }>((resolve) => {
    const off = store.onSaveStatus((status) => {
      off();
      resolve(status);
    });
  });
const temps = async (dir: string) => (await realFs.readdir(dir)).filter((name) => name.includes('.tmp-'));

describe('a settings save while settings.json is held open', () => {
  beforeEach(() => {
    failures.length = 0;
    renames.length = 0;
    held = null;
    writes.active = 0;
    writes.most = 0;
  });

  it.each(['EPERM', 'EACCES', 'EBUSY'])('two quick typing switches both land when the second write meets %s once', async (code) => {
    const { dir, store } = await storeWith(['putty', 'windowsterminal']);
    // What the two switch saves send main: each built from the list the previous save returned.
    const first = nextWrite(store);
    store.update({ typeOutApps: ['putty'] });
    expect((await first).ok).toBe(true);
    failures.push(code);
    const second = nextWrite(store);
    store.update({ typeOutApps: [] });
    const status = await second;
    expect((await saved(dir)).typeOutApps).toEqual([]);
    expect(status.ok).toBe(true);
    expect((await saved(dir)).languagePin).toBe('de');
    expect(await temps(dir)).toEqual([]);
  });

  it('a newer change made while the older write waits out a lock wins on disk', async () => {
    const { dir, store } = await storeWith(['putty', 'windowsterminal']);
    const statuses: boolean[] = [];
    store.onSaveStatus((status) => statuses.push(status.ok));
    failures.push('EPERM', 'EPERM');
    const hold = holdNextRename();
    store.update({ typeOutApps: ['putty'] });
    // The first write has reached its rename and is held there while the second change is made.
    await hold.entered;
    store.update({ typeOutApps: [] });
    hold.release();
    await vi.waitFor(() => expect(statuses).toHaveLength(2), { timeout: 3000 });
    expect(statuses).toEqual([true, true]);
    expect((await saved(dir)).typeOutApps).toEqual([]);
    expect(writes.most).toBe(1);
    expect(await temps(dir)).toEqual([]);
  });

  it('a file held for good still fails, says so and leaves no temp file', async () => {
    const { dir, store } = await storeWith(['putty']);
    failures.push(...Array<string>(50).fill('EPERM'));
    const write = nextWrite(store);
    store.update({ typeOutApps: [] });
    const status = await write;
    expect(status.ok).toBe(false);
    expect(store.saveError?.message).toContain('EPERM');
    expect((await saved(dir)).typeOutApps).toEqual(['putty']);
    expect(await temps(dir)).toEqual([]);
  });

  it.each(['ENOENT', 'EISDIR'])('%s is not a lock and fails on the first try', async (code) => {
    const dir = await realFs.mkdtemp(path.join(os.tmpdir(), 'uv-settings-locked-'));
    failures.push(code, code);
    await expect(writeJsonAtomic(path.join(dir, 'data.json'), { a: 1 })).rejects.toThrow(code);
    expect(renames).toHaveLength(1);
    expect(await temps(dir)).toEqual([]);
  });
});

describe('data.json flushes while the file is held open', () => {
  beforeEach(() => {
    failures.length = 0;
    renames.length = 0;
    held = null;
    writes.active = 0;
    writes.most = 0;
  });

  const term = (id: string, phrase: string) => ({
    id, phrase, aliases: [], pronunciations: [], language: 'auto' as const, priority: 'normal' as const, notes: '',
    usageCount: 0, createdAt: '2026-01-01T00:00:00.000Z', updatedAt: '2026-01-01T00:00:00.000Z',
  });

  it('flushes queued behind a write waiting out a lock run one at a time and the newest state lands', async () => {
    const dir = await realFs.mkdtemp(path.join(os.tmpdir(), 'uv-data-locked-'));
    const file = path.join(dir, 'data.json');
    const store = new DataStore(file);
    await store.load();
    store.upsertTerm(term('a', 'Alpha'));
    failures.push('EPERM', 'EPERM');
    const hold = holdNextRename();
    const first = store.flush();
    // The first flush has reached its rename and is held there while the others queue behind it.
    await hold.entered;
    store.upsertTerm(term('b', 'Beta'));
    const queued = [store.flush(), store.flush()];
    store.upsertTerm(term('c', 'Gamma'));
    queued.push(store.flush());
    hold.release();
    expect(await Promise.all([first, ...queued])).toEqual([true, true, true, true]);
    expect(writes.most).toBe(1);
    const onDisk = JSON.parse(await realFs.readFile(file, 'utf8')) as { payload: { terms: Array<{ phrase: string }> } };
    expect(onDisk.payload.terms.map((entry) => entry.phrase)).toEqual(['Gamma', 'Beta', 'Alpha']);
    expect(await temps(dir)).toEqual([]);
  });
});

describe('temp file names', () => {
  beforeEach(() => {
    failures.length = 0;
    renames.length = 0;
  });

  it('two writes to one file in the same millisecond use different temp files', async () => {
    const dir = await realFs.mkdtemp(path.join(os.tmpdir(), 'uv-temp-name-'));
    const file = path.join(dir, 'data.json');
    const now = vi.spyOn(Date, 'now').mockReturnValue(1_760_000_000_000);
    try {
      await Promise.all([writeJsonAtomic(file, { n: 1 }), writeJsonAtomic(file, { n: 2 })]);
    } finally {
      now.mockRestore();
    }
    const [first, second] = renames.map(([from]) => from);
    expect(first).not.toBe(second);
    expect(await temps(dir)).toEqual([]);
  });
});
