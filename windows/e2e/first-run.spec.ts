import { test, expect, _electron as electron, type ElectronApplication, type Page } from '@playwright/test';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { seedUserData } from './fixtures.js';

// The first-run setup end to end, on the built app. Deepgram is answered by the e2e-only
// stub in main (a key starting with `valid` works, `offline` fails like a dead network,
// anything else is refused) and the microphone is Chromium's fake device, so the real key
// check, the real level meter and the real dictation pipeline all run.
//
//  1. fresh install: every step, a refused key, a dead network, a good key, the live
//     meter, a practice dictation, Done, and no flow on the next launch
//  2. an existing user (key saved, no completed flag) never sees it and is marked completed
//  3. --force-first-run on a completed install: walk it with another key, language and
//     hotkey; afterwards the install's files are byte-identical
//  4. skip from the key step, then Settings > Run setup again
//  5. microphone refused, then allowed while the step is open
//  6. reduced motion: no step animation
//  7. every step in light and dark at the smallest window size (screenshots)
//  8. the launch rule: a pending flow opens the window by itself, a login launch does not
//  9. the flow's lifetime in main: closing the window mid-flow ends it, hotkey dictations
//     paste again, a running practice recording stops
// 10. a malformed or refused hotkey, a slow key check left and re-entered, a save that
//     fails, a key that cannot be sent
// 11. the microphone: closed on leaving the step, a late answer closed, retries paused hidden

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = process.env.E2E_OUT ?? path.join(root, 'e2e-results');
const shots = path.join(out, 'screens');

interface Running {
  app: ElectronApplication;
  win: Page;
  userData: string;
  stop: () => Promise<void>;
}

/** Resolves to `fallback` if `promise` takes longer than `ms`, so diagnostics never hang. */
function within<T>(promise: Promise<T>, ms: number, fallback: T): Promise<T> {
  return Promise.race([promise.catch(() => fallback), new Promise<T>((resolve) => setTimeout(() => resolve(fallback), ms))]);
}

async function mainWindow(app: ElectronApplication, userData: string, output: string[]): Promise<Page> {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    for (const page of app.windows()) {
      const href = await within(page.evaluate(() => location.href), 2_000, page.url());
      if (href.includes('view=main')) return page;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  const log = await fs.readFile(path.join(userData, 'e2e.log'), 'utf8').catch(() => '(no e2e.log)');
  throw new Error(`the main window never opened\nlog:\n${log}\n${output.join('')}`);
}

/** Launches the built app on `userData` with video and a trace, and waits for the main window. */
async function launch(name: string, userData: string, flags: string[] = []): Promise<Running> {
  const env = { ...process.env } as Record<string, string>;
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({
    args: [path.join(root, 'dist', 'main', 'index.js'), `--uv-data-dir=${userData}`, '--e2e', ...flags],
    env,
    // `_electron.launch` bypasses the config's `use` options, so video and trace are switched on here.
    recordVideo: { dir: path.join(out, 'video-first-run', name), size: { width: 1040, height: 720 } },
  });
  const output: string[] = [];
  app.process().stdout?.on('data', (chunk: Buffer) => output.push(chunk.toString()));
  app.process().stderr?.on('data', (chunk: Buffer) => output.push(chunk.toString()));
  await app.context().tracing.start({ screenshots: true, snapshots: true });
  const win = await mainWindow(app, userData, output);
  await win.setViewportSize({ width: 1040, height: 720 });
  const stop = async (): Promise<void> => {
    try {
      await app.context().tracing.stop({ path: path.join(out, `trace-first-run-${name}.zip`) });
    } finally {
      await app.close();
    }
  };
  return { app, win, userData, stop };
}

async function freshDir(): Promise<string> {
  return fs.mkdtemp(path.join(os.tmpdir(), 'uv-e2e-fr-'));
}

async function remove(dir: string): Promise<void> {
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}

async function shot(win: Page, name: string): Promise<void> {
  await win.waitForTimeout(450); // let the step's enter beat finish
  await fs.mkdir(shots, { recursive: true });
  const file = path.join(shots, `${name}.png`);
  await win.screenshot({ path: file });
  await test.info().attach(name, { path: file, contentType: 'image/png' });
}

/** The flow's own tree: the shell underneath is inert but still in the accessibility tree. */
const fr = (win: Page) => win.locator('.fr');

const page = (win: Page, name: string) => win.locator(`.fr-page[data-page="${name}"]`);

async function readJson(file: string): Promise<Record<string, unknown> | null> {
  try {
    return JSON.parse(await fs.readFile(file, 'utf8')) as Record<string, unknown>;
  } catch {
    return null;
  }
}

/** Polls a file until `ok` accepts it: main writes settings a moment after the click. */
async function settingsWhere(dir: string, ok: (settings: Record<string, unknown> | null) => boolean): Promise<Record<string, unknown> | null> {
  const deadline = Date.now() + 10_000;
  let last: Record<string, unknown> | null = null;
  while (Date.now() < deadline) {
    last = await readJson(path.join(dir, 'settings.json'));
    if (ok(last)) return last;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  return last;
}

/** Welcome to the microphone step with a key the stub accepts. */
async function walkToMicrophone(win: Page): Promise<void> {
  await fr(win).getByRole('button', { name: 'Get started' }).click();
  const key = fr(win).getByLabel('Deepgram API key');
  await key.fill('valid-walk-key');
  await key.press('Enter');
  await expect(page(win, 'deepgramKey')).toBeVisible();
  await page(win, 'deepgramKey').getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page(win, 'microphone')).toBeVisible();
}

test('fresh install: every step, a bad key blocks, a good key advances, then never again', async () => {
  const userData = await freshDir();
  let run = await launch('fresh', userData);
  try {
    const { win } = run;
    await expect(win.locator('.fr')).toBeVisible();

    // Welcome: focus is on the main control and Enter advances.
    await expect(page(win, 'welcome').getByRole('heading', { name: 'Welcome to Useful Voice' })).toBeVisible();
    await expect(fr(win).getByRole('button', { name: 'Get started' })).toBeFocused();
    await shot(win, 'flow-01-welcome');
    await win.keyboard.press('Enter');

    // Engine: Deepgram is the only live engine; the local models are disabled.
    await expect(page(win, 'engine')).toBeVisible();
    await expect(win.locator('.fr-credit-figure')).toHaveText('$200');
    await expect(fr(win).getByText('No card needed.')).toBeVisible();
    await expect(fr(win).getByText(/one year|12 months|1 year/i)).toHaveCount(0);
    await expect(win.locator('.fr-local-row')).toHaveCount(2);
    for (const row of await win.locator('.fr-local-row').all()) await expect(row).toBeDisabled();
    await expect(fr(win).getByText('Coming to Windows')).toHaveCount(2);
    const key = fr(win).getByLabel('Deepgram API key');
    await expect(key).toBeFocused();

    // A refused key shows the error and blocks.
    await key.fill('not-a-real-key-123');
    await key.press('Enter');
    await expect(win.locator('.fr-alert', { hasText: "Deepgram didn't accept this key" })).toBeVisible();
    await expect(page(win, 'engine')).toBeVisible();
    await shot(win, 'flow-02-engine-refused');

    // A dead network is a different message, and also blocks.
    await key.fill('offline-key-123');
    await key.press('Enter');
    await expect(win.locator('.fr-alert', { hasText: "Couldn't reach Deepgram" })).toBeVisible();
    await expect(page(win, 'engine')).toBeVisible();

    // Nothing was saved by either attempt.
    expect((await readJson(path.join(userData, 'settings.json')))?.apiKeyEncrypted).toBeUndefined();

    // Editing the field clears the error at once.
    await key.fill('valid-e2e-key');
    await expect(win.locator('.fr-alert')).toHaveCount(0);
    await key.press('Enter');
    await expect(page(win, 'deepgramKey')).toBeVisible();
    await expect(fr(win).locator('.fr-ok', { hasText: 'Key works.' })).toBeVisible();
    await shot(win, 'flow-03-key-saved');
    const saved = await settingsWhere(userData, (s) => typeof s?.apiKeyEncrypted === 'string');
    expect(typeof saved?.apiKeyEncrypted).toBe('string');
    await expect(fr(win).getByRole('button', { name: 'Continue', exact: true })).toBeFocused();
    await win.keyboard.press('Enter');

    // Microphone: the fake device is allowed and the meter moves.
    await expect(page(win, 'microphone')).toBeVisible();
    await expect(win.locator('.fr-ok', { hasText: 'Allowed' })).toBeVisible();
    const heights = new Set<number>();
    const deadline = Date.now() + 8_000;
    while (Date.now() < deadline && !(heights.size > 1 && Math.max(...heights) > 4)) {
      const now = await win.locator('.fr-meter-bar').evaluateAll((bars) => bars.map((bar) => (bar as HTMLElement).offsetHeight));
      for (const height of now) heights.add(height);
      await win.waitForTimeout(100);
    }
    expect(Math.max(...heights), 'the level meter never rose above its resting height').toBeGreaterThan(4);
    await shot(win, 'flow-04-microphone');
    await fr(win).getByRole('button', { name: 'Continue', exact: true }).click();

    // Try it: a practice dictation fills the field inside the flow.
    await expect(page(win, 'tryIt')).toBeVisible();
    const pad = fr(win).getByLabel('Practice area');
    await expect(pad).toBeFocused();
    await expect(pad).toHaveAttribute('placeholder', /Ctrl\+Alt\+Space/);
    await fr(win).getByRole('button', { name: 'Start recording' }).click();
    await expect(fr(win).getByRole('button', { name: 'Stop', exact: true })).toBeVisible();
    await win.waitForTimeout(2200); // the fake device beeps about once a second
    await fr(win).getByRole('button', { name: 'Stop', exact: true }).click();
    await expect(pad).toHaveValue('Hello from Useful Voice.', { timeout: 20_000 });
    await expect(fr(win).locator('.fr-ok', { hasText: "It worked. That's all there is to it." })).toBeVisible();
    await shot(win, 'flow-05-try-it-worked');
    await fr(win).getByRole('button', { name: 'Finish setup' }).click();

    // Done lands in the main window.
    await expect(page(win, 'done')).toBeVisible();
    await expect(fr(win).getByRole('heading', { name: "You're all set" })).toBeVisible();
    await shot(win, 'flow-06-done');
    await fr(win).getByRole('button', { name: 'Open Useful Voice' }).click();
    await expect(win.locator('.fr')).toHaveCount(0);
    await expect(win.locator('.st-title')).toHaveText('Dictations');
    const done = await settingsWhere(userData, (s) => s?.firstRunCompleted === true);
    expect(done?.firstRunCompleted).toBe(true);
  } finally {
    await run.stop();
  }

  // Relaunch on the same folder: no flow.
  run = await launch('fresh-relaunch', userData);
  try {
    await expect(run.win.locator('.st-title')).toHaveText('Dictations');
    expect((await run.win.evaluate(() => window.usefulVoice.firstRunState())).pending).toBe(false);
    await expect(run.win.locator('.fr')).toHaveCount(0);
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('an existing user with a saved key never sees it, and is marked completed', async () => {
  const userData = await seedUserData({ firstRunCompleted: false });
  // An install from before the flow existed: a key saved, no completed flag. The first
  // launch (a brand new folder) shows the flow; saving the key through the app's own
  // API is how the folder gets into that state.
  let run = await launch('existing-seed', userData);
  try {
    await run.win.evaluate(() => window.usefulVoice.setApiKey('valid-existing-user'));
    const seeded = await settingsWhere(userData, (s) => typeof s?.apiKeyEncrypted === 'string');
    expect(seeded?.firstRunCompleted).toBeUndefined();
  } finally {
    await run.stop();
  }

  run = await launch('existing', userData);
  try {
    await expect(run.win.locator('.st-title')).toHaveText('Dictations');
    await expect(run.win.locator('.bubble')).toHaveCount(6);
    expect((await run.win.evaluate(() => window.usefulVoice.firstRunState())).pending).toBe(false);
    await expect(run.win.locator('.fr')).toHaveCount(0);
    const marked = await settingsWhere(userData, (s) => s?.firstRunCompleted === true);
    expect(marked?.firstRunCompleted).toBe(true);
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('--force-first-run on a completed install shows the flow and saves nothing', async () => {
  const userData = await seedUserData({ firstRunCompleted: false });
  // Make a completed install with a key: save a key, relaunch so the gate marks it.
  let run = await launch('forced-seed-1', userData);
  try {
    await run.win.evaluate(() => window.usefulVoice.setApiKey('valid-original-key'));
    await settingsWhere(userData, (s) => typeof s?.apiKeyEncrypted === 'string');
  } finally {
    await run.stop();
  }
  run = await launch('forced-seed-2', userData);
  try {
    await settingsWhere(userData, (s) => s?.firstRunCompleted === true);
  } finally {
    await run.stop();
  }

  const files = ['settings.json', 'data.json'];
  const before = await Promise.all(files.map((file) => fs.readFile(path.join(userData, file))));
  const listing = async (): Promise<string[]> =>
    (await fs.readdir(userData)).filter((name) => name.endsWith('.json')).sort();
  const jsonBefore = await listing();

  run = await launch('forced', userData, ['--force-first-run']);
  try {
    const { win } = run;
    // It shows even though the install is complete and has a key, and it shows no saved
    // key: the claim card appears as designed.
    await expect(win.locator('.fr')).toBeVisible();
    await fr(win).getByRole('button', { name: 'Get started' }).click();
    await expect(win.locator('.fr-credit-figure')).toBeVisible();
    await expect(fr(win).getByText('Key saved.')).toHaveCount(0);

    // A different key works for this run.
    const key = fr(win).getByLabel('Deepgram API key');
    await key.fill('valid-forced-other-key');
    await key.press('Enter');
    await expect(page(win, 'deepgramKey')).toBeVisible();
    await page(win, 'deepgramKey').getByRole('button', { name: 'Continue', exact: true }).click();
    await expect(win.locator('.fr-ok', { hasText: 'Allowed' })).toBeVisible();
    await fr(win).getByRole('button', { name: 'Continue', exact: true }).click();

    // Pick German and a different hotkey.
    await expect(page(win, 'tryIt')).toBeVisible();
    await fr(win).getByRole('button', { name: 'Spoken language' }).click();
    await fr(win).getByRole('combobox').fill('Deutsch');
    await fr(win).getByRole('option', { name: /Deutsch/ }).first().click();
    await expect(fr(win).locator('.lang-trigger-label')).toHaveText('Deutsch');
    await fr(win).getByRole('button', { name: 'Change' }).click();
    await fr(win).getByLabel('Dictation hotkey').fill('Ctrl+Shift+K');
    await fr(win).getByLabel('Dictation hotkey').press('Enter');
    await expect(fr(win).getByText('Add Ctrl or Alt')).toHaveCount(0);
    // Display-only in a forced run: main checks and accepts it, and saves nothing.
    await expect(fr(win).locator('.fr-cap', { hasText: 'Shift' })).toBeVisible();
    await expect(fr(win).getByLabel('Practice area')).toHaveAttribute('placeholder', /Ctrl\+Shift\+K/);

    await fr(win).getByRole('button', { name: 'Start recording' }).click();
    await win.waitForTimeout(2200);
    await fr(win).getByRole('button', { name: 'Stop', exact: true }).click();
    await expect(fr(win).getByLabel('Practice area')).toHaveValue('Hello from Useful Voice.', { timeout: 20_000 });

    await fr(win).getByRole('button', { name: 'Finish setup' }).click();
    await fr(win).getByRole('button', { name: 'Open Useful Voice' }).click();
    await expect(win.locator('.fr')).toHaveCount(0);
    // The history is untouched: the practice dictation was not saved.
    expect(await win.evaluate(() => window.usefulVoice.getHistory().then((entries) => entries.length))).toBe(6);

    // The dictation really asked Deepgram for German: the forced language reached main.
    const log = await fs.readFile(path.join(userData, 'e2e.log'), 'utf8');
    const requests = log.split('\n').filter((line) => line.includes(' deepgram '));
    expect(requests.some((line) => line.includes('language=de'))).toBe(true);
  } finally {
    await run.stop();
  }

  const after = await Promise.all(files.map((file) => fs.readFile(path.join(userData, file))));
  files.forEach((file, index) => {
    expect(after[index]?.equals(before[index] as Buffer), `${file} changed during a forced run`).toBe(true);
  });
  expect(await listing(), 'a forced run created or removed a data file').toEqual(jsonBefore);

  // And the install is still complete: the next normal launch shows no flow.
  run = await launch('forced-after', userData);
  try {
    await expect(run.win.locator('.st-title')).toHaveText('Dictations');
    expect((await run.win.evaluate(() => window.usefulVoice.firstRunState())).pending).toBe(false);
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('skip from the key step, then Settings > Run setup again reopens it', async () => {
  const userData = await freshDir();
  let run = await launch('skip', userData);
  try {
    const { win } = run;
    await fr(win).getByRole('button', { name: 'Get started' }).click();
    await expect(page(win, 'engine')).toBeVisible();
    await fr(win).getByRole('button', { name: 'Skip setup' }).click();

    // The main window, with the key-missing banner.
    await expect(win.locator('.fr')).toHaveCount(0);
    await expect(win.locator('.st-title')).toHaveText('Dictations');
    await expect(win.locator('.banner')).toContainText('No Deepgram key.');
    const skipped = await settingsWhere(userData, (s) => s?.firstRunCompleted === true);
    expect(skipped?.firstRunCompleted).toBe(true);

    // Settings > Run setup again opens it at Welcome, with Close instead of Skip.
    await win.locator('.rail-item', { hasText: 'Settings' }).click();
    await win.getByRole('button', { name: 'Run setup again' }).click();
    await expect(win.locator('.fr')).toBeVisible();
    await expect(page(win, 'welcome')).toBeVisible();
    await expect(fr(win).getByRole('button', { name: 'Skip setup' })).toHaveCount(0);
    // Esc closes it, and stays on Settings.
    await win.keyboard.press('Escape');
    await expect(win.locator('.fr')).toHaveCount(0);
    await expect(win.locator('.rail-item[aria-current="page"]')).toHaveText(/Settings/);

    // It opens again, and Close works too.
    await win.getByRole('button', { name: 'Run setup again' }).click();
    await fr(win).getByRole('button', { name: 'Close' }).click();
    await expect(win.locator('.fr')).toHaveCount(0);
  } finally {
    await run.stop();
  }

  // A skip counts as finished: the next launch does not show the flow.
  run = await launch('skip-relaunch', userData);
  try {
    await expect(run.win.locator('.st-title')).toHaveText('Dictations');
    expect((await run.win.evaluate(() => window.usefulVoice.firstRunState())).pending).toBe(false);
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('microphone refused, then allowed while the step is open, moves on by itself', async () => {
  const userData = await freshDir();
  const run = await launch('mic-denied', userData);
  try {
    const { win } = run;
    // Windows refuses the microphone: getUserMedia rejects the way the OS answers.
    await win.evaluate(() => {
      const devices = navigator.mediaDevices;
      (window as unknown as { __realGetUserMedia: typeof devices.getUserMedia }).__realGetUserMedia = devices.getUserMedia.bind(devices);
      devices.getUserMedia = () => Promise.reject(new DOMException('Permission denied', 'NotAllowedError'));
    });
    await walkToMicrophone(win);
    await expect(fr(win).getByText('Microphone access is off for Useful Voice.')).toBeVisible();
    await expect(fr(win).getByRole('button', { name: 'Open Windows Settings' })).toBeVisible();
    await expect(fr(win).getByText('Waiting for access. This moves on by itself.')).toBeVisible();
    await shot(win, 'flow-mic-denied-live');

    // The person turns it on in Windows Settings: the step notices and moves on.
    await win.evaluate(() => {
      const devices = navigator.mediaDevices;
      devices.getUserMedia = (window as unknown as { __realGetUserMedia: typeof devices.getUserMedia }).__realGetUserMedia;
    });
    await expect(page(win, 'tryIt')).toBeVisible({ timeout: 10_000 });
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('reduced motion: steps change with no animation', async () => {
  const userData = await freshDir();
  const run = await launch('reduced-motion', userData);
  try {
    const { win } = run;
    const motion = (name: string) =>
      page(win, name).evaluate((node) => {
        const style = getComputedStyle(node);
        return { name: style.animationName, seconds: parseFloat(style.animationDuration) };
      });

    // With motion allowed, a step enters with its animation.
    await win.emulateMedia({ reducedMotion: 'no-preference' });
    await fr(win).getByRole('button', { name: 'Get started' }).click();
    await expect(page(win, 'engine')).toBeVisible();
    const normal = await motion('engine');
    expect(normal.name).toBe('fr-enter');
    expect(normal.seconds).toBeGreaterThan(0.1);

    // Reduced: no animation on the next step, and none left on the meter's bars.
    await win.emulateMedia({ reducedMotion: 'reduce' });
    await fr(win).getByRole('button', { name: 'Back' }).click();
    await expect(page(win, 'welcome')).toBeVisible();
    await fr(win).getByRole('button', { name: 'Get started' }).click();
    await expect(page(win, 'engine')).toBeVisible();
    const reduced = await motion('engine');
    expect(reduced.name).toBe('none');
    expect(reduced.seconds).toBeLessThan(0.001);

    const key = fr(win).getByLabel('Deepgram API key');
    await key.fill('valid-motion-key');
    await key.press('Enter');
    await page(win, 'deepgramKey').getByRole('button', { name: 'Continue', exact: true }).click();
    await expect(page(win, 'microphone')).toBeVisible();
    const bar = await win.locator('.fr-meter-bar').first().evaluate((node) => getComputedStyle(node).transitionDuration);
    expect(parseFloat(bar)).toBeLessThan(0.001);
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('every step in light and dark at the smallest window size', async () => {
  const steps = ['welcome', 'engine', 'errKey', 'deepgramKey', 'microphone', 'errMic', 'tryIt', 'tryItDone', 'done'];
  for (const step of steps) {
    const userData = await freshDir();
    const run = await launch(`shots-${step}`, userData, ['--force-first-run', `--first-run-step=${step}`]);
    try {
      const { win } = run;
      // The smallest window the app allows.
      await run.app.evaluate(({ BrowserWindow }) => {
        const window = BrowserWindow.getAllWindows().find((w) => w.webContents.getURL().includes('view=main'));
        window?.setContentSize(820, 560 - 32);
      });
      await win.setViewportSize({ width: 820, height: 560 });
      await expect(win.locator('.fr-page')).toBeVisible();
      for (const theme of ['light', 'dark']) {
        await win.evaluate((value) => {
          document.documentElement.dataset.theme = value;
        }, theme);
        await shot(win, `step-${step}-${theme}`);
        // Nothing may spill out of the stage at the smallest size.
        const overflow = await win.locator('.fr-page').evaluate((node) => node.scrollWidth - node.clientWidth);
        expect(overflow, `${step} ${theme} overflows sideways`).toBeLessThanOrEqual(0);
      }
    } finally {
      await run.stop();
      await remove(userData);
    }
  }
});

/** What the e2e hooks in main report. */
const hooks = (app: ElectronApplication) => ({
  open: () => app.evaluate(() => (globalThis as unknown as { __uv: { firstRunOpen(): boolean } }).__uv.firstRunOpen()),
  state: () => app.evaluate(() => (globalThis as unknown as { __uv: { serviceState(): string } }).__uv.serviceState()),
  source: () => app.evaluate(() => (globalThis as unknown as { __uv: { lastSource(): string | undefined } }).__uv.lastSource()),
  windows: () => app.evaluate(() => (globalThis as unknown as { __uv: { mainWindows(): number } }).__uv.mainWindows()),
  pressHotkey: () => app.evaluate(() => (globalThis as unknown as { __uv: { pressHotkey(): Promise<void> } }).__uv.pressHotkey()),
  cancel: () => app.evaluate(() => (globalThis as unknown as { __uv: { cancel(): Promise<void> } }).__uv.cancel()),
  call: (name: string, arg?: unknown) =>
    app.evaluate(
      (_electron, args) => (globalThis as unknown as { __uv: Record<string, (value?: unknown) => unknown> }).__uv[args.name]?.(args.arg),
      { name, arg },
    ),
  requests: () => app.evaluate(() => (globalThis as unknown as { __uv: { stateRequests(): number } }).__uv.stateRequests()),
});

async function until(check: () => Promise<boolean>, what: string, ms = 10_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** Welcome to Try it on a fresh folder, with a key the stub accepts. */
async function walkToTryIt(win: Page): Promise<void> {
  await walkToMicrophone(win);
  await expect(fr(win).locator('.fr-ok', { hasText: 'Allowed' })).toBeVisible();
  await fr(win).getByRole('button', { name: 'Continue', exact: true }).click();
  await expect(page(win, 'tryIt')).toBeVisible();
}

test('launch rule: a pending flow opens the window itself, a login launch does not', async () => {
  // Tray-only (no e2e auto-open): only the launch rule can open the window.
  const fresh = await freshDir();
  let run = await launch('launch-fresh', fresh, ['--e2e-tray-only']);
  try {
    await expect(run.win.locator('.fr')).toBeVisible();
    expect(await hooks(run.app).windows()).toBe(1);
  } finally {
    await run.stop();
  }

  // Launched by the login entry: no window jumps in front of the person.
  const env = { ...process.env } as Record<string, string>;
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({
    args: [path.join(root, 'dist', 'main', 'index.js'), `--uv-data-dir=${fresh}`, '--e2e', '--e2e-tray-only', '--autostart'],
    env,
  });
  try {
    await until(async () => (await app.evaluate(() => typeof (globalThis as { __uv?: unknown }).__uv)) === 'object', 'main to start');
    await new Promise((resolve) => setTimeout(resolve, 2500));
    expect(await hooks(app).windows()).toBe(0);
  } finally {
    await app.close();
  }

  // A completed install stays tray-only too.
  const done = await seedUserData();
  const quiet = await electron.launch({
    args: [path.join(root, 'dist', 'main', 'index.js'), `--uv-data-dir=${done}`, '--e2e', '--e2e-tray-only'],
    env,
  });
  try {
    await until(async () => (await quiet.evaluate(() => typeof (globalThis as { __uv?: unknown }).__uv)) === 'object', 'main to start');
    await new Promise((resolve) => setTimeout(resolve, 2500));
    expect(await hooks(quiet).windows()).toBe(0);
  } finally {
    await quiet.close();
    await remove(fresh);
    await remove(done);
  }
});

test('closing the window mid-flow ends it: hotkey dictations paste again and a recording stops', async () => {
  const userData = await freshDir();
  const run = await launch('flow-lifetime', userData);
  try {
    const { win, app } = run;
    const main = hooks(app);
    await walkToTryIt(win);
    expect(await main.open()).toBe(true);

    // While the flow is open the hotkey dictates into the flow: copy only, nothing pasted.
    await main.pressHotkey();
    expect(await main.source()).toBe('window');
    await until(async () => (await main.state()) === 'recording', 'the practice recording');

    // The window is closed mid-recording: the flow is over and the recording stops.
    await app.evaluate(({ BrowserWindow }) => {
      BrowserWindow.getAllWindows().find((w) => w.webContents.getURL().includes('view=main'))?.close();
    });
    await until(async () => (await main.state()) === 'idle', 'the recording to stop');
    expect(await main.open()).toBe(false);

    // Now the hotkey is a hotkey again: it pastes into the app in front.
    await main.pressHotkey();
    expect(await main.source()).toBe('hotkey');
    await main.cancel();
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('leaving Try it while a practice recording runs stops it', async () => {
  const userData = await freshDir();
  const run = await launch('leave-recording', userData);
  try {
    const { win, app } = run;
    const main = hooks(app);
    await walkToTryIt(win);

    // Back.
    await fr(win).getByRole('button', { name: 'Start recording' }).click();
    await until(async () => (await main.state()) === 'recording', 'recording');
    await fr(win).getByRole('button', { name: 'Back' }).click();
    await until(async () => (await main.state()) === 'idle', 'recording to stop after Back');

    // Skip setup (close).
    await fr(win).getByRole('button', { name: 'Continue', exact: true }).click();
    await fr(win).getByRole('button', { name: 'Start recording' }).click();
    await until(async () => (await main.state()) === 'recording', 'recording again');
    await fr(win).getByRole('button', { name: 'Skip setup' }).click();
    await until(async () => (await main.state()) === 'idle', 'recording to stop after Skip');
    await expect(win.locator('.fr')).toHaveCount(0);
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('a malformed hotkey is refused in the flow and never saved', async () => {
  const userData = await freshDir();
  const run = await launch('hotkey', userData);
  try {
    const { win } = run;
    await walkToTryIt(win);
    const caps = () => fr(win).locator('.fr-caps .fr-cap').allTextContents();
    const before = await caps();
    await fr(win).getByRole('button', { name: 'Change' }).click();
    const input = fr(win).getByLabel('Dictation hotkey');
    for (const bad of ['Ctrl', 'Ctrl+Alt', 'Ctrl+DefinitelyNotAKey', 'Space', 'Ctrl++A', 'Ctrl+A+', 'Ctrl+Alt+F25']) {
      await input.fill(bad);
      await input.press('Enter');
      await expect(fr(win).locator('.fr-inline-err')).not.toHaveText('');
      // The field stays open, and neither the file nor the shown hotkey changed.
      await expect(input).toBeVisible();
      expect(JSON.stringify(await readJson(path.join(userData, 'settings.json')))).not.toContain(`"${bad}"`);
    }
    await input.fill('Ctrl+Alt+Space');
    await input.press('Enter');
    await expect(fr(win).getByRole('button', { name: 'Change' })).toBeVisible();
    expect(await caps()).toEqual(before);
    // Another app owns it (Windows refuses the trial registration): the flow says so and
    // keeps the old hotkey, saved and shown.
    await fr(win).getByRole('button', { name: 'Change' }).click();
    await hooks(run.app).call('refuseAccelerator', 'Ctrl+Alt+J');
    await input.fill('ctrl+alt+j');
    await input.press('Enter');
    await expect(fr(win).locator('.fr-inline-err')).toContainText('Another app is using');
    await expect(input).toBeVisible();
    expect(JSON.stringify(await readJson(path.join(userData, 'settings.json')))).not.toMatch(/ctrl\+alt\+j/i);
    // The current hotkey in another spelling is no conflict and needs no trial, even if the
    // OS would refuse it (it is already registered by this app).
    await hooks(run.app).call('refuseAccelerator', 'Control+Alt+Space');
    await input.fill('control+alt+space');
    await input.press('Enter');
    await expect(fr(win).getByRole('button', { name: 'Change' })).toBeVisible();
    await hooks(run.app).call('refuseAccelerator', null);
    await fr(win).getByRole('button', { name: 'Change' }).click();

    // The language hotkey's own combination says why.
    await fr(win).getByLabel('Dictation hotkey').fill('Ctrl+Alt+L');
    await fr(win).getByLabel('Dictation hotkey').press('Enter');
    await expect(fr(win).locator('.fr-inline-err')).toContainText("can't share");

    // A good one is saved.
    await fr(win).getByLabel('Dictation hotkey').fill('Ctrl+Alt+K');
    await fr(win).getByLabel('Dictation hotkey').press('Enter');
    await expect(fr(win).locator('.fr-cap', { hasText: 'K' })).toBeVisible();
    const saved = await settingsWhere(userData, (s) => (s?.settings as { hotkey?: { accelerator?: string } } | undefined)?.hotkey?.accelerator === 'Control+Alt+K');
    expect((saved?.settings as { hotkey: { accelerator: string } }).hotkey.accelerator).toBe('Control+Alt+K');
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('a slow key check left and re-entered does not leave Connect stuck', async () => {
  const userData = await freshDir();
  const run = await launch('slow-check', userData);
  try {
    const { win } = run;
    await fr(win).getByRole('button', { name: 'Get started' }).click();
    const key = fr(win).getByLabel('Deepgram API key');
    await key.fill('slow-key-123');
    await key.press('Enter');
    await expect(fr(win).getByRole('button', { name: 'Checking the key…' })).toBeVisible();
    await fr(win).getByRole('button', { name: 'Back' }).click();
    await fr(win).getByRole('button', { name: 'Get started' }).click();
    const connect = fr(win).getByRole('button', { name: 'Connect', exact: true });
    await expect(connect).toBeEnabled();
    // The old check finishes while we are here: its answer is ignored, nothing is saved.
    await win.waitForTimeout(2200);
    await expect(page(win, 'engine')).toBeVisible();
    expect((await readJson(path.join(userData, 'settings.json')))?.apiKeyEncrypted).toBeUndefined();
    // And the page works again.
    await connect.click();
    await expect(page(win, 'deepgramKey')).toBeVisible({ timeout: 10_000 });
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('a failed key save and an unsendable key are handled without a request or a stuck button', async () => {
  const userData = await freshDir();
  const run = await launch('key-errors', userData);
  try {
    const { win, app } = run;
    await fr(win).getByRole('button', { name: 'Get started' }).click();
    const key = fr(win).getByLabel('Deepgram API key');
    const requests = async (): Promise<number> =>
      (await fs.readFile(path.join(userData, 'e2e.log'), 'utf8')).split('\n').filter((line) => line.includes(' deepgram ')).length;

    // A key with a space cannot be a header value: refused, and no request goes out.
    const before = await requests();
    await key.fill('not a valid key');
    await key.press('Enter');
    await expect(fr(win).locator('.fr-alert', { hasText: "Deepgram didn't accept this key" })).toBeVisible();
    expect(await requests()).toBe(before);

    // The save call rejects: the page says so and Connect works again.
    await app.evaluate(({ ipcMain }) => {
      ipcMain.removeHandler('firstrun:save-key');
      ipcMain.handle('firstrun:save-key', () => {
        throw new Error('boom');
      });
    });
    await key.fill('valid-save-fails');
    await key.press('Enter');
    await expect(fr(win).locator('.fr-alert', { hasText: "Couldn't save the key" })).toBeVisible();
    await expect(fr(win).getByRole('button', { name: 'Connect', exact: true })).toBeEnabled();
    await expect(page(win, 'engine')).toBeVisible();
  } finally {
    await run.stop();
    await remove(userData);
  }
});

/** Replaces getUserMedia in the page with a recorder of what it hands out. */
async function watchMicrophone(win: Page, mode: 'live' | 'slow' | 'denied'): Promise<void> {
  await win.evaluate((how) => {
    const w = window as unknown as { __streams: MediaStream[]; __calls: number; __vis: string };
    w.__streams = [];
    w.__calls = 0;
    w.__vis = 'visible';
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => w.__vis });
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => w.__vis === 'hidden' });
    const devices = navigator.mediaDevices;
    const real = devices.getUserMedia.bind(devices);
    devices.getUserMedia = async (constraints) => {
      w.__calls += 1;
      if (how === 'denied') throw new DOMException('Permission denied', 'NotAllowedError');
      if (how === 'slow') await new Promise((resolve) => setTimeout(resolve, 900));
      const stream = await real(constraints);
      w.__streams.push(stream);
      return stream;
    };
  }, mode);
}
const setVisibility = (win: Page, value: 'visible' | 'hidden') =>
  win.evaluate((v) => {
    (window as unknown as { __vis: string }).__vis = v;
    document.dispatchEvent(new Event('visibilitychange'));
  }, value);
const liveTracks = (win: Page) =>
  win.evaluate(() =>
    (window as unknown as { __streams: MediaStream[] }).__streams.flatMap((s) => s.getTracks()).filter((t) => t.readyState === 'live').length,
  );

test('the microphone is closed on leaving the step, and a late answer or a hidden retry never holds it', async () => {
  const userData = await freshDir();
  const run = await launch('mic-lifetime', userData);
  try {
    const { win } = run;
    // Leaving the step closes every track.
    await watchMicrophone(win, 'live');
    await walkToMicrophone(win);
    await expect(fr(win).locator('.fr-ok', { hasText: 'Allowed' })).toBeVisible();
    expect(await liveTracks(win)).toBeGreaterThan(0);
    await fr(win).getByRole('button', { name: 'Continue', exact: true }).click();
    await expect(page(win, 'tryIt')).toBeVisible();
    expect(await liveTracks(win)).toBe(0);

    // A request still pending when the window hides: its stream is closed when it lands.
    await watchMicrophone(win, 'slow');
    await fr(win).getByRole('button', { name: 'Back' }).click();
    await expect(page(win, 'microphone')).toBeVisible();
    await setVisibility(win, 'hidden');
    await win.waitForTimeout(1600);
    expect(await liveTracks(win)).toBe(0);
    // Shown again: it starts again.
    await setVisibility(win, 'visible');
    await expect(fr(win).locator('.fr-ok', { hasText: 'Allowed' })).toBeVisible({ timeout: 5_000 });
    expect(await liveTracks(win)).toBeGreaterThan(0);
  } finally {
    await run.stop();
    await remove(userData);
  }

  // Denied retries stop while hidden and resume when shown.
  const second = await freshDir();
  const again = await launch('mic-denied-hidden', second);
  try {
    const { win } = again;
    await watchMicrophone(win, 'denied');
    await walkToMicrophone(win);
    await expect(fr(win).getByText('Microphone access is off for Useful Voice.')).toBeVisible();
    await setVisibility(win, 'hidden');
    await win.waitForTimeout(300);
    const calls = () => win.evaluate(() => (window as unknown as { __calls: number }).__calls);
    const atHide = await calls();
    await win.waitForTimeout(2600);
    expect(await calls()).toBe(atHide);
    await setVisibility(win, 'visible');
    await until(async () => (await calls()) > atHide, 'retries to resume when shown');
  } finally {
    await again.stop();
    await remove(second);
  }
});

test('Run setup again pressed twice opens one flow and reads the state once', async () => {
  const userData = await freshDir();
  const run = await launch('double-open', userData);
  try {
    const { win, app } = run;
    await fr(win).getByRole('button', { name: 'Skip setup' }).click();
    await win.locator('.rail-item', { hasText: 'Settings' }).click();
    // Hold the state read so both presses land while the first is still pending.
    const before = await hooks(app).requests();
    await hooks(app).call('holdStateRequests');
    const button = win.getByRole('button', { name: 'Run setup again' });
    await button.click();
    await button.click();
    await win.waitForTimeout(400);
    await hooks(app).call('releaseStateRequests');
    await expect(win.locator('.fr')).toHaveCount(1);
    expect((await hooks(app).requests()) - before).toBe(1);
  } finally {
    await run.stop();
    await remove(userData);
  }
});

test('leaving Try it while the recorder is still starting never starts a recording', async () => {
  const userData = await freshDir();
  const run = await launch('start-pending', userData);
  try {
    const { win, app } = run;
    const main = hooks(app);
    // Count the live tracks the recorder window opens.
    const recorder = app.windows().find((w) => w.url().includes('view=recorder'));
    expect(recorder, 'the recorder page').toBeTruthy();
    await (recorder as Page).evaluate(() => {
      const w = window as unknown as { __streams: MediaStream[] };
      w.__streams = [];
      const devices = navigator.mediaDevices;
      const real = devices.getUserMedia.bind(devices);
      devices.getUserMedia = async (constraints) => {
        const stream = await real(constraints);
        w.__streams.push(stream);
        return stream;
      };
    });
    const live = () =>
      (recorder as Page).evaluate(() =>
        (window as unknown as { __streams: MediaStream[] }).__streams.flatMap((s) => s.getTracks()).filter((t) => t.readyState === 'live').length,
      );

    await walkToTryIt(win);
    await main.call('holdRecorderStart');
    await fr(win).getByRole('button', { name: 'Start recording' }).click();
    // The recorder has not answered: the service and the page both still read idle.
    await win.waitForTimeout(300);
    expect(await main.state()).toBe('idle');
    await fr(win).getByRole('button', { name: 'Back' }).click();
    await win.waitForTimeout(300);
    await main.call('releaseRecorderStart');
    await win.waitForTimeout(2000);
    expect(await main.state()).toBe('idle');
    expect(await live()).toBe(0);
    await expect(fr(win).getByRole('button', { name: 'Continue', exact: true })).toBeVisible();

    // The same from the error state: a failed practice, Start again, leave while held.
    await fr(win).getByRole('button', { name: 'Continue', exact: true }).click();
    await main.call('failNextRecorderStart');
    await fr(win).getByRole('button', { name: 'Start recording' }).click();
    await until(async () => (await main.state()) === 'error', 'the practice error');
    await main.call('holdRecorderStart');
    await fr(win).getByRole('button', { name: 'Start recording' }).click();
    await win.waitForTimeout(300);
    await fr(win).getByRole('button', { name: 'Back' }).click();
    await win.waitForTimeout(300);
    await main.call('releaseRecorderStart');
    await win.waitForTimeout(2000);
    expect(await main.state()).toBe('idle');
    expect(await live()).toBe(0);
  } finally {
    await run.stop();
    await remove(userData);
  }
});

// ---- the engine step and the saved voice model ---------------------------------------

test('the engine step shows the model it will use and Continue applies exactly that', async () => {
  for (const [saved, shown, expected] of [
    ['elevenlabs:scribe_v2', 'Deepgram Nova-3', 'deepgram:nova-3'],
    ['deepgram:nova-3-medical', 'Deepgram Nova-3 Medical', 'deepgram:nova-3-medical'],
  ] as const) {
    const userData = await freshDir();
    await fs.writeFile(path.join(userData, 'settings.json'), JSON.stringify({ version: 1, settings: { voiceModelId: saved } }));
    const run = await launch(`engine-${expected}`, userData);
    try {
      const { win } = run;
      await fr(win).getByRole('button', { name: 'Get started' }).click();
      await expect(page(win, 'engine')).toBeVisible();
      await expect(win.locator('.fr-card-name')).toHaveText(shown);
      // Nothing changes until Continue.
      expect((await readJson(path.join(userData, 'settings.json')))?.settings).toMatchObject({ voiceModelId: saved });
      const key = fr(win).getByLabel('Deepgram API key');
      await key.fill('valid-walk-key');
      await key.press('Enter');
      await expect(page(win, 'deepgramKey')).toBeVisible();
      await page(win, 'deepgramKey').getByRole('button', { name: 'Continue', exact: true }).click();
      await expect(page(win, 'microphone')).toBeVisible();
      const after = await settingsWhere(userData, (s) => (s?.settings as { voiceModelId?: string } | undefined)?.voiceModelId === expected);
      expect((after?.settings as { voiceModelId: string }).voiceModelId).toBe(expected);
    } finally {
      await run.stop();
      await remove(userData);
    }
  }
});

test('a forced setup applies the engine for its own dictations and leaves the saved model alone', async () => {
  const userData = await seedUserData({ firstRunCompleted: true });
  await fs.writeFile(
    path.join(userData, 'settings.json'),
    JSON.stringify({ version: 1, firstRunCompleted: true, settings: { voiceModelId: 'elevenlabs:scribe_v2' } }),
  );
  const before = await fs.readFile(path.join(userData, 'settings.json'));
  const run = await launch('engine-forced', userData, ['--force-first-run']);
  try {
    const { win } = run;
    await fr(win).getByRole('button', { name: 'Get started' }).click();
    await expect(win.locator('.fr-card-name')).toHaveText('Deepgram Nova-3');
    const key = fr(win).getByLabel('Deepgram API key');
    await key.fill('valid-walk-key');
    await key.press('Enter');
    await page(win, 'deepgramKey').getByRole('button', { name: 'Continue', exact: true }).click();
    await expect(page(win, 'microphone')).toBeVisible();
    // The saved choice is what Settings reports, and the file is byte for byte what it was.
    expect((await win.evaluate(() => window.usefulVoice.getSettings())).voiceModelId).toBe('elevenlabs:scribe_v2');
    expect((await fs.readFile(path.join(userData, 'settings.json'))).equals(before)).toBe(true);
  } finally {
    await run.stop();
    await remove(userData);
  }
});
