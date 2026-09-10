import { app, safeStorage } from 'electron';
import path from 'node:path';
import { DEFAULT_SETTINGS, type AppSettings } from '../core/models.js';
import { normaliseSettings } from '../core/settings/settingsBounds.js';
import { readJson, writeJsonAtomic } from '../core/settings/jsonStore.js';

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
      if (typeof incoming.apiKeyEncrypted === 'string' && incoming.apiKeyEncrypted.length > 0) {
        this.apiKey = this.decrypt(incoming.apiKeyEncrypted);
        if (this.apiKey === null) {
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
    this.loaded = true;
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
    this.plaintextKeyWarning = false;
    void this.save();
    return { ok: true };
  }

  clearApiKey(): void {
    this.apiKey = null;
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

  private decrypt(stored: string): string | null {
    const buffer = Buffer.from(stored, 'base64');
    if (safeStorage.isEncryptionAvailable()) {
      try {
        return safeStorage.decryptString(buffer);
      } catch {
        // Fall through: it may have been stored while encryption was unavailable.
      }
    }
    try {
      const text = buffer.toString('utf8');
      return text.length > 0 ? text : null;
    } catch {
      return null;
    }
  }

  /** Persist settings and the key. Reports failure instead of swallowing it. */
  async save(): Promise<SaveStatus> {
    const payload: SettingsFile = {
      version: CURRENT_SETTINGS_VERSION,
      settings: this.settings,
    };
    if (this.apiKey !== null && this.apiKey.length > 0) {
      const encrypted = this.encrypt(this.apiKey);
      payload.apiKeyEncrypted = encrypted.data;
      this.plaintextKeyWarning = encrypted.plaintextFallback;
      payload.apiKeyPlaintextWarning = encrypted.plaintextFallback;
    }

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
