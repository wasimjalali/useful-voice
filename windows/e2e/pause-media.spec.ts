import { expect, test, type Page } from '@playwright/test';
import { seedUserData } from './fixtures.js';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { collect, hook, launch, out, remove, saveSettings, setKey, type Running } from './harness.js';

// "Pause media while dictating" on the built app, with a scripted player in place of the
// Windows media controls (`__uv.setMedia`, `mediaState`, `mediaCalls`; installed under
// `--e2e` only, so nothing real is ever paused). Real recordings from the fake microphone.

const SECOND = 1000;
const PLAYER = { Spotify: 'Playing', Edge: 'Playing', Podcast: 'Paused' } as const;

let run: Running | null = null;

test.afterEach(async () => {
  const current = run;
  run = null;
  if (!current) return;
  try {
    await current.stop();
  } finally {
    await remove(current.userData);
  }
});

async function start(name: string): Promise<Running> {
  const userData = await seedUserData({ emptyHistory: true });
  run = await launch(name, userData);
  await collect(run.win);
  await setKey(run.win, 'valid-e2e-key');
  await hook(run.app, 'setMedia', PLAYER);
  return run;
}

const startButton = (win: Page) => win.getByRole('button', { name: 'Start dictating' });
const stopButton = (win: Page) => win.getByRole('button', { name: 'Stop and transcribe' });

const media = (r: Running) => hook(r.app, 'mediaState');
const calls = (r: Running) => hook(r.app, 'mediaCalls');

test('what is playing pauses when the recording starts and plays again the moment it stops', async () => {
  const r = await start('media-stop');
  await startButton(r.win).click();
  await expect(stopButton(r.win)).toBeVisible({ timeout: 15 * SECOND });
  // Only what was Playing is paused; the podcast the person had paused is untouched.
  await expect.poll(() => media(r)).toEqual({ Spotify: 'Paused', Edge: 'Paused', Podcast: 'Paused' });

  await r.win.waitForTimeout(1.5 * SECOND);
  await stopButton(r.win).click();
  await expect.poll(() => media(r), { timeout: 10 * SECOND }).toEqual({ Spotify: 'Playing', Edge: 'Playing', Podcast: 'Paused' });
  // One pause and one resume of exactly the two it paused: never the podcast.
  expect(await calls(r)).toEqual(['list', 'pause:Spotify,Edge', 'resume:Spotify,Edge']);
  await expect(r.win.locator('.dock .dock-inner:not(.is-leaving) .dock-status')).toContainText('Saved and copied', { timeout: 20 * SECOND });
});

test('Esc during the recording plays it again', async () => {
  const r = await start('media-cancel');
  await startButton(r.win).click();
  await expect(stopButton(r.win)).toBeVisible({ timeout: 15 * SECOND });
  await expect.poll(() => media(r)).toMatchObject({ Spotify: 'Paused' });
  await hook(r.app, 'cancel');
  await expect.poll(() => media(r), { timeout: 10 * SECOND }).toEqual({ Spotify: 'Playing', Edge: 'Playing', Podcast: 'Paused' });
  expect(await calls(r)).toEqual(['list', 'pause:Spotify,Edge', 'resume:Spotify,Edge']);
});

test('a session the person scrubbed during the dictation is left paused, the other plays', async () => {
  const r = await start('media-scrub');
  await startButton(r.win).click();
  await expect(stopButton(r.win)).toBeVisible({ timeout: 15 * SECOND });
  await expect.poll(() => media(r)).toMatchObject({ Spotify: 'Paused', Edge: 'Paused' });
  await hook(r.app, 'scrubMedia', { id: 'Edge', byMs: 60_000 });
  await r.win.waitForTimeout(1 * SECOND);
  await stopButton(r.win).click();
  await expect.poll(() => media(r), { timeout: 10 * SECOND }).toEqual({ Spotify: 'Playing', Edge: 'Paused', Podcast: 'Paused' });
});

test('a microphone that will not open still leaves the media playing', async () => {
  const r = await start('media-mic-fail');
  await hook(r.app, 'failNextRecorderStart');
  await startButton(r.win).click();
  await expect(r.win.locator('.dock.is-warn')).toBeVisible({ timeout: 15 * SECOND });
  await expect.poll(() => media(r), { timeout: 10 * SECOND }).toEqual({ Spotify: 'Playing', Edge: 'Playing', Podcast: 'Paused' });
});

test('nothing is paused when the setting is off', async () => {
  const r = await start('media-off');
  await saveSettings(r.win, { pauseMediaWhileDictating: false });
  await startButton(r.win).click();
  await expect(stopButton(r.win)).toBeVisible({ timeout: 15 * SECOND });
  await r.win.waitForTimeout(1 * SECOND);
  expect(await media(r)).toEqual(PLAYER);
  await stopButton(r.win).click();
  await expect(r.win.locator('.dock .dock-inner:not(.is-leaving) .dock-status')).toContainText('Saved and copied', { timeout: 20 * SECOND });
  expect(await calls(r)).toEqual([]);
});

test('Settings has the toggle in General, on by default', async () => {
  const r = await start('media-settings');
  await r.win.locator('.rail-item', { hasText: 'Settings' }).click();
  const toggle = r.win.getByRole('switch', { name: 'Pause media while dictating' });
  await expect(toggle).toBeVisible();
  await expect(toggle).toHaveAttribute('aria-checked', 'true');
  // The row in both themes, for the record.
  for (const appearance of ['light', 'dark'] as const) {
    await saveSettings(r.win, { appearance });
    await r.win.waitForTimeout(400);
    await r.win.screenshot({ path: path.join(out, `settings-pause-media-${appearance}.png`) });
  }
  await toggle.click();
  await expect(toggle).toHaveAttribute('aria-checked', 'false');
  const saved = (await r.win.evaluate(() => (window as unknown as { usefulVoice: { getSettings(): Promise<{ pauseMediaWhileDictating: boolean }> } }).usefulVoice.getSettings())).pauseMediaWhileDictating;
  expect(saved).toBe(false);
});

/** Quits the app by `trigger`, waits for the process to end, and returns the e2e.log it left. */
async function endApp(r: Running, trigger: () => Promise<unknown>): Promise<string[]> {
  const exited = new Promise<void>((resolve) => r.app.process().once('exit', () => resolve()));
  await trigger().catch(() => undefined);
  await Promise.race([exited, new Promise((_, reject) => setTimeout(() => reject(new Error('the app did not exit')), 30 * SECOND))]);
  const text = await fs.readFile(path.join(r.userData, 'e2e.log'), 'utf8');
  // The app is gone: only its folder is left to remove.
  run = null;
  await remove(r.userData);
  return text.split('\n').filter((line) => /media |quit: exiting/.test(line));
}

const entries = (lines: string[]): string[] => lines.map((line) => line.replace(/^\S+ /, ''));

test('a logoff or shutdown (session-end) plays the media again before the app exits', async () => {
  const r = await start('media-session-end');
  await startButton(r.win).click();
  await expect(stopButton(r.win)).toBeVisible({ timeout: 15 * SECOND });
  await expect.poll(() => media(r)).toMatchObject({ Spotify: 'Paused', Edge: 'Paused' });
  const lines = entries(await endApp(r, () => hook(r.app, 'sessionEnd')));
  expect(lines).toEqual(['media list', 'media pause:Spotify,Edge', 'media resume:Spotify,Edge', 'quit: exiting']);
});

test('an app.quit() from anywhere plays the media again before the app exits', async () => {
  const r = await start('media-app-quit');
  await startButton(r.win).click();
  await expect(stopButton(r.win)).toBeVisible({ timeout: 15 * SECOND });
  await expect.poll(() => media(r)).toMatchObject({ Spotify: 'Paused', Edge: 'Paused' });
  const lines = entries(await endApp(r, () => hook(r.app, 'appQuit')));
  expect(lines).toEqual(['media list', 'media pause:Spotify,Edge', 'media resume:Spotify,Edge', 'quit: exiting']);
});
