import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { DEFAULT_SETTINGS } from '../src/core/models.js';
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
    const { pauseMediaWhileDictating: _omitted, ...older } = DEFAULT_SETTINGS;
    // The store merges the file over the defaults, so a missing key keeps the default.
    expect(normaliseSettings({ ...DEFAULT_SETTINGS, ...older }).pauseMediaWhileDictating).toBe(true);
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
