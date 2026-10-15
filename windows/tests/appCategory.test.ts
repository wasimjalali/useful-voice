import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  allowedStyles,
  APP_CATEGORIES,
  APP_CATEGORY_NAMES,
  AUTO_SEND_KEYS,
  defaultStyle,
  effectiveStyle,
  isAppCategory,
  sendKeyChord,
  type AppCategory,
} from '../src/core/apps/appCategory.js';
import {
  categoryForURL,
  isBrowser,
  normalizeAppID,
  parseWebURL,
  resolveCategory,
  seededCategory,
} from '../src/core/apps/appCategoryRegistry.js';
import {
  APP_SEEDS,
  BROWSER_BUNDLE_IDS,
  BROWSER_EXECUTABLES,
} from '../src/core/apps/appCategorySeeds.js';

// The same cases drive AppCategoryRegistryTests.swift, so the two platforms cannot drift.
interface Fixture {
  apps: {
    id: string;
    appID?: string;
    url?: string;
    overrides?: Record<string, string>;
    expected: AppCategory;
  }[];
  urls: { url: string; expected: AppCategory | null }[];
  parse: { url: string; host: string | null; path: string | null }[];
  normalize: { raw: string; expected: string }[];
}
const fixture: Fixture = JSON.parse(
  readFileSync(
    new URL('../../Tests/Fixtures/app-awareness/registry-cases.json', import.meta.url),
    'utf8',
  ),
);

describe('resolveCategory on the shared cases', () => {
  it('has the cases it should', () => {
    expect(fixture.apps).toHaveLength(107);
    expect(fixture.urls).toHaveLength(82);
  });

  it('resolves every app case', () => {
    const failures = fixture.apps
      .map((c) => ({
        c,
        got: resolveCategory({
          appID: c.appID ?? null,
          url: c.url ?? null,
          // The Swift side drops unknown categories while decoding; cast the same way here.
          overrides: (c.overrides ?? null) as Record<string, AppCategory> | null,
        }),
      }))
      .filter(({ c, got }) => got !== c.expected)
      .map(({ c, got }) => `${c.id}: got ${got}, want ${c.expected}`);
    expect(failures).toEqual([]);
  });

  it('matches every address case', () => {
    const failures = fixture.urls
      .map((c) => ({ c, got: categoryForURL(c.url) }))
      .filter(({ c, got }) => got !== c.expected)
      .map(({ c, got }) => `${JSON.stringify(c.url)}: got ${got}, want ${c.expected}`);
    expect(failures).toEqual([]);
  });

  it('parses addresses into host and path', () => {
    for (const c of fixture.parse) {
      const want = c.host === null ? null : { host: c.host, path: c.path };
      expect(parseWebURL(c.url), c.url).toEqual(want);
    }
  });

  it('normalizes app ids', () => {
    for (const c of fixture.normalize) expect(normalizeAppID(c.raw), c.raw).toBe(c.expected);
  });
});

describe('resolution order', () => {
  it('override beats address beats app seed beats Other', () => {
    const app = 'com.apple.mail';
    expect(resolveCategory({ appID: app })).toBe('email');
    expect(resolveCategory({ appID: app, url: 'https://claude.ai/code' })).toBe('coding');
    expect(
      resolveCategory({ appID: app, url: 'https://claude.ai/code', overrides: { [app]: 'docsNotes' } }),
    ).toBe('docsNotes');
    expect(resolveCategory({ appID: 'com.example.none' })).toBe('other');
  });

  it('never throws on odd input', () => {
    expect(resolveCategory({})).toBe('other');
    expect(resolveCategory({ appID: null, url: null, overrides: null })).toBe('other');
    expect(resolveCategory({ appID: '\u0000', url: '\u0000://' })).toBe('other');
    expect(resolveCategory({ appID: 'x'.repeat(10000), url: 'a'.repeat(10000) })).toBe('other');
  });
});

describe('seed tables', () => {
  it('has no id in two categories', () => {
    const seen = new Map<string, AppCategory>();
    const clashes: string[] = [];
    for (const { category, ids } of APP_SEEDS) {
      for (const id of ids) {
        const key = normalizeAppID(id);
        const prior = seen.get(key);
        if (prior !== undefined) clashes.push(`${key}: ${prior} and ${category}`);
        seen.set(key, category);
      }
    }
    expect(clashes).toEqual([]);
  });

  it('keeps browsers out of the app seeds', () => {
    for (const id of [...BROWSER_BUNDLE_IDS, ...BROWSER_EXECUTABLES]) {
      expect(seededCategory(id), id).toBeNull();
      expect(isBrowser(id), id).toBe(true);
    }
    expect(isBrowser('com.apple.mail')).toBe(false);
    expect(isBrowser('')).toBe(false);
  });

  it('lists the browsers the spec names on each platform', () => {
    for (const id of [
      'com.apple.Safari', 'com.google.Chrome', 'company.thebrowser.Browser', 'com.microsoft.edgemac',
      'com.brave.Browser', 'org.mozilla.firefox', 'com.operasoftware.Opera', 'com.vivaldi.Vivaldi',
      'chrome.exe', 'msedge.exe', 'brave.exe', 'firefox.exe', 'opera.exe', 'vivaldi.exe',
    ]) {
      expect(isBrowser(id), id).toBe(true);
    }
    expect(isBrowser('C:\\Program Files\\Google\\Chrome\\Application\\CHROME.EXE')).toBe(true);
  });

  it('covers every category', () => {
    expect(APP_SEEDS.map((s) => s.category).sort()).toEqual(
      ['coding', 'docsNotes', 'email', 'personalChat', 'workChat'],
    );
  });
});

describe('categories and styles', () => {
  it('names every category', () => {
    expect(APP_CATEGORIES.map((c) => APP_CATEGORY_NAMES[c])).toEqual([
      'Email', 'Work chat', 'Personal chat', 'Coding', 'Docs and notes', 'Other',
    ]);
    expect(isAppCategory('email')).toBe(true);
    expect(isAppCategory('bogus')).toBe(false);
    expect(isAppCategory(3)).toBe(false);
  });

  it('has the default styles from the spec', () => {
    expect(defaultStyle('email')).toBe('formal');
    expect(defaultStyle('workChat')).toBe('casual');
    expect(defaultStyle('personalChat')).toBe('casual');
    expect(defaultStyle('docsNotes')).toBe('formal');
    expect(defaultStyle('other')).toBe('formal');
    expect(defaultStyle('coding')).toBe('formal');
  });

  it('offers Very casual for Personal chat only', () => {
    for (const c of APP_CATEGORIES) {
      expect(allowedStyles(c).includes('veryCasual'), c).toBe(c === 'personalChat');
    }
  });

  it('falls back from Very casual outside Personal chat', () => {
    expect(effectiveStyle('veryCasual', 'personalChat')).toBe('veryCasual');
    for (const c of APP_CATEGORIES.filter((x) => x !== 'personalChat')) {
      expect(effectiveStyle('veryCasual', c), c).toBe('casual');
    }
    expect(effectiveStyle(null, 'workChat')).toBe('casual');
    expect(effectiveStyle(undefined, 'email')).toBe('formal');
    expect(effectiveStyle('formal', 'workChat')).toBe('formal');
  });
});

describe('auto-send key', () => {
  it('maps to the key to send', () => {
    expect(sendKeyChord('off', 'macOS')).toBeNull();
    expect(sendKeyChord('off', 'windows')).toBeNull();
    for (const p of ['macOS', 'windows'] as const) {
      expect(sendKeyChord('return', p)).toEqual({ shift: false, command: false, control: false });
      expect(sendKeyChord('shiftReturn', p)).toEqual({ shift: true, command: false, control: false });
    }
    expect(sendKeyChord('modReturn', 'macOS')).toEqual({ shift: false, command: true, control: false });
    expect(sendKeyChord('modReturn', 'windows')).toEqual({ shift: false, command: false, control: true });
  });

  it('defaults to off and lists every key', () => {
    expect(AUTO_SEND_KEYS[0]).toBe('off');
    expect(AUTO_SEND_KEYS).toHaveLength(4);
  });
});
