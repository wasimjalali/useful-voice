import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { DEFAULT_SETTINGS, type AppSettings } from '../src/core/models.js';
import { normaliseSettings } from '../src/core/settings/settingsBounds.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = (file: string): string => readFileSync(path.join(root, file), 'utf8');

describe('the pauseMediaWhileDictating setting', () => {
  it('is on by default', () => {
    expect(DEFAULT_SETTINGS.pauseMediaWhileDictating).toBe(true);
  });

  it('keeps a real boolean either way', () => {
    expect(normaliseSettings({ ...DEFAULT_SETTINGS, pauseMediaWhileDictating: false }).pauseMediaWhileDictating).toBe(false);
    expect(normaliseSettings({ ...DEFAULT_SETTINGS, pauseMediaWhileDictating: true }).pauseMediaWhileDictating).toBe(true);
  });

  it('falls back to the default for a stored value that is not a boolean', () => {
    for (const bad of ['false', 0, null, undefined, {}]) {
      const settings = { ...DEFAULT_SETTINGS, pauseMediaWhileDictating: bad as unknown as boolean };
      expect(normaliseSettings(settings).pauseMediaWhileDictating).toBe(true);
    }
  });

  it('is on for a settings file written before the setting existed', () => {
    // What an older build wrote: every field except this one. Built from the defaults by
    // removing the key, so the object really has no such property (a spread of the defaults
    // would put it back and the test could never fail).
    const olderFile: Record<string, unknown> = { ...DEFAULT_SETTINGS, soundEffectsEnabled: false };
    delete olderFile.pauseMediaWhileDictating;
    expect('pauseMediaWhileDictating' in olderFile).toBe(false);

    // Straight through normalisation: a missing key must come out as the default, not undefined.
    expect(normaliseSettings(olderFile as unknown as AppSettings).pauseMediaWhileDictating).toBe(true);

    // And through the store's load: the file's settings over the defaults, then normalised.
    const loaded = normaliseSettings({ ...DEFAULT_SETTINGS, ...olderFile } as AppSettings);
    expect(loaded.pauseMediaWhileDictating).toBe(true);
    // Other values from that file survive: only the missing key was filled in.
    expect(loaded.soundEffectsEnabled).toBe(false);
  });

  it('keeps an explicit off from a file that has the key', () => {
    const file = { ...DEFAULT_SETTINGS, pauseMediaWhileDictating: false };
    expect(normaliseSettings({ ...DEFAULT_SETTINGS, ...file }).pauseMediaWhileDictating).toBe(false);
  });
});

describe('the plumbing for the setting', () => {
  it('reaches the renderer through the shared settings shape', () => {
    expect(source('src/preload/types.ts')).toMatch(/pauseMediaWhileDictating: boolean;/);
  });

  it('has a toggle in the General group labelled exactly "Pause media while dictating", with no helper text', () => {
    const page = source('src/renderer/pages/settings.ts');
    const general = page.slice(page.indexOf('function generalGroup'), page.indexOf('function goalRow'));
    const row = /row\(\s*'Pause media while dictating',\s*switchControl\('Pause media while dictating', settings\.pauseMediaWhileDictating,[\s\S]*?\),\s*\),/.exec(general);
    expect(row, 'the row is in generalGroup').not.toBeNull();
    // A hint would be a third argument to row().
    expect(row?.[0]).not.toMatch(/hint/i);
  });

  it('is saved through the existing settings channel, not a new one', () => {
    expect(source('src/renderer/pages/settings.ts')).toContain('save({ pauseMediaWhileDictating: value })');
    expect(source('src/main/index.ts')).toContain("ipcMain.handle('settings:save'");
  });

  it('is read by the media policy from the live settings', () => {
    expect(source('src/main/index.ts')).toContain('enabled: () => this.settings.all.pauseMediaWhileDictating');
  });
});

describe('quit wiring for the media', () => {
  const main = source('src/main/index.ts');

  it('routes an OS-initiated quit through the one orderly quit', () => {
    expect(main).toMatch(/app\.on\('before-quit', \(event\) => \{\s*if \(this\.quitting\) return;\s*event\.preventDefault\(\);\s*void this\.quit\(\);/);
  });

  it('plays the media again on a session end (logoff or shutdown) within a second', () => {
    expect(main).toMatch(/window\.on\('session-end', \(\) => \{\s*void this\.media\?\.shutdown\(1000\);/);
  });

  it('gives the quit a 2.5 s budget and logs a miss before the diagnostics are flushed', () => {
    const quit = main.slice(main.indexOf('private async runQuit'));
    const shutdown = quit.indexOf('this.media.shutdown(2500)');
    const miss = quit.indexOf('may stay paused');
    const flush = quit.indexOf('await this.diagnostics.flush()');
    expect(shutdown).toBeGreaterThan(-1);
    expect(miss).toBeGreaterThan(shutdown);
    expect(flush).toBeGreaterThan(miss);
  });
});
