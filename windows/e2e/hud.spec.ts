import { _electron as electron, expect, test, type ElectronApplication, type Page } from '@playwright/test';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { seedUserData } from './fixtures.js';

// The HUD bubble on the built app: waveform, placements (bottom, beside the cursor, flipped), colorways and halo. The HUD window only exists
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

/** Plain-page backdrop for screenshots: the HUD window is transparent, so a shot needs something behind it. */
async function shoot(hud: Page, name: string, backdrop = '#a8aeb3'): Promise<void> {
  await hud.evaluate((color) => {
    document.documentElement.style.background = color;
  }, backdrop);
  await hud.screenshot({ path: path.join(shots, name) });
  await hud.evaluate(() => {
    document.documentElement.style.background = '';
  });
}

type Place = { kind: 'bottom' } | { kind: 'caret'; flipped: boolean };
type Colorway = 'ink' | 'paper' | 'signal' | 'accent';

const SURFACE: Record<Colorway, { light: string; dark: string }> = {
  ink: { light: 'rgb(23, 23, 23)', dark: 'rgb(32, 32, 32)' },
  paper: { light: 'rgb(255, 255, 255)', dark: 'rgb(242, 242, 242)' },
  signal: { light: 'rgb(23, 23, 23)', dark: 'rgb(32, 32, 32)' },
  accent: { light: 'rgb(23, 23, 23)', dark: 'rgb(32, 32, 32)' },
};
/** The record dot's colour per colorway (accent #3366FF). */
const REC: Record<Colorway, string> = {
  ink: 'rgb(240, 121, 92)',
  paper: 'rgb(194, 65, 42)',
  signal: 'rgb(240, 121, 92)',
  accent: 'rgb(51, 102, 255)',
};

const placements: Array<[string, Place]> = [
  ['bottom', { kind: 'bottom' }],
  ['caret', { kind: 'caret', flipped: false }],
  ['caret-flipped', { kind: 'caret', flipped: true }],
];
const colorways: Colorway[] = ['ink', 'paper', 'signal', 'accent'];

let hudPageHandle: Page;

test.beforeEach(async () => {
  hudPageHandle ??= await hudPage();
  await fs.mkdir(shots, { recursive: true });
  await hudPageHandle.emulateMedia({ reducedMotion: 'no-preference' });
  await send('hud:view', null);
  await hudPageHandle.waitForTimeout(300);
});

test('the recording bubble draws a moving 16-bar waveform that fits the window', async () => {
  const hud = hudPageHandle;
  await send('hud:view', { kind: 'recording', elapsedSeconds: 12, seq: 1 });
  const bars = hud.locator('.hud-capsule .waveform rect');
  await expect(bars).toHaveCount(16);
  await expect(hud.locator('.hud-capsule .landing-mark')).toHaveCount(0);
  expect(await hud.locator('.hud-capsule .waveform').evaluate((n) => [n.getAttribute('width'), n.getAttribute('height')])).toEqual(['44', '14']);

  const heights = async (): Promise<number[]> => bars.evaluateAll((nodes) => nodes.map((n) => Number(n.getAttribute('height'))));
  // Silence: every bar sits at the 2 px floor.
  await send('hud:level', 0);
  await hud.waitForTimeout(400);
  expect(Math.max(...(await heights()))).toBeLessThan(3);

  // Speech-like bursts for two seconds: speech scrolls in from the right.
  for (let i = 0; i < 40; i += 1) {
    const burst = Math.abs(Math.sin(i / 3)) * 0.35 + 0.02;
    await send('hud:level', burst);
    await hud.waitForTimeout(50);
  }
  const after = await heights();
  expect(Math.max(...after)).toBeGreaterThan(8);
  // A bar's opacity follows its level, 0.45 to 1.
  const opacities = await bars.evaluateAll((nodes) => nodes.map((n) => Number(n.getAttribute('opacity'))));
  expect(Math.min(...opacities)).toBeGreaterThanOrEqual(0.449);
  expect(Math.max(...opacities)).toBeGreaterThan(0.7);

  // The bubble, 30 high with the dot, timer and esc, sits inside the 520 x 96 window.
  const capsule = await hud.locator('.hud-capsule').boundingBox();
  expect(capsule).not.toBeNull();
  const viewport = await hud.evaluate(() => ({ w: window.innerWidth, h: window.innerHeight }));
  expect(viewport).toEqual({ w: 520, h: 96 });
  expect(capsule!.height).toBeCloseTo(30, 0);
  expect(capsule!.y).toBeGreaterThanOrEqual(0);
  expect(capsule!.y + capsule!.height).toBeLessThanOrEqual(96);
  expect(capsule!.x).toBeGreaterThan(0);
  expect(capsule!.x + capsule!.width).toBeLessThan(520);
  const overflow = await hud.locator('.hud-capsule').evaluate((node) => node.scrollWidth - node.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);
  await expect(hud.locator('.hud-kbd')).toHaveText('esc');

  // With a stop countdown showing, it still fits.
  await send('hud:view', { kind: 'recording', elapsedSeconds: 13, stopsIn: 8, seq: 1 });
  await hud.waitForTimeout(400);
  const wide = await hud.locator('.hud-capsule').boundingBox();
  expect(wide!.x + wide!.width).toBeLessThan(520);
  expect(wide!.width).toBeGreaterThan(capsule!.width);

  await shoot(hud, 'hud-recording-waveform.png');
});

for (const [placeName, place] of placements) {
  for (const colorway of colorways) {
    test(`${placeName} placement, ${colorway}: recording, transcribing mid-bloom, inserting, done`, async () => {
      const hud = hudPageHandle;
      const style = { colorway, accent: '#3366FF', systemDark: false };
      const frame = (view: Record<string, unknown>, seq: number): Promise<void> => send('hud:view', { ...view, seq, placement: place, style });
      const capsule = hud.locator('.hud-capsule');
      const tag = `${placeName}-${colorway}`;
      const flipped = place.kind === 'caret' && place.flipped;

      // Recording: the bloom rings are out right after the start.
      await frame({ kind: 'recording', elapsedSeconds: 3 }, 1);
      await hud.waitForTimeout(140);
      await shoot(hud, `hud-${tag}-bloom.png`);
      const rings = await hud.locator('.hud-ring').evaluateAll((nodes) => nodes.map((n) => Number(getComputedStyle(n).opacity)));
      expect(Math.max(...rings)).toBeGreaterThan(0.1);
      // Speech; the switch to transcribing arrives while the second ring is still growing.
      for (let i = 0; i < 9; i += 1) {
        await send('hud:level', Math.abs(Math.sin(i / 2)) * 0.3 + 0.03);
        await hud.waitForTimeout(50);
      }
      await expect(capsule).toHaveAttribute('data-kind', 'recording');
      const box = (await capsule.boundingBox())!;
      expect(box.height).toBeCloseTo(30, 0);
      if (place.kind === 'bottom') {
        expect(box.x + box.width / 2).toBeCloseTo(260, 0);
        expect(box.y + box.height).toBeCloseTo(68, 0);
        await expect(hud.locator('.hud-tail')).toBeHidden();
        await expect(hud.locator('.hud-kbd')).toHaveText('esc');
      } else {
        expect(box.y + box.height / 2).toBeCloseTo(48, 0);
        const tail = hud.locator('.hud-tail');
        await expect(tail).toBeVisible();
        const tb = (await tail.boundingBox())!;
        const edge = flipped ? box.x + box.width : box.x;
        expect(edge).toBeCloseTo(flipped ? 492 : 28, 0);
        expect(tb.x + tb.width / 2).toBeCloseTo(edge, 0);
        expect(tb.y + tb.height / 2).toBeCloseTo(48, 0);
        await expect(hud.locator('.hud-kbd')).toHaveCount(0);
      }
      expect(await capsule.evaluate((n) => getComputedStyle(n).backgroundColor)).toBe(SURFACE[colorway].light);
      expect(await hud.locator('.hud-dot').evaluate((n) => getComputedStyle(n).backgroundColor)).toBe(REC[colorway]);
      // The aura follows the voice while recording.
      const aura = await hud.locator('.hud-aura').evaluate((n) => Number(getComputedStyle(n).opacity));
      expect(aura).toBeGreaterThan(0.05);
      await shoot(hud, `hud-${tag}-recording.png`);

      await frame({ kind: 'transcribing' }, 2);
      await hud.waitForTimeout(110);
      const mid = (await capsule.boundingBox())!;
      expect(mid.x).toBeGreaterThan(0);
      expect(mid.x + mid.width).toBeLessThan(520);
      await hud.waitForTimeout(350);
      await expect(capsule).toHaveAttribute('aria-label', 'Transcribing');
      await expect(hud.locator('.hud-inner')).toHaveCount(1);
      await expect(hud.locator('.hud-shim')).toHaveText('Transcribing');
      const t = (await capsule.boundingBox())!;
      if (place.kind === 'caret') expect(flipped ? t.x + t.width : t.x).toBeCloseTo(flipped ? 492 : 28, 0);
      // The aura has faded out.
      expect(await hud.locator('.hud-aura').evaluate((n) => Number(getComputedStyle(n).opacity))).toBeLessThan(0.01);
      await shoot(hud, `hud-${tag}-transcribing.png`);

      await frame({ kind: 'inserting' }, 3);
      await hud.waitForTimeout(350);
      await expect(capsule).toHaveAttribute('aria-label', 'Inserting');
      const anchorOpacity = await hud.locator('.hud-anchor').evaluate((n) => Number(getComputedStyle(n).opacity));
      if (place.kind === 'bottom') {
        await expect(capsule).toContainText('Inserting');
        expect(anchorOpacity).toBeGreaterThan(0.99);
      } else {
        // The bubble has folded into the cursor.
        expect(anchorOpacity).toBeLessThan(0.01);
      }

      await frame({ kind: 'done', words: 23, saved: false }, 4);
      await hud.waitForTimeout(700);
      if (place.kind === 'bottom') {
        await expect(capsule).toContainText('Inserted · 23 words');
        expect(await hud.locator('.hud-chip').evaluate((n) => Number(getComputedStyle(n).opacity))).toBe(0);
        const d = (await capsule.boundingBox())!;
        expect(d.x + d.width / 2).toBeCloseTo(260, 0);
        expect(d.y + d.height).toBeCloseTo(68, 0);
        const checkOffset = await hud.locator('.hud-check path').evaluate((n) => n.getAttribute('stroke-dashoffset'));
        expect(Number(checkOffset)).toBeCloseTo(0, 2);
      } else {
        const chip = hud.locator('.hud-chip');
        await expect(chip).toHaveText('23 words');
        const c = (await chip.boundingBox())!;
        expect(c.height).toBeCloseTo(22, 0);
        expect(c.y + c.height / 2).toBeCloseTo(48, 0);
        expect(flipped ? c.x + c.width : c.x).toBeCloseTo(flipped ? 492 : 28, 0);
        expect(await chip.evaluate((n) => getComputedStyle(n).backgroundColor)).toBe(SURFACE[colorway].light);
        expect(Number(await chip.evaluate((n) => getComputedStyle(n).opacity))).toBeGreaterThan(0.99);
        expect(Number(await hud.locator('.hud-chip path').evaluate((n) => n.getAttribute('stroke-dashoffset')))).toBeCloseTo(0, 2);
      }
      await shoot(hud, `hud-${tag}-done.png`);

      await send('hud:view', null);
      await hud.waitForTimeout(350);
      await expect(capsule).toHaveClass(/is-hidden/);
      await expect(capsule).toBeEmpty();
      await expect(hud.locator('.hud-chip')).toBeEmpty();
    });
  }
}

test('a system in dark mode darkens ink and paper, and a bad accent value falls back', async () => {
  const hud = hudPageHandle;
  const capsule = hud.locator('.hud-capsule');
  for (const colorway of ['ink', 'paper'] as const) {
    await send('hud:view', { kind: 'cancelled', seq: colorway === 'ink' ? 1 : 2, placement: { kind: 'bottom' }, style: { colorway, accent: '#3366FF', systemDark: true } });
    await hud.waitForTimeout(450);
    expect(await capsule.evaluate((n) => getComputedStyle(n).backgroundColor)).toBe(SURFACE[colorway].dark);
  }
  await send('hud:view', { kind: 'recording', elapsedSeconds: 1, seq: 3, placement: { kind: 'bottom' }, style: { colorway: 'accent', accent: 'red;x', systemDark: false } });
  await hud.waitForTimeout(450);
  expect(await hud.locator('.hud-dot').evaluate((n) => getComputedStyle(n).backgroundColor)).toBe('rgb(242, 169, 59)');
  await shoot(hud, 'hud-bottom-accent-default.png');
});

test('an error beside the cursor unfolds the bubble again', async () => {
  const hud = hudPageHandle;
  const caret = { kind: 'caret', flipped: false } as const;
  const style = { colorway: 'ink', accent: '#F2A93B', systemDark: false };
  await send('hud:view', { kind: 'transcribing', seq: 1, placement: caret, style });
  await hud.waitForTimeout(400);
  await send('hud:view', { kind: 'inserting', seq: 2, placement: caret, style });
  await hud.waitForTimeout(350);
  expect(await hud.locator('.hud-anchor').evaluate((n) => Number(getComputedStyle(n).opacity))).toBeLessThan(0.01);
  await send('hud:view', { kind: 'error', seq: 3, placement: caret, style, error: { kind: 'offline', message: 'Could not reach Deepgram.', fix: 'retry' } });
  await hud.waitForTimeout(450);
  const capsule = hud.locator('.hud-capsule');
  await expect(capsule).toContainText('No connection');
  const box = (await capsule.boundingBox())!;
  expect(box.x).toBeCloseTo(28, 0);
  expect(box.height).toBeCloseTo(30, 0);
  await expect(hud.locator('.hud-btn')).toBeVisible();
  expect((await hud.locator('.hud-btn').boundingBox())!.height).toBeCloseTo(22, 0);
  expect((await hud.locator('.hud-x').boundingBox())!.width).toBeCloseTo(20, 0);
  await shoot(hud, 'hud-caret-error.png');
});

test('reduce motion: no scale, bloom or aura, still dots, no shimmer, check fully drawn', async () => {
  const hud = hudPageHandle;
  await hud.emulateMedia({ reducedMotion: 'reduce' });
  const place = { kind: 'caret', flipped: false } as const;
  const style = { colorway: 'ink', accent: '#F2A93B', systemDark: false };
  await send('hud:view', { kind: 'recording', elapsedSeconds: 1, seq: 1, placement: place, style });
  await send('hud:level', 0.3);
  await hud.waitForTimeout(100);
  expect(await hud.locator('.hud-anchor').evaluate((n) => getComputedStyle(n).transform)).toBe('none');
  const halo = await hud.locator('.hud-ring, .hud-aura, .hud-glow').evaluateAll((nodes) => nodes.map((n) => Number(getComputedStyle(n).opacity)));
  expect(Math.max(...halo)).toBe(0);
  await send('hud:view', { kind: 'transcribing', seq: 2, placement: place, style });
  await hud.waitForTimeout(60);
  // Instant swap: one row, no cross-fade.
  await expect(hud.locator('.hud-inner')).toHaveCount(1);
  await expect(hud.locator('.hud-shim')).toHaveClass(/is-still/);
  const cx = await hud.locator('.hud-dots-mark circle').evaluateAll((nodes) => nodes.map((n) => n.getAttribute('cx')));
  await hud.waitForTimeout(200);
  expect(await hud.locator('.hud-dots-mark circle').evaluateAll((nodes) => nodes.map((n) => n.getAttribute('cx')))).toEqual(cx);
  await send('hud:view', { kind: 'done', words: 5, saved: true, seq: 3, placement: place, style });
  await hud.waitForTimeout(200);
  await expect(hud.locator('.hud-chip')).toHaveText('Copied · 5 words');
  expect(Number(await hud.locator('.hud-chip path').evaluate((n) => n.getAttribute('stroke-dashoffset')))).toBeCloseTo(0, 2);
  expect(await hud.locator('.hud-chip').evaluate((n) => getComputedStyle(n).transform)).toBe('none');
});

