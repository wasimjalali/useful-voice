import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';

// Failure modes for the stored key, written before the fix. The first-run gate saves the
// settings file at launch (to mark an upgrading user completed), which re-encrypts
// whatever the store holds. If DPAPI could not decrypt the key, the store used to fall
// back to reading the blob as UTF-8 and then encrypt that garbage over the original:
//  1. an undecryptable blob must be written back verbatim by any later save
//  2. the UTF-8 fallback applies only when encryption is unavailable (or the blob was
//     stored as plaintext), never as a "success" while safeStorage works
//  3. a new key replaces the kept blob, and clearing the key drops it
//  4. encryption unavailable AND the file not marked plaintext: the blob is an encrypted
//     one this run cannot read, so it is kept verbatim, never read as text and rewritten
//  5. a decryptable key round-trips and still counts as stored

let available = true;
vi.mock('electron', () => ({
  app: { getPath: () => os.tmpdir() },
  safeStorage: {
    isEncryptionAvailable: () => available,
    encryptString: (value: string) => Buffer.from(`enc:${value}`),
    decryptString: (buffer: Buffer) => {
      const text = buffer.toString('utf8');
      if (!text.startsWith('enc:')) throw new Error('cannot decrypt');
      return text.slice(4);
    },
  },
}));

const { SettingsStore } = await import('../src/main/settingsStore.js');

async function folderWith(file: Record<string, unknown> | null): Promise<string> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'uv-settings-'));
  if (file) await fs.writeFile(path.join(dir, 'settings.json'), JSON.stringify(file));
  return dir;
}
const read = async (dir: string) => JSON.parse(await fs.readFile(path.join(dir, 'settings.json'), 'utf8')) as Record<string, unknown>;
const blob = (text: string) => Buffer.from(text).toString('base64');

describe('stored API key', () => {
  beforeEach(() => {
    available = true;
  });

  it('writes an undecryptable blob back verbatim', async () => {
    const original = blob('written by another account');
    const dir = await folderWith({ version: 1, settings: {}, apiKeyEncrypted: original });
    const store = new SettingsStore(dir);
    await store.load();
    expect(store.hasApiKey).toBe(false);
    expect(store.hasStoredKey).toBe(true);
    store.markFirstRunCompleted();
    await store.save();
    const saved = await read(dir);
    expect(saved.apiKeyEncrypted).toBe(original);
    expect(saved.firstRunCompleted).toBe(true);
  });

  it('does not read the blob as plaintext while encryption works', async () => {
    const dir = await folderWith({ version: 1, settings: {}, apiKeyEncrypted: blob('looks like text') });
    const store = new SettingsStore(dir);
    await store.load();
    expect(store.revealApiKey()).toBeNull();
  });

  it('reads a plaintext fallback blob when encryption is unavailable', async () => {
    available = false;
    const dir = await folderWith({ version: 1, settings: {}, apiKeyEncrypted: blob('plain-key'), apiKeyPlaintextWarning: true });
    const store = new SettingsStore(dir);
    await store.load();
    expect(store.revealApiKey()).toBe('plain-key');
  });

  it('keeps an encrypted blob verbatim when encryption is unavailable and it is not marked plaintext', async () => {
    available = false;
    const original = blob('enc:from-an-earlier-run');
    const dir = await folderWith({ version: 1, settings: {}, apiKeyEncrypted: original });
    const store = new SettingsStore(dir);
    await store.load();
    expect(store.revealApiKey()).toBeNull();
    store.markFirstRunCompleted();
    await store.save();
    const saved = await read(dir);
    expect(saved.apiKeyEncrypted).toBe(original);
    expect(saved.apiKeyPlaintextWarning).toBeUndefined();
  });

  it('a new key replaces the kept blob and clearing drops it', async () => {
    const dir = await folderWith({ version: 1, settings: {}, apiKeyEncrypted: blob('junk') });
    const store = new SettingsStore(dir);
    await store.load();
    store.setApiKey('fresh-key');
    await store.save();
    expect((await read(dir)).apiKeyEncrypted).toBe(Buffer.from('enc:fresh-key').toString('base64'));
    store.clearApiKey();
    await store.save();
    expect((await read(dir)).apiKeyEncrypted).toBeUndefined();
    expect(store.hasStoredKey).toBe(false);
  });

  it('round-trips a decryptable key', async () => {
    const dir = await folderWith({ version: 1, settings: {}, apiKeyEncrypted: Buffer.from('enc:good-key').toString('base64') });
    const store = new SettingsStore(dir);
    await store.load();
    expect(store.revealApiKey()).toBe('good-key');
    expect(store.hasStoredKey).toBe(true);
  });
});
