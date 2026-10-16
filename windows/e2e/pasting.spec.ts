import { test, expect, _electron as electron, type ElectronApplication, type Page } from '@playwright/test';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { seedUserData } from './fixtures.js';
import { sendToMain } from './harness.js';

// The Pasting settings (B1) on the built app: an install upgraded from a build that had
// typing switched on for two terminals. It turns "Restore clipboard after paste" off and
// back on, switches typing off for one app and on again, and checks every change lands
// in settings.json, the row stays put when switched off, and the file keeps the rest.
// Then two switches flipped faster than a save returns must both land, and a type-out
// that stopped part way must say so instead of the plain "Copied" notice.

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = process.env.E2E_OUT ?? path.join(root, 'e2e-results');
const shots = path.join(out, 'shots');

let app: ElectronApplication;
let win: Page;
let userData: string;

async function mainWindow(electronApp: ElectronApplication): Promise<Page> {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    for (const page of electronApp.windows()) {
      const href = await page.evaluate(() => location.href).catch(() => page.url());
      if (href.includes('view=main')) return page;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error('the main window never opened');
}

async function savedSettings(): Promise<Record<string, unknown>> {
  const file = JSON.parse(await fs.readFile(path.join(userData, 'settings.json'), 'utf8')) as {
    settings?: Record<string, unknown>;
  };
  return file.settings ?? {};
}

async function shot(name: string): Promise<void> {
  await win.waitForTimeout(350);
  const file = path.join(shots, `${name}.png`);
  await win.screenshot({ path: file });
  await test.info().attach(name, { path: file, contentType: 'image/png' });
}

test.beforeAll(async () => {
  userData = await seedUserData();
  await fs.writeFile(
    path.join(userData, 'settings.json'),
    JSON.stringify({ version: 1, firstRunCompleted: true, settings: { typeOutApps: ['WindowsTerminal.exe', 'putty.exe'], languagePin: 'de' } }),
  );
  const env = { ...process.env } as Record<string, string>;
  delete env.ELECTRON_RUN_AS_NODE;
  app = await electron.launch({
    args: [path.join(root, 'dist', 'main', 'index.js'), `--uv-data-dir=${userData}`, '--e2e'],
    env,
    recordVideo: { dir: path.join(out, 'video'), size: { width: 1180, height: 740 } },
  });
  await app.context().tracing.start({ screenshots: true, snapshots: true });
  win = await mainWindow(app);
  await win.setViewportSize({ width: 1180, height: 740 });
  await win.waitForSelector('.st-title');
});

test.afterAll(async () => {
  try {
    await app?.context().tracing.stop({ path: path.join(out, 'trace-pasting.zip') });
  } finally {
    try {
      await app?.close();
    } finally {
      if (userData) await fs.rm(userData, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    }
  }
});

test('pasting settings: clipboard restore and per-app typing save and survive', async () => {
  await win.locator('.rail-item', { hasText: 'Settings' }).click();
  await win.locator('.s-index-item', { hasText: 'Pasting' }).click();
  const group = win.locator('#settings-pasting');
  await expect(group).toBeVisible();

  // Restore is on by default for an older file; off says where the dictation goes.
  const restore = group.getByRole('switch', { name: 'Restore clipboard after paste' });
  await expect(restore).toHaveAttribute('aria-checked', 'true');
  await expect(group).not.toContainText('Your dictation stays on the clipboard.');
  await restore.click();
  await expect(restore).toHaveAttribute('aria-checked', 'false');
  await expect(group).toContainText('Your dictation stays on the clipboard.');
  await expect.poll(async () => (await savedSettings()).restorePreviousClipboard).toBe(false);

  // The app from the older file shows normalised, switched on.
  const terminal = group.getByRole('switch', { name: 'Type into windowsterminal' });
  await expect(terminal).toHaveAttribute('aria-checked', 'true');
  await shot('pasting-01-restore-off');

  // Off: saved, and the row stays where it was so it can be switched back.
  await terminal.click();
  await expect(terminal).toHaveAttribute('aria-checked', 'false');
  await expect.poll(async () => (await savedSettings()).typeOutApps).toEqual(['putty']);
  await expect(terminal).toBeVisible();
  await terminal.click();
  await expect.poll(async () => (await savedSettings()).typeOutApps).toEqual(['putty', 'windowsterminal']);

  await restore.click();
  await expect(restore).toHaveAttribute('aria-checked', 'true');
  await expect.poll(async () => (await savedSettings()).restorePreviousClipboard).toBe(true);
  // Nothing else in the file was disturbed.
  expect((await savedSettings()).languagePin).toBe('de');
  await shot('pasting-02-final');
});

test('two typing switches flipped before the first save returns both land', async () => {
  const group = win.locator('#settings-pasting');
  const terminal = group.getByRole('switch', { name: 'Type into windowsterminal' });
  const putty = group.getByRole('switch', { name: 'Type into putty' });
  await expect(terminal).toHaveAttribute('aria-checked', 'true');
  await expect(putty).toHaveAttribute('aria-checked', 'true');
  // Both clicks go out in the same task, long before the first IPC save can come back.
  await win.evaluate(() => {
    const switches = [...document.querySelectorAll<HTMLButtonElement>('#settings-pasting [role="switch"]')];
    for (const name of ['Type into windowsterminal', 'Type into putty']) {
      switches.find((button) => button.getAttribute('aria-label') === name)?.click();
    }
  });
  await expect.poll(async () => (await savedSettings()).typeOutApps).toEqual([]);
  await expect(terminal).toHaveAttribute('aria-checked', 'false');
  await expect(putty).toHaveAttribute('aria-checked', 'false');
  await shot('pasting-03-both-off');
});

test('a type-out that stopped part way says so in the dock', async () => {
  await win.locator('.rail-item', { hasText: 'Dictations' }).click();
  // What main sends when typing stopped part way. (A real hotkey dictation would type
  // into the machine running the suite.)
  await sendToMain(app, 'dictation:outcome', {
    kind: 'delivered',
    words: 9,
    result: 'copiedNotPasted',
    appName: 'Windows Terminal',
    partlyTyped: true,
  });
  await sendToMain(app, 'dictation:state', { state: 'idle', message: 'Partly typed. The full text is on your clipboard.' });
  const status = win.locator('.dock .dock-inner:not(.is-leaving) .dock-status');
  await expect(status).toContainText('Partly typed. The full text is on your clipboard.');
  await expect(status).not.toContainText('Press Ctrl+V');
  await shot('pasting-04-partly-typed');
});
