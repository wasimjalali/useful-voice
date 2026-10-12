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
    await expect(fr(win).getByText('Key works.')).toBeVisible();
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
    await expect(fr(win).getByText("It worked. That's all there is to it.")).toBeVisible();
    await shot(win, 'flow-05-try-it-worked');
    await fr(win).getByRole('button', { name: 'Finish setup' }).click();

    // Done lands in the main window.
    await expect(page(win, 'done')).toBeVisible();
    await expect(fr(win).getByRole('heading', { name: "You're all set" })).toBeVisible();
    await shot(win, 'flow-06-done');
    await fr(win).getByRole('button', { name: 'Open Useful Voice' }).click();
    await expect(win.locator('.fr')).toHaveCount(0);
    await expect(win.locator('.st-title')).toHaveText('Stream');
    const done = await settingsWhere(userData, (s) => s?.firstRunCompleted === true);
    expect(done?.firstRunCompleted).toBe(true);
  } finally {
    await run.stop();
  }

  // Relaunch on the same folder: no flow.
  run = await launch('fresh-relaunch', userData);
  try {
    await expect(run.win.locator('.st-title')).toHaveText('Stream');
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
    await expect(run.win.locator('.st-title')).toHaveText('Stream');
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
    await fr(win).getByLabel('Dictation hotkey').fill('Ctrl+Shift');
    await fr(win).getByLabel('Dictation hotkey').press('Enter');
    await expect(fr(win).getByText('Add Ctrl or Alt')).toHaveCount(0);
    await expect(win.locator('.fr-cap', { hasText: 'Shift' })).toBeVisible();
    await expect(fr(win).getByLabel('Practice area')).toHaveAttribute('placeholder', /Ctrl\+Shift/);

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
    await expect(run.win.locator('.st-title')).toHaveText('Stream');
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
    await expect(win.locator('.st-title')).toHaveText('Stream');
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
    await expect(run.win.locator('.st-title')).toHaveText('Stream');
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
