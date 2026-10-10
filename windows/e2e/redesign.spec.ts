import { test, expect, _electron as electron, type ElectronApplication, type Page } from '@playwright/test';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { seedUserData } from './fixtures.js';

// The redesign end to end, on the built app with fixture data. It walks the hard
// path a real user takes: filter the Stream to Deutsch, search across languages,
// teach a fix from a misheard dictation and find it in Vocabulary, then switch the
// whole app to dark from Settings and check every page still renders there.

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = process.env.E2E_OUT ?? path.join(root, 'e2e-results');
const shots = path.join(out, 'shots');

let app: ElectronApplication;
let win: Page;
let userData: string;

async function mainWindow(electronApp: ElectronApplication): Promise<Page> {
  for (let i = 0; i < 100; i += 1) {
    const found = electronApp.windows().find((page) => page.url().includes('view=main'));
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('the main window never opened');
}

async function go(section: 'Stream' | 'Notes' | 'Vocabulary' | 'Insights' | 'Settings'): Promise<void> {
  await win.locator('.rail-item', { hasText: section }).click();
  await expect(win.locator('.rail-item[aria-current="page"]', { hasText: section })).toBeVisible();
}

async function shot(name: string): Promise<void> {
  await win.waitForTimeout(350); // let the page-enter beat finish
  const file = path.join(shots, `${name}.png`);
  await win.screenshot({ path: file });
  await test.info().attach(name, { path: file, contentType: 'image/png' });
}

test.beforeAll(async () => {
  userData = await seedUserData();
  const env = { ...process.env } as Record<string, string>;
  delete env.ELECTRON_RUN_AS_NODE;
  app = await electron.launch({
    args: [path.join(root, 'dist', 'main', 'index.js'), `--user-data-dir=${userData}`, '--e2e'],
    env,
    // `_electron.launch` bypasses the config's `use` options, so video and trace
    // are switched on here.
    recordVideo: { dir: path.join(out, 'video'), size: { width: 1180, height: 740 } },
  });
  await app.context().tracing.start({ screenshots: true, snapshots: true });
  win = await mainWindow(app);
  await win.setViewportSize({ width: 1180, height: 740 });
  await win.waitForSelector('.st-title');
});

test.afterAll(async () => {
  await app?.context().tracing.stop({ path: path.join(out, 'trace.zip') });
  await app?.close();
  // The scratch user-data folder this run created.
  if (userData) await fs.rm(userData, { recursive: true, force: true });
});

test('filter, search and teach a fix, then switch to dark', async () => {
  // Stream lists the seeded dictations, newest at the bottom, grouped by day.
  await expect(win.locator('.st-title')).toHaveText('Stream');
  await expect(win.locator('.bubble')).toHaveCount(6);
  // One header (the page's own) and no popover left open over the dock.
  await expect(win.locator('.stage-header')).toBeHidden();
  await expect(win.locator('.status-popover')).toBeHidden();
  await expect(win.getByRole('heading', { name: 'Stream', exact: true })).toHaveCount(1);
  await shot('01-stream-light');

  // Filter to Deutsch: only the two German dictations stay.
  await win.locator('.st-chip', { hasText: 'Deutsch' }).click();
  await expect(win.locator('.bubble')).toHaveCount(2);
  await expect(win.locator('.bubble').first()).toContainText(/Konfiguration|Unterlagen/);
  await shot('02-stream-deutsch');

  // Search inside the filter, then across everything.
  await win.locator('.st-search-input').fill('Kubernetes');
  await expect(win.locator('.bubble')).toHaveCount(1);
  await expect(win.locator('.st-count')).toContainText('1');
  await win.locator('.st-chip', { hasText: 'All' }).click();
  await win.locator('.st-search-input').fill('Barry');
  await expect(win.locator('.bubble')).toHaveCount(1);
  await shot('03-stream-search');

  // Teach a fix: select the misheard words, then use the bubble's action.
  const bubble = win.locator('.bubble').first();
  await bubble.hover();
  await bubble.evaluate((node) => {
    const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
    for (let text = walker.nextNode(); text; text = walker.nextNode()) {
      const at = (text.textContent ?? '').indexOf('Barry');
      if (at < 0) continue;
      const range = document.createRange();
      range.setStart(text, Math.max(0, at - 4)); // "the Barry"
      range.setEnd(text, at + 'Barry'.length);
      const selection = window.getSelection();
      selection?.removeAllRanges();
      selection?.addRange(range);
      return;
    }
    throw new Error('no "Barry" text in the bubble');
  });
  await bubble.getByRole('button', { name: 'Teach a fix' }).click();
  const heard = win.locator('#tf-heard');
  await expect(heard).toHaveValue(/Barry/);
  await win.locator('#tf-write').fill('Tabari');
  await shot('04-teach-a-fix');
  await win.getByRole('button', { name: 'Save fix' }).click();
  await expect(win.locator('.tf')).toHaveCount(0);

  // The fix lands in Vocabulary as a sentence.
  await go('Vocabulary');
  await win.getByRole('button', { name: /^Fixes/ }).click();
  await expect(win.locator('main')).toContainText('Barry');
  await expect(win.locator('main')).toContainText('Tabari');
  await shot('05-vocabulary-fix');

  // Switch the whole app to dark from Settings.
  await go('Settings');
  await win.locator('.segmented[aria-label="Theme"] button', { hasText: 'Dark' }).click();
  await expect(win.locator('html')).toHaveAttribute('data-theme', 'dark');
  const background = await win.evaluate(() => getComputedStyle(document.body).backgroundColor);
  expect(background).toBe('rgb(15, 15, 15)');
  await shot('06-settings-dark');

  // Every page still renders in dark.
  for (const section of ['Stream', 'Notes', 'Vocabulary', 'Insights', 'Settings'] as const) {
    await go(section);
    await shot(`10-${section.toLowerCase()}-dark`);
  }
  await expect(win.locator('main')).toContainText('Appearance');

  // And back to light: every page again.
  await win.locator('.segmented[aria-label="Theme"] button', { hasText: 'Light' }).click();
  await expect(win.locator('html')).toHaveAttribute('data-theme', 'light');
  for (const section of ['Stream', 'Notes', 'Vocabulary', 'Insights', 'Settings'] as const) {
    await go(section);
    await shot(`20-${section.toLowerCase()}-light`);
  }
});
