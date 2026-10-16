import { expect, test, type ElectronApplication, type Locator, type Page } from '@playwright/test';
import path from 'node:path';
import { seedUserData } from './fixtures.js';
import { launch, pageFor, remove, root, sendToMain, type Running } from './harness.js';

// The HUD for a screen reader (WAS-53) and the HUD never showing a stale error (WAS-54 item 5),
// on the built app. The HUD window only exists while a dictation runs on a real desktop, so the
// spec opens a second window on the HUD page and feeds it what main sends: view frames,
// announcements and input levels (the same approach as `hud.spec.ts`).
//
// What is checked here is the window's end: the live regions that speak, the capsule's
// accessible name per state, and that the ticking timer is not read out. The text main decides
// to say per state is covered by `tests/announce.test.ts`.

let run: Running | null = null;
let hud: Page;

test.beforeAll(async () => {
  const userData = await seedUserData();
  run = await launch('hud-a11y', userData);
  hud = await openHud(run.app, userData);
});

test.afterAll(async () => {
  const current = run;
  run = null;
  if (!current) return;
  try {
    await current.stop();
  } finally {
    await remove(current.userData);
  }
});

async function openHud(app: ElectronApplication, userData: string): Promise<Page> {
  await app.evaluate(async ({ BrowserWindow }, appPath) => {
    const win = new BrowserWindow({
      width: 520,
      height: 96,
      show: true,
      frame: false,
      useContentSize: true,
      resizable: false,
      focusable: false,
      transparent: true,
      hasShadow: false,
      webPreferences: { preload: `${appPath}/preload/index.js`, contextIsolation: true, nodeIntegration: false },
    });
    await win.loadFile(`${appPath}/renderer/index.html`, { query: { view: 'hud', theme: 'light' } });
  }, path.join(root, 'dist'));
  return pageFor(app, 'hud', userData);
}

/** Sends a message to the HUD window the way main does. */
async function sendToHud(app: ElectronApplication, channel: string, payload: unknown): Promise<void> {
  await app.evaluate(
    ({ BrowserWindow }, args) => {
      const win = BrowserWindow.getAllWindows().find((w) => w.webContents.getURL().includes('view=hud'));
      win?.webContents.send(args.channel, args.payload);
    },
    { channel, payload },
  );
}

const polite = (page: Page): Locator => page.locator('[role="status"][aria-live="polite"].sr-only');
const assertive = (page: Page): Locator => page.locator('[role="alert"][aria-live="assertive"].sr-only');

test('the HUD and the main window each carry a polite and an assertive live region that speak what main announces', async () => {
  const { app, win } = run!;

  for (const [name, page] of [['HUD', hud], ['main window', win]] as const) {
    await expect(polite(page), `${name} polite region`).toHaveCount(1);
    await expect(assertive(page), `${name} assertive region`).toHaveCount(1);
    // Atomic, so a changed line is read whole, and visually hidden, not display:none (which a
    // screen reader would skip).
    await expect(polite(page)).toHaveAttribute('aria-atomic', 'true');
    await expect(assertive(page)).toHaveAttribute('aria-atomic', 'true');
    await expect(polite(page)).toBeAttached();
    expect(await polite(page).evaluate((node) => getComputedStyle(node).display)).not.toBe('none');
  }

  // Main picks the window by focus; here each is sent a line directly.
  await sendToHud(app, 'app:announce', { text: 'Recording', urgency: 'polite' });
  await expect(polite(hud)).toHaveText('Recording');
  await expect(assertive(hud)).toHaveText('');

  await sendToHud(app, 'app:announce', { text: 'Deepgram rejected your API key. Open settings available.', urgency: 'assertive' });
  await expect(assertive(hud)).toHaveText('Deepgram rejected your API key. Open settings available.');
  await expect(polite(hud)).toHaveText('Recording');

  await sendToMain(app, 'app:announce', { text: 'Saved and copied, 4 words', urgency: 'polite' });
  await expect(polite(win)).toHaveText('Saved and copied, 4 words');

  // The same sentence twice in a row is spoken twice: the region is emptied before it is set.
  await sendToHud(app, 'app:announce', { text: 'Cancelled', urgency: 'polite' });
  await expect(polite(hud)).toHaveText('Cancelled');
  await hud.evaluate(() => {
    const region = document.querySelector('[role="status"][aria-live="polite"]');
    const seen: string[] = [];
    new MutationObserver(() => seen.push(region?.textContent ?? '')).observe(region as Node, { childList: true, characterData: true, subtree: true });
    (window as unknown as { __seen: string[] }).__seen = seen;
  });
  await sendToHud(app, 'app:announce', { text: 'Cancelled', urgency: 'polite' });
  await expect.poll(() => hud.evaluate(() => (window as unknown as { __seen: string[] }).__seen)).toContain('Cancelled');
  expect(await hud.evaluate(() => (window as unknown as { __seen: string[] }).__seen)).toContain('');
});

test('the capsule is named for each HUD state and the timer is not a live region', async () => {
  const { app } = run!;
  const capsule = hud.locator('.hud-capsule');
  let seq = 100;
  const show = async (view: Record<string, unknown>): Promise<void> => {
    seq += 1;
    await sendToHud(app, 'hud:view', { ...view, seq });
  };

  const states: Array<[Record<string, unknown>, string, string]> = [
    [{ kind: 'recording', elapsedSeconds: 12 }, 'Recording, 0:12', 'recording'],
    [{ kind: 'transcribing' }, 'Transcribing', 'transcribing'],
    [{ kind: 'inserting' }, 'Inserting', 'inserting'],
    [{ kind: 'saving' }, 'Saving', 'saving'],
    [{ kind: 'done', words: 24, saved: false }, 'Inserted, 24 words', 'done'],
    [{ kind: 'done', words: 1, saved: true }, 'Saved and copied, 1 word', 'done'],
    [{ kind: 'copied' }, 'Copied. Press Ctrl+V to paste', 'copied'],
    [{ kind: 'copied', lineBreaks: true }, "Copied. It has line breaks, so it wasn't typed. Press Ctrl+V.", 'copied'],
    [{ kind: 'cancelled' }, 'Cancelled', 'cancelled'],
    [{ kind: 'language', name: 'Deutsch' }, 'Language: Deutsch', 'language'],
    [{ kind: 'error', error: { kind: 'offline', message: 'Could not reach Deepgram.', fix: 'retry' } }, 'No connection', 'error'],
    [{ kind: 'error', error: { kind: 'micUnavailable', message: 'Microphone access is blocked.', fix: 'openMicrophoneSettings' } }, 'Microphone access is off', 'error'],
  ];
  for (const [view, label, kind] of states) {
    await show(view);
    await expect(capsule).toHaveAttribute('aria-label', label);
    await expect(capsule).toHaveAttribute('data-kind', kind);
  }

  // Recording: the label follows the clock ("Recording, 0:12" -> 0:13) while the visible timer
  // is hidden from assistive technology, and nothing around it is a live region.
  await show({ kind: 'recording', elapsedSeconds: 12 });
  await expect(capsule).toHaveAttribute('aria-label', 'Recording, 0:12');
  await hud.waitForTimeout(400); // the previous view's cross-fade
  const time = hud.locator('.hud-time');
  await expect(time).toHaveText('0:12');
  await expect(time).toHaveAttribute('aria-hidden', 'true');
  await sendToHud(app, 'hud:view', { kind: 'recording', elapsedSeconds: 13, seq });
  await expect(capsule).toHaveAttribute('aria-label', 'Recording, 0:13');
  await expect(time).toHaveText('0:13');
  expect(await time.evaluate((node) => node.closest('[aria-live], [role="status"], [role="alert"], [role="timer"]') === null)).toBe(true);
  expect(await capsule.evaluate((node) => node.getAttribute('aria-live'))).toBeNull();
  expect(await capsule.evaluate((node) => node.querySelectorAll('[aria-live], [role="status"], [role="alert"], [role="timer"]').length)).toBe(0);
  // The only live regions in the whole HUD page are the two that main speaks through.
  expect(await hud.evaluate(() => document.querySelectorAll('[aria-live]').length)).toBe(2);

  // The countdown appears in the label's visible text without a new live region.
  await sendToHud(app, 'hud:view', { kind: 'recording', elapsedSeconds: 55, stopsIn: 5, seq });
  await expect(hud.locator('.hud-stops')).toHaveText('Stops in 5 s');
  expect(await hud.locator('.hud-stops').evaluate((node) => node.closest('[aria-live]') === null)).toBe(true);
});

test('an error never outlives the dictation that replaces it', async () => {
  const { app } = run!;
  const capsule = hud.locator('.hud-capsule');

  await sendToHud(app, 'hud:view', {
    kind: 'error',
    error: { kind: 'offline', message: 'Could not reach Deepgram. Check your internet connection.', fix: 'retry' },
    seq: 500,
  });
  await expect(capsule).toHaveAttribute('data-kind', 'error');
  await expect(capsule).toContainText('No connection');
  await expect(capsule.getByRole('button', { name: 'Retry last recording' })).toBeVisible();
  await expect(capsule).toHaveAttribute('title', /Could not reach Deepgram/);

  // The next dictation starts: nothing of the error is left, not its text, its button, its
  // tooltip or its kind.
  await sendToHud(app, 'hud:view', { kind: 'recording', elapsedSeconds: 0, seq: 501 });
  await expect(capsule).toHaveAttribute('data-kind', 'recording');
  await expect(capsule).toHaveAttribute('aria-label', 'Recording, 0:00');
  await expect(capsule).not.toContainText('No connection');
  await expect(capsule.locator('.hud-btn')).toHaveCount(0);
  await expect(capsule.locator('.hud-x')).toHaveCount(0);
  await expect(capsule).not.toHaveAttribute('title', /.+/);
  // Even after the outgoing content's cross-fade has finished.
  await hud.waitForTimeout(400);
  await expect(capsule.locator('.hud-inner')).toHaveCount(1);
  await expect(capsule).not.toContainText('Could not reach');

  // An error that ends the dictation, then a done line: the error is replaced the same way.
  await sendToHud(app, 'hud:view', { kind: 'error', error: { kind: 'noSpeech', message: 'No speech detected.' }, seq: 502 });
  await expect(capsule).toHaveAttribute('data-kind', 'error');
  await sendToHud(app, 'hud:view', { kind: 'done', words: 4, saved: true, seq: 503 });
  await expect(capsule).toHaveAttribute('data-kind', 'done');
  await hud.waitForTimeout(400);
  await expect(capsule).not.toContainText('No speech');

  // And hidden means hidden: nothing is left behind once main says there is no view.
  await sendToHud(app, 'hud:view', null);
  await expect(capsule).toHaveClass(/is-hidden/);
  await expect(capsule).toBeEmpty();
});
