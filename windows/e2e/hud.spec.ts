import { _electron as electron, expect, test, type ElectronApplication, type Page } from '@playwright/test';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { seedUserData } from './fixtures.js';

// The recording pill's scrolling waveform on the built app. The HUD window only exists
// while a dictation runs, so the test opens a second window on the HUD page and feeds it
// the same IPC messages main sends: a recording frame and a stream of input levels.

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = process.env.E2E_OUT ?? path.join(root, 'e2e-results');
const shots = path.join(out, 'shots');

let app: ElectronApplication;
let userData: string;

test.beforeAll(async () => {
  userData = await seedUserData();
  const env = { ...process.env } as Record<string, string>;
  delete env.ELECTRON_RUN_AS_NODE;
  app = await electron.launch({
    args: [path.join(root, 'dist', 'main', 'index.js'), `--uv-data-dir=${userData}`, '--e2e'],
    env,
    // `_electron.launch` bypasses the config's `use` options, so video and trace are switched on here.
    recordVideo: { dir: path.join(out, 'video-hud'), size: { width: 520, height: 96 } },
  });
  await app.context().tracing.start({ screenshots: true, snapshots: true });
});

test.afterAll(async () => {
  try {
    await app?.context().tracing.stop({ path: path.join(out, 'trace-hud.zip') });
  } finally {
    try {
      await app?.close();
    } finally {
      if (userData) await fs.rm(userData, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    }
  }
});

async function hudPage(): Promise<Page> {
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
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    for (const page of app.windows()) {
      if (page.url().includes('view=hud')) return page;
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('the HUD page never opened');
}

/** Sends a message to the HUD window the way main does. */
async function send(channel: string, payload: unknown): Promise<void> {
  await app.evaluate(
    ({ BrowserWindow }, args) => {
      const win = BrowserWindow.getAllWindows().find((w) => w.webContents.getURL().includes('view=hud'));
      win?.webContents.send(args.channel, args.payload);
    },
    { channel, payload },
  );
}

test('the recording pill draws a moving waveform that fits the window', async () => {
  const hud = await hudPage();
  await fs.mkdir(shots, { recursive: true });
  await send('hud:view', { kind: 'recording', elapsedSeconds: 12, seq: 1 });
  const bars = hud.locator('.hud-capsule .waveform rect');
  await expect(bars).toHaveCount(30);
  await expect(hud.locator('.hud-capsule .landing-mark')).toHaveCount(0);

  const heights = async (): Promise<number[]> => bars.evaluateAll((nodes) => nodes.map((n) => Number(n.getAttribute('height'))));
  // Silence: every bar sits at the 3 px floor.
  await send('hud:level', 0);
  await hud.waitForTimeout(300);
  expect(Math.max(...(await heights()))).toBeLessThan(4);

  // Speech-like bursts for two seconds: speech scrolls in from the right.
  for (let i = 0; i < 40; i += 1) {
    const burst = Math.abs(Math.sin(i / 3)) * 0.35 + 0.02;
    await send('hud:level', burst);
    await hud.waitForTimeout(50);
  }
  const after = await heights();
  expect(Math.max(...after)).toBeGreaterThan(14);
  // Oldest on the left is still near the floor or lower than the newest: newest is right.
  const opacities = await bars.evaluateAll((nodes) => nodes.map((n) => Number(n.getAttribute('opacity'))));
  expect(opacities[0]).toBeCloseTo(0.35, 2);
  expect(opacities[29]).toBeCloseTo(1, 2);

  // The pill, with the record dot, timer and Esc, sits inside the 520 px window.
  const capsule = await hud.locator('.hud-capsule').boundingBox();
  expect(capsule).not.toBeNull();
  const viewport = await hud.evaluate(() => ({ w: window.innerWidth, h: window.innerHeight }));
  expect(viewport).toEqual({ w: 520, h: 96 });
  expect(capsule!.y).toBeGreaterThanOrEqual(0);
  expect(capsule!.y + capsule!.height).toBeLessThanOrEqual(96);
  expect(capsule!.x).toBeGreaterThan(0);
  expect(capsule!.x + capsule!.width).toBeLessThan(520);
  const overflow = await hud.locator('.hud-capsule').evaluate((node) => node.scrollWidth - node.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);

  // With a stop countdown showing, it still fits.
  await send('hud:view', { kind: 'recording', elapsedSeconds: 13, stopsIn: 8, seq: 1 });
  await hud.waitForTimeout(300);
  const wide = await hud.locator('.hud-capsule').boundingBox();
  expect(wide!.x + wide!.width).toBeLessThan(520);

  await hud.screenshot({ path: path.join(shots, 'hud-recording-waveform.png') });
});
