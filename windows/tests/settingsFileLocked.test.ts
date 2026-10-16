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

const failures: string[] = [];
const renames: Array<[string, string]> = [];
vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs')>();
  const rename = async (from: string, to: string): Promise<void> => {
    renames.push([from, to]);
    const code = failures.shift();
    if (code) throw Object.assign(new Error(`${code}: held open, rename '${from}' -> '${to}'`), { code });
    return actual.promises.rename(from, to);
  };
  return { ...actual, promises: { ...actual.promises, rename } };
});
vi.mock('electron', () => ({
  app: { getPath: () => os.tmpdir() },
  safeStorage: { isEncryptionAvailable: () => true, encryptString: (value: string) => Buffer.from(value), decryptString: String },
}));

const { SettingsStore } = await import('../src/main/settingsStore.js');
const { writeJsonAtomic } = await import('../src/core/settings/jsonStore.js');

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
