import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { beforeEach, describe, expect, it, vi } from 'vitest';

// The ElevenLabs, Gemini and Anthropic keys are stored the way the Deepgram key is:
//  1. encrypted with safeStorage, never as plain text in the file
//  2. a key that can't be decrypted on this account is written back untouched by any later save
//  3. removing one key leaves the others, and the Deepgram key is unaffected
//  4. the renderer-facing presence map says which are saved, and nothing else

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

async function folder(file?: Record<string, unknown>): Promise<string> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'uv-keys-'));
  if (file) await fs.writeFile(path.join(dir, 'settings.json'), JSON.stringify(file));
  return dir;
}
const read = async (dir: string) => JSON.parse(await fs.readFile(path.join(dir, 'settings.json'), 'utf8')) as Record<string, any>;
const blob = (text: string) => Buffer.from(text).toString('base64');

describe('provider keys', () => {
  beforeEach(() => {
    available = true;
  });

  it('saves each key encrypted and reads it back after a reload', async () => {
    const dir = await folder();
    const store = new SettingsStore(dir);
    await store.load();
    expect(store.setKey('elevenlabs', ' xi-123 ')).toEqual({ ok: true });
    expect(store.setKey('gemini', 'AIza-1').ok).toBe(true);
    expect(store.setKey('anthropic', 'sk-ant-1').ok).toBe(true);
    await store.save();

    const file = await read(dir);
    expect(JSON.stringify(file)).not.toContain('xi-123');
    expect(JSON.stringify(file)).not.toContain('AIza-1');
    expect(Buffer.from(file.providerKeys.elevenlabs.data, 'base64').toString()).toBe('enc:xi-123');

    const again = new SettingsStore(dir);
    await again.load();
    expect(again.revealKey('elevenlabs')).toBe('xi-123');
    expect(again.revealKey('gemini')).toBe('AIza-1');
    expect(again.revealKey('anthropic')).toBe('sk-ant-1');
    expect(again.keyPresence()).toEqual({ deepgram: false, elevenlabs: true, gemini: true, anthropic: true });
  });

  it('refuses an empty key', async () => {
    const store = new SettingsStore(await folder());
    await store.load();
    expect(store.setKey('gemini', '   ')).toEqual({ ok: false, error: 'The API key is empty.' });
    expect(store.hasKeyFor('gemini')).toBe(false);
  });

  it('removes one key without touching the others, Deepgram included', async () => {
    const dir = await folder();
    const store = new SettingsStore(dir);
    await store.load();
    store.setApiKey('dg-1');
    store.setKey('elevenlabs', 'xi-1');
    store.setKey('gemini', 'g-1');
    store.clearKey('gemini');
    await store.save();
    const file = await read(dir);
    expect(Object.keys(file.providerKeys)).toEqual(['elevenlabs']);
    expect(file.apiKeyEncrypted).toBeTruthy();
    expect(store.keyPresence()).toEqual({ deepgram: true, elevenlabs: true, gemini: false, anthropic: false });
    store.clearKey('elevenlabs');
    await store.save();
    expect((await read(dir)).providerKeys).toBeUndefined();
  });

  it('writes a key it cannot decrypt back verbatim, and does not pretend it is set', async () => {
    const original = { data: blob('written by another account') };
    const dir = await folder({ version: 1, settings: {}, providerKeys: { anthropic: original } });
    const store = new SettingsStore(dir);
    await store.load();
    expect(store.hasKeyFor('anthropic')).toBe(false);
    expect(store.revealKey('anthropic')).toBeNull();
    expect(store.hasStoredKey).toBe(true);
    expect(store.saveError?.message).toContain('Anthropic');
    store.update({ appearance: 'dark' });
    await store.save();
    expect((await read(dir)).providerKeys.anthropic).toEqual(original);
  });

  it('counts a provider key as a stored key for the first-run gate', async () => {
    const store = new SettingsStore(await folder({ version: 1, settings: {}, providerKeys: { gemini: { data: blob('enc:g') } } }));
    await store.load();
    expect(store.hasStoredKey).toBe(true);
    expect(store.hasApiKey).toBe(false);
  });
});
