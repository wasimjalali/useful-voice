import { app, safeStorage } from 'electron';
import path from 'node:path';
import { DEFAULT_SETTINGS, type AppSettings } from '../core/models.js';
import { normaliseSettings } from '../core/settings/settingsBounds.js';
import { readJson, writeJsonAtomic } from '../core/settings/jsonStore.js';
import { KEY_PROVIDER_INFO, type KeyProvider } from '../core/models/catalog.js';

/**
 * Where the API key is stored.
 *
 * On macOS the key lives in the Keychain. The Windows equivalent is DPAPI, which
 * Electron exposes as `safeStorage`, so the key is encrypted with the *user's*
 * credentials and is unreadable from another account or from a copy of the file
 * moved to another machine. It is never written in plaintext, never logged, and
 * never sent to the renderer.
 */

interface SettingsFile {
  version: number;
  settings: AppSettings;
  /** Base64 of the DPAPI-encrypted API key. Absent when no key is configured. */
  apiKeyEncrypted?: string;
  /**
   * Set only when the key had to be stored without OS encryption (no DPAPI
   * available). The UI warns the user, because a plaintext key on disk is a real
   * (if limited) exposure.
   */
  apiKeyPlaintextWarning?: boolean;
  /** Set once the first-run setup has been finished or skipped, or was never needed. */
  firstRunCompleted?: boolean;
  /** The other providers' keys, encrypted the same way as the Deepgram key. */
  providerKeys?: Partial<Record<ExtraKeyProvider, StoredKey>>;
}

/** The providers whose keys live in `providerKeys` (Deepgram's stays in `apiKeyEncrypted`). */
export type ExtraKeyProvider = Exclude<KeyProvider, 'deepgram'>;
const EXTRA_KEY_PROVIDERS: readonly ExtraKeyProvider[] = ['elevenlabs', 'gemini', 'anthropic'];

interface StoredKey {
  /** Base64 of the DPAPI-encrypted key (or of the text when `plaintext`). */
  data: string;
  plaintext?: boolean;
}

/** One extra key in memory: the key when it could be read, the blob when it could not. */
interface ExtraKey {
  key: string | null;
  /** The stored blob as read, kept when it could not be decrypted so a save writes it back untouched. */
  undecrypted: StoredKey | null;
  onDisk: boolean;
}

const CURRENT_SETTINGS_VERSION = 1;

export interface SaveStatus {
  ok: boolean;
  message?: string;
}

export class SettingsStore {
  private settings: AppSettings = { ...DEFAULT_SETTINGS };
  private apiKey: string | null = null;
  private plaintextKeyWarning = false;
  private loaded = false;
  private lastSaveError: Error | null = null;
  private completedFirstRun = false;
  private keyOnDisk = false;
  /** The stored key blob as read, kept when it could not be decrypted so a save writes it back untouched. */
  private undecryptedBlob: string | null = null;
  private frozen = false;
  private readonly extraKeys = new Map<ExtraKeyProvider, ExtraKey>();
  private readonly statusListeners = new Set<(status: SaveStatus) => void>();

  private readonly filePath: string;

  constructor(userDataDirectory: string) {
    this.filePath = path.join(userDataDirectory, 'settings.json');
  }

  get path(): string {
    return this.filePath;
  }

  async load(): Promise<void> {
    const result = await readJson<SettingsFile>(this.filePath);
    if (result.value && typeof result.value === 'object') {
      const incoming = result.value;
      // Merge over the defaults so a file written by an older build still
      // produces a complete settings object rather than undefined fields.
      this.settings = { ...DEFAULT_SETTINGS, ...(incoming.settings ?? {}) };
      this.settings.hotkey = { ...DEFAULT_SETTINGS.hotkey, ...(incoming.settings?.hotkey ?? {}) };
      // Correct out-of-range values on load as well as on update, so a file
      // written by an older build (which offered a 900 s recording) is fixed at
      // launch rather than honoured until the user next opens Settings.
      this.settings = normaliseSettings(this.settings);
      this.plaintextKeyWarning = incoming.apiKeyPlaintextWarning === true;
      this.completedFirstRun = incoming.firstRunCompleted === true;
      this.keyOnDisk = typeof incoming.apiKeyEncrypted === 'string' && incoming.apiKeyEncrypted.length > 0;
      if (typeof incoming.apiKeyEncrypted === 'string' && incoming.apiKeyEncrypted.length > 0) {
        this.apiKey = this.decrypt(incoming.apiKeyEncrypted, incoming.apiKeyPlaintextWarning === true);
        if (this.apiKey === null) {
          this.undecryptedBlob = incoming.apiKeyEncrypted;
          // Decryption failed: the file was copied from another user or machine,
          // or the OS profile changed. Report it rather than silently behaving as
          // if no key were configured (which is what the macOS build did with a
          // locked keychain: it told the user they were never set up).
          this.lastSaveError = new Error(
            'The stored API key could not be decrypted on this account. Re-enter your Deepgram key in Settings.',
          );
        }
      }
    }
    if (result.value && typeof result.value === 'object') {
      this.loadExtraKeys(result.value.providerKeys);
    }
    this.loaded = true;
  }

  private loadExtraKeys(stored: SettingsFile['providerKeys']): void {
    for (const provider of EXTRA_KEY_PROVIDERS) {
      const entry = stored?.[provider];
      if (!entry || typeof entry.data !== 'string' || entry.data.length === 0) continue;
      const key = this.decrypt(entry.data, entry.plaintext === true);
      this.extraKeys.set(provider, { key, undecrypted: key === null ? entry : null, onDisk: true });
      if (key === null) {
        this.lastSaveError = new Error(
          `The stored ${KEY_PROVIDER_INFO[provider].name} key could not be decrypted on this account. Re-enter it in Settings.`,
        );
      }
    }
  }

  get isLoaded(): boolean {
    return this.loaded;
  }

  get all(): AppSettings {
    return this.settings;
  }

  get saveError(): Error | null {
    return this.lastSaveError;
  }

  /** The first-run setup was finished or skipped. */
  get firstRunCompleted(): boolean {
    return this.completedFirstRun;
  }

  /**
   * A key was stored, whether or not it can be read now. Presence only, so a key that
   * fails to decrypt still counts as configured for the first-run gate.
   */
  get hasStoredKey(): boolean {
    return this.keyOnDisk || this.hasApiKey || [...this.extraKeys.values()].some((entry) => entry.onDisk);
  }

  markFirstRunCompleted(): void {
    if (this.completedFirstRun) return;
    this.completedFirstRun = true;
    void this.save();
  }

  /**
   * While frozen, `save` writes nothing. A `--force-first-run` session uses it so the
   * flow can never change the install, whatever else asks for a save (quit included).
   */
  setFrozen(frozen: boolean): void {
    this.frozen = frozen;
  }

  get isApiKeyEncrypted(): boolean {
    return !this.plaintextKeyWarning;
  }

  get hasApiKey(): boolean {
    return this.apiKey !== null && this.apiKey.length > 0;
  }

  /**
   * The API key, for main-process use only.
   *
   * Deliberately a method rather than a property so it is obvious at every call
   * site that a secret is being read, and so it can be audited by grep.
   */
  revealApiKey(): string | null {
    return this.apiKey;
  }

  /** Whether a provider has a key you can use now. */
  hasKeyFor(provider: KeyProvider): boolean {
    if (provider === 'deepgram') return this.hasApiKey;
    const entry = this.extraKeys.get(provider);
    return entry?.key != null && entry.key.length > 0;
  }

  /** Presence of every provider's key, for the renderer. */
  keyPresence(): Record<KeyProvider, boolean> {
    return {
      deepgram: this.hasApiKey,
      elevenlabs: this.hasKeyFor('elevenlabs'),
      gemini: this.hasKeyFor('gemini'),
      anthropic: this.hasKeyFor('anthropic'),
    };
  }

  /** A provider's key, for main-process use only (see `revealApiKey`). */
  revealKey(provider: KeyProvider): string | null {
    if (provider === 'deepgram') return this.apiKey;
    return this.extraKeys.get(provider)?.key ?? null;
  }

  setKey(provider: KeyProvider, key: string): { ok: boolean; error?: string } {
    if (provider === 'deepgram') return this.setApiKey(key);
    const trimmed = key.trim();
    if (trimmed.length === 0) return { ok: false, error: 'The API key is empty.' };
    this.extraKeys.set(provider, { key: trimmed, undecrypted: null, onDisk: true });
    void this.save();
    return { ok: true };
  }

  clearKey(provider: KeyProvider): void {
    if (provider === 'deepgram') {
      this.clearApiKey();
      return;
    }
    this.extraKeys.delete(provider);
    void this.save();
  }

  onSaveStatus(listener: (status: SaveStatus) => void): () => void {
    this.statusListeners.add(listener);
    return () => this.statusListeners.delete(listener);
  }

  update(patch: Partial<AppSettings>): AppSettings {
    this.settings = {
      ...this.settings,
      ...patch,
      hotkey: { ...this.settings.hotkey, ...(patch.hotkey ?? {}) },
    };
    // Bring the values the UI can set back inside their supported ranges, so a
    // bad value cannot produce an unresponsive recorder (a zero-second silence
    // timeout, or a 15-hour cap). Shared with load, and pure, so the bounds
    // themselves are unit-tested rather than assumed.
    this.settings = normaliseSettings(this.settings);
    void this.save();
    return this.settings;
  }

  setApiKey(key: string): { ok: boolean; error?: string } {
    const trimmed = key.trim();
    if (trimmed.length === 0) return { ok: false, error: 'The API key is empty.' };
    this.apiKey = trimmed;
    this.undecryptedBlob = null;
    this.keyOnDisk = true;
    this.plaintextKeyWarning = false;
    void this.save();
    return { ok: true };
  }

  clearApiKey(): void {
    this.apiKey = null;
    this.undecryptedBlob = null;
    this.keyOnDisk = false;
    this.plaintextKeyWarning = false;
    void this.save();
  }

  private encrypt(value: string): { data: string; plaintextFallback: boolean } {
    if (safeStorage.isEncryptionAvailable()) {
      return { data: safeStorage.encryptString(value).toString('base64'), plaintextFallback: false };
    }
    // No DPAPI (rare; some Windows Server and CI configurations). Store anyway so
    // the app still works, but remember to tell the user, since a key in
    // plaintext on disk is a real exposure.
    return { data: Buffer.from(value, 'utf8').toString('base64'), plaintextFallback: true };
  }

  /**
   * `storedAsPlaintext`: the file says the key was saved without encryption. Only then, or
   * when encryption is unavailable now, is the blob read as text; while DPAPI works, a
   * blob it cannot decrypt is not a key, and reading it as UTF-8 would invent a garbage one.
   */
  private decrypt(stored: string, storedAsPlaintext: boolean): string | null {
    const buffer = Buffer.from(stored, 'base64');
    if (storedAsPlaintext) {
      // Saved without encryption (the file says so): it is text, and is read as text.
      const text = buffer.toString('utf8');
      return text.length > 0 ? text : null;
    }
    if (!safeStorage.isEncryptionAvailable()) return null;
    try {
      return safeStorage.decryptString(buffer);
    } catch {
      return null;
    }
  }

  private saveChain: Promise<unknown> = Promise.resolve();

  /**
   * Persist settings and the key. Reports failure instead of swallowing it.
   *
   * Saves run one after another: two overlapping writes of the same file (a key save
   * the settings page kicks off while another caller awaits its own) fight over the
   * temp file and one of them fails.
   */
  save(): Promise<SaveStatus> {
    const run = this.saveChain.then(() => this.write());
    this.saveChain = run.catch(() => undefined);
    return run;
  }

  private async write(): Promise<SaveStatus> {
    if (this.frozen) return { ok: true };
    const payload: SettingsFile = {
      version: CURRENT_SETTINGS_VERSION,
      settings: this.settings,
      ...(this.completedFirstRun ? { firstRunCompleted: true } : {}),
    };
    if (this.apiKey !== null && this.apiKey.length > 0) {
      const encrypted = this.encrypt(this.apiKey);
      payload.apiKeyEncrypted = encrypted.data;
      this.plaintextKeyWarning = encrypted.plaintextFallback;
      payload.apiKeyPlaintextWarning = encrypted.plaintextFallback;
    } else if (this.undecryptedBlob !== null) {
      // Could not be read on this account: keep it as it was, for the account that can.
      payload.apiKeyEncrypted = this.undecryptedBlob;
    }

    const providerKeys: Partial<Record<ExtraKeyProvider, StoredKey>> = {};
    for (const [provider, entry] of this.extraKeys) {
      if (entry.key !== null && entry.key.length > 0) {
        const encrypted = this.encrypt(entry.key);
        providerKeys[provider] = { data: encrypted.data, ...(encrypted.plaintextFallback ? { plaintext: true } : {}) };
      } else if (entry.undecrypted) {
        providerKeys[provider] = entry.undecrypted;
      }
    }
    if (Object.keys(providerKeys).length > 0) payload.providerKeys = providerKeys;

    try {
      await writeJsonAtomic(this.filePath, payload);
      this.lastSaveError = null;
      const status: SaveStatus = { ok: true };
      this.emitStatus(status);
      return status;
    } catch (error) {
      const wrapped = error instanceof Error ? error : new Error(String(error));
      this.lastSaveError = wrapped;
      const status: SaveStatus = {
        ok: false,
        message: 'Your changes could not be saved. Check free disk space and folder permissions.',
      };
      this.emitStatus(status);
      return status;
    }
  }

  private emitStatus(status: SaveStatus): void {
    for (const listener of this.statusListeners) {
      try {
        listener(status);
      } catch {
        // A failing listener must not break saving.
      }
    }
  }
}

/** The directory user data lives in, for diagnostics and error messages. */
export function userDataDirectory(): string {
  return app.getPath('userData');
}
