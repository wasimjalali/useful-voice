import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { DEFAULT_HUD_ACCENT, HUD_COLORWAYS, parseAppsUseLightTheme } from '../src/core/hudModel.js';
import { DEFAULT_SETTINGS, type AppSettings } from '../src/core/models.js';
import { normaliseSettings } from '../src/core/settings/settingsBounds.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = (file: string): string => readFileSync(path.join(root, file), 'utf8');
const withHud = (hud: Record<string, unknown>): AppSettings => ({ ...DEFAULT_SETTINGS, ...hud }) as AppSettings;

describe('the hudColorway and hudAccent settings', () => {
  it('default to ink and the amber accent', () => {
    expect(DEFAULT_SETTINGS.hudColorway).toBe('ink');
    expect(DEFAULT_SETTINGS.hudAccent).toBe(DEFAULT_HUD_ACCENT);
    expect(DEFAULT_HUD_ACCENT).toBe('#F2A93B');
  });

  it('keep every real colorway', () => {
    for (const colorway of HUD_COLORWAYS) {
      expect(normaliseSettings(withHud({ hudColorway: colorway })).hudColorway).toBe(colorway);
    }
  });

  it('fall back to ink for an unknown or non-string colorway', () => {
    for (const bad of ['neon', '', 'INK', 3, null, undefined, {}]) {
      expect(normaliseSettings(withHud({ hudColorway: bad })).hudColorway).toBe('ink');
    }
  });

  it('normalise a good accent to upper case', () => {
    expect(normaliseSettings(withHud({ hudAccent: '#a1b2c3' })).hudAccent).toBe('#A1B2C3');
    expect(normaliseSettings(withHud({ hudAccent: '#00FF7f' })).hudAccent).toBe('#00FF7F');
  });

  it('fall back to the default accent for anything that is not #RRGGBB', () => {
    for (const bad of ['red', '#fff', 'F2A93B', '#F2A93B0', '#GGGGGG', ' #F2A93B', '#F2A93B\n', '', 7, null, undefined]) {
      expect(normaliseSettings(withHud({ hudAccent: bad })).hudAccent).toBe(DEFAULT_HUD_ACCENT);
    }
  });

  it('are filled in for a settings file written before they existed', () => {
    const older: Record<string, unknown> = { ...DEFAULT_SETTINGS, soundEffectsEnabled: false };
    delete older.hudColorway;
    delete older.hudAccent;
    expect('hudColorway' in older).toBe(false);
    const loaded = normaliseSettings({ ...DEFAULT_SETTINGS, ...older } as AppSettings);
    expect(loaded.hudColorway).toBe('ink');
    expect(loaded.hudAccent).toBe(DEFAULT_HUD_ACCENT);
    expect(loaded.soundEffectsEnabled).toBe(false);
  });
});

describe('the plumbing for the dictation pill', () => {
  it('reaches the renderer through the shared settings shape', () => {
    const types = source('src/preload/types.ts');
    expect(types).toMatch(/hudColorway: 'ink' \| 'paper' \| 'signal' \| 'accent';/);
    expect(types).toMatch(/hudAccent: string;/);
  });

  it('has a Dictation pill row after Theme, saved through the existing settings channel', () => {
    const page = source('src/renderer/pages/settings.ts');
    expect(page).toContain("row('Theme', group), row('Dictation pill', pillControl(settings))");
    expect(page).toContain('save({ hudColorway: value })');
    expect(page).toContain("save({ hudAccent: well.value.toUpperCase(), hudColorway: 'accent' })");
    expect(page).toContain("id: 'hud-accent'");
  });

  it('sends every HUD frame with its placement and style, on the existing channel', () => {
    const main = source('src/main/index.ts');
    expect(main).toContain("window.webContents.send('hud:view', wire)");
    expect(main).toContain('placement: this.hudPlacement, style: this.hudStyle(), appearance: this.hudAppearance');
    expect(main).toContain('systemDark: this.systemDark ?? nativeTheme.shouldUseDarkColors');
  });
});

describe('parseAppsUseLightTheme', () => {
  const out = (value: string): string =>
    `\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize\r\n    AppsUseLightTheme    REG_DWORD    ${value}\r\n\r\n`;
  it('reads 0 as dark and 1 as light', () => {
    expect(parseAppsUseLightTheme(out('0x0'))).toBe(true);
    expect(parseAppsUseLightTheme(out('0x1'))).toBe(false);
  });
  it('gives null for anything it cannot read, so the caller falls back', () => {
    for (const bad of ['', 'ERROR: The system was unable to find the specified registry key or value.', out('0x7'), out('zz')]) {
      expect(parseAppsUseLightTheme(bad)).toBeNull();
    }
  });
});
