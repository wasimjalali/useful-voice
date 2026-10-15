import { expect, test, type Page } from '@playwright/test';
import { E2E_TRANSCRIPT_FIXTURE, seedUserData } from './fixtures.js';
import {
  clipboardText,
  collect,
  historyWhere,
  hook,
  launch,
  log,
  remove,
  saveSettings,
  sendToMain,
  setKey,
  trayItem,
  useScriptedMicrophone,
  writeClipboard,
  type Running,
} from './harness.js';

// The dictation pipeline end to end on the built app: a real recording from Chromium's fake
// microphone, the real key check against the e2e Deepgram stub, the real delivery, history and
// tray state, and what the Stream's dock shows. Covers the launch items that are about how a
// dictation behaves rather than how a page looks:
//
//   WAS-19  window and retry dictations are saved and copied, never pasted
//   WAS-20  typed errors with their fix, and the "Copied. Press Ctrl+V" notice's life
//   WAS-26  elapsed time, level and the stop countdown reach the window
//   WAS-27  the silence and maximum-length limits stop a recording
//   WAS-54  the tray's Copy last transcript, Delete all asking first, a dictation in the
//           app's own window not pasting and not being filed under an app
//
// Nothing here presses the hotkey to completion: that would paste into whatever is in
// front of the machine running the suite.

const SECOND = 1000;

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

async function start(name: string, options: { emptyHistory?: boolean; key?: string | null } = {}): Promise<Running> {
  const userData = await seedUserData({ emptyHistory: options.emptyHistory });
  run = await launch(name, userData);
  await collect(run.win);
  if (options.key !== null) await setKey(run.win, options.key ?? 'valid-e2e-key');
  return run;
}

const startButton = (win: Page) => win.getByRole('button', { name: 'Start dictating' });
const stopButton = (win: Page) => win.getByRole('button', { name: 'Stop and transcribe' });
const dockFix = (win: Page) => win.locator('.dock').getByRole('button', { name: 'Open settings' });
const dockStatus = (win: Page) => win.locator('.dock .dock-inner:not(.is-leaving) .dock-status');

/** One whole dictation from the dock: record for a moment, stop, wait for the outcome. */
async function dictateFromDock(win: Page, seconds = 1.5): Promise<void> {
  await startButton(win).click();
  await expect(stopButton(win)).toBeVisible({ timeout: 15 * SECOND });
  await win.waitForTimeout(seconds * SECOND);
  await stopButton(win).click();
}

/** Starts one and waits for the dock to settle on an error row. */
async function dictateIntoError(win: Page): Promise<void> {
  await dictateFromDock(win);
  await expect(win.locator('.dock.is-warn, .dock.is-bad')).toBeVisible({ timeout: 20 * SECOND });
}

test('a dictation started in the app saves and copies, is never pasted, and the tray can copy it', async () => {
  const { app, win, userData } = await start('window-source', { emptyHistory: true });

  // Nothing dictated yet: Copy last transcript is in the menu but has nothing to copy.
  expect(await trayItem(app, 'Copy last transcript')).toMatchObject({ enabled: false });
  expect(await trayItem(app, 'Retry last recording')).toMatchObject({ enabled: false });
  await writeClipboard(app, 'the clipboard before');

  await dictateFromDock(win);
  await expect(dockStatus(win)).toContainText('Saved and copied', { timeout: 20 * SECOND });

  // A window dictation: it said so at the start, it never took the paste path, and it
  // reported the saved-and-copied result, which only copy mode produces.
  expect(await hook(app, 'lastSource')).toBe('window');
  const events = await log(win);
  expect(events.outcomes).toEqual([{ kind: 'delivered', words: 4, result: 'copied' }]);
  const delivering = events.states.filter((state) => state.state === 'delivering');
  expect(delivering.length).toBeGreaterThan(0);
  expect(delivering.every((state) => state.delivery === 'copy')).toBe(true);
  expect(events.states.some((state) => state.state === 'error')).toBe(false);

  // On the clipboard, and in history without an app: it is not filed under "Unknown" or
  // under Useful Voice itself.
  expect(await clipboardText(app)).toBe(E2E_TRANSCRIPT_FIXTURE);
  const history = await historyWhere(userData, (rows) => rows.length === 1);
  expect(history).toHaveLength(1);
  expect(history[0]?.text).toBe(E2E_TRANSCRIPT_FIXTURE);
  expect(history[0]?.appName).toBe('');
  await expect(win.locator('.bubble')).toHaveCount(1);
  await expect(win.locator('.bubble .bubble-meta')).toContainText('saved and copied');
  await expect(win.locator('.bubble .bubble-meta')).not.toContainText(/Unknown|into /);

  // The tray can copy it although nothing failed. Retry still has nothing to retry.
  expect(await trayItem(app, 'Copy last transcript')).toMatchObject({ enabled: true });
  expect(await trayItem(app, 'Retry last recording')).toMatchObject({ enabled: false });
  await writeClipboard(app, 'something else');
  await win.evaluate(() => (window as unknown as { usefulVoice: { copyLastTranscript(): Promise<void> } }).usefulVoice.copyLastTranscript());
  expect(await clipboardText(app)).toBe(E2E_TRANSCRIPT_FIXTURE);
});

test('Delete all dictations asks first, Cancel and Esc keep everything, Delete empties the tray item too', async () => {
  const { app, win, userData } = await start('delete-all');
  await expect(win.locator('.bubble')).toHaveCount(6);
  expect(await trayItem(app, 'Copy last transcript')).toMatchObject({ enabled: true });

  const dialog = win.getByRole('alertdialog');
  const open = async (): Promise<void> => {
    await win.getByRole('button', { name: 'Delete all dictations' }).click();
    await expect(dialog).toBeVisible();
    await expect(dialog).toContainText('6 dictations');
  };

  // The click alone removes nothing.
  await open();
  expect(await historyWhere(userData, () => true)).toHaveLength(6);
  await expect(win.locator('.bubble')).toHaveCount(6);

  // Cancel.
  await dialog.getByRole('button', { name: 'Cancel' }).click();
  await expect(dialog).toHaveCount(0);
  await expect(win.locator('.bubble')).toHaveCount(6);

  // Esc.
  await open();
  await win.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);
  await expect(win.locator('.bubble')).toHaveCount(6);
  expect(await historyWhere(userData, () => true)).toHaveLength(6);

  // Confirm.
  await open();
  await dialog.getByRole('button', { name: /^Delete 6 dictations/ }).click();
  await expect(dialog).toHaveCount(0);
  await expect(win.locator('.bubble')).toHaveCount(0);
  expect(await historyWhere(userData, (rows) => rows.length === 0)).toHaveLength(0);
  expect(await trayItem(app, 'Copy last transcript')).toMatchObject({ enabled: false });
});

test('a failed upload keeps the audio, offers Retry, and the retry is saved and copied', async () => {
  const { app, win, userData } = await start('retry', { emptyHistory: true, key: 'offline-e2e-key' });

  await dictateIntoError(win);
  // A dead network: typed as offline, with Retry as the fix, in the dock and in the tray.
  const events = await log(win);
  const failure = events.states.find((state) => state.state === 'error');
  expect(failure?.error).toMatchObject({ kind: 'offline', fix: 'retry' });
  await expect(dockStatus(win)).toContainText('Could not reach Deepgram');
  const retry = win.getByRole('button', { name: 'Retry last recording' });
  await expect(retry).toBeVisible();
  expect(await trayItem(app, 'Retry last recording')).toMatchObject({ enabled: true });
  // Nothing was delivered, so there is nothing to copy yet.
  expect(await trayItem(app, 'Copy last transcript')).toMatchObject({ enabled: false });
  expect(await historyWhere(userData, () => true)).toHaveLength(0);

  // The network is back (a good key now). Retry re-sends the kept audio.
  await setKey(win, 'valid-e2e-key');
  await writeClipboard(app, 'the clipboard before');
  await retry.click();
  await expect(dockStatus(win)).toContainText('Saved and copied', { timeout: 20 * SECOND });

  // A retry is always saved and copied: a hotkey was never pressed for it, and its window
  // may be long gone.
  const after = await log(win);
  expect(after.outcomes).toEqual([{ kind: 'delivered', words: 4, result: 'copied' }]);
  expect(await clipboardText(app)).toBe(E2E_TRANSCRIPT_FIXTURE);
  const history = await historyWhere(userData, (rows) => rows.length === 1);
  expect(history[0]).toMatchObject({ text: E2E_TRANSCRIPT_FIXTURE, appName: '' });
  expect(await trayItem(app, 'Retry last recording')).toMatchObject({ enabled: false });
  expect(await trayItem(app, 'Copy last transcript')).toMatchObject({ enabled: true });
});

test('each error kind says what happened and offers its own fix, and the next dictation clears it', async () => {
  const { app, win } = await start('error-kinds', { emptyHistory: true, key: 'bad-e2e-key' });

  // A key Deepgram refuses: Settings is the fix.
  await dictateIntoError(win);
  let events = await log(win);
  expect(events.states.filter((state) => state.state === 'error').at(-1)?.error).toMatchObject({ kind: 'keyRejected', fix: 'openEngineSettings' });
  await expect(dockStatus(win)).toContainText('rejected your API key');
  await expect(dockFix(win)).toBeVisible();

  // No key at all: the same fix.
  await win.evaluate(() => (window as unknown as { usefulVoice: { clearApiKey(): Promise<void> } }).usefulVoice.clearApiKey());
  await dictateIntoError(win);
  events = await log(win);
  expect(events.states.filter((state) => state.state === 'error').at(-1)?.error).toMatchObject({ kind: 'noProvider', fix: 'openEngineSettings' });
  await expect(dockFix(win)).toBeVisible();

  // A microphone that will not open: the fix is the Windows microphone settings. The button
  // is shown but not pressed, since it would open the real Settings app.
  await hook(app, 'failNextRecorderStart');
  await startButton(win).click();
  await expect(win.locator('.dock.is-warn')).toBeVisible({ timeout: 15 * SECOND });
  events = await log(win);
  expect(events.states.filter((state) => state.state === 'error').at(-1)?.error).toMatchObject({ kind: 'micUnavailable', fix: 'openMicrophoneSettings' });
  await expect(dockStatus(win)).toContainText('Microphone access is blocked');
  await expect(dockFix(win)).toBeVisible();

  // The next dictation clears the old error at once, before anything new has happened.
  await setKey(win, 'valid-e2e-key');
  await startButton(win).click();
  await expect(stopButton(win)).toBeVisible({ timeout: 15 * SECOND });
  await expect(win.locator('.dock.is-warn, .dock.is-bad')).toHaveCount(0);
  await expect(win.locator('.dock-error')).toHaveCount(0);
  await win.waitForTimeout(1.5 * SECOND);
  await stopButton(win).click();
  await expect(dockStatus(win)).toContainText('Saved and copied', { timeout: 20 * SECOND });
});

test('the Open settings fix of an engine error opens Settings, and the first section brings the dock back', async () => {
  const { win } = await start('open-settings', { emptyHistory: true, key: 'bad-e2e-key' });
  await dictateIntoError(win);
  await expect(dockStatus(win)).toContainText('rejected your API key');
  await dockFix(win).click();
  const current = win.locator('.rail-item[aria-current="page"]');
  await expect(current).toHaveCount(1);
  await expect(current).toContainText('Settings');
  await expect(win.locator('.dock')).toHaveCount(0);

  // The first rail item is the dictation page. A failure here dumps the page, so a run on a
  // machine nobody can look at still says what was on screen.
  const rail = win.locator('.rail-item');
  try {
    await rail.first().click({ timeout: 10 * SECOND });
    await win.waitForSelector('.dock', { timeout: 10 * SECOND });
  } catch (error) {
    const dump = await win.evaluate(() => `${location.href}\n${document.body.innerText.slice(0, 1500)}\nrail items: ${document.querySelectorAll('.rail-item').length}`);
    throw new Error(`${(error as Error).message}\n--- page ---\n${dump}`);
  }
  await expect(win.locator('.rail-item[aria-current="page"]')).not.toContainText('Settings');
});

test('"Copied. Press Ctrl+V to paste" outlasts the done line and ends on the next dictation, the x, or 8 s', async () => {
  const { app, win } = await start('copied-notice');
  const notice = win.locator('.dock .dock-inner:not(.is-leaving) .dock-status', { hasText: 'Copied.' });
  // What main sends when a hotkey paste could not be confirmed: the outcome, then idle.
  // (A real hotkey dictation would paste into the machine running the suite.)
  const copiedNotPasted = async (): Promise<void> => {
    await sendToMain(app, 'dictation:outcome', { kind: 'delivered', words: 9, result: 'copiedNotPasted', appName: 'Notepad' });
    await sendToMain(app, 'dictation:state', { state: 'idle', message: 'Copied to your clipboard. Press Ctrl+V to paste it.' });
  };

  // It survives the idle that follows and the 4 s an ordinary done line gets.
  await copiedNotPasted();
  await expect(notice).toBeVisible();
  await expect(win.getByRole('button', { name: 'Copy last transcript' })).toBeVisible();
  await win.waitForTimeout(5 * SECOND);
  await expect(notice).toBeVisible();
  // ... and clears on its own at 8 s.
  await expect(notice).toHaveCount(0, { timeout: 5 * SECOND });
  await expect(dockStatus(win)).toContainText('Ready');

  // The x.
  await copiedNotPasted();
  await expect(notice).toBeVisible();
  await win.getByRole('button', { name: 'Dismiss' }).click();
  await expect(notice).toHaveCount(0);
  await expect(dockStatus(win)).toContainText('Ready');

  // The next dictation.
  await copiedNotPasted();
  await expect(notice).toBeVisible();
  await setKey(win, 'valid-e2e-key');
  await startButton(win).click();
  await expect(stopButton(win)).toBeVisible({ timeout: 15 * SECOND });
  await expect(notice).toHaveCount(0);
  await win.waitForTimeout(1.5 * SECOND);
  await stopButton(win).click();
  await expect(dockStatus(win)).toContainText('Saved and copied', { timeout: 20 * SECOND });
});

test('the maximum length stops the recording, with the countdown and live numbers in the window', async () => {
  test.setTimeout(120 * SECOND);
  const { win } = await start('max-length', { emptyHistory: true });
  // The shortest the app allows. Silence is left at its longest so only the clock can stop it.
  await saveSettings(win, { maxRecordingSeconds: 30, silenceTimeoutSeconds: 120 });

  await startButton(win).click();
  await expect(stopButton(win)).toBeVisible({ timeout: 15 * SECOND });
  // The timer runs on its own.
  await expect(win.locator('.dock-time')).toHaveText(/^0:0[2-9]$/, { timeout: 15 * SECOND });
  await expect(win.locator('.dock-stops')).toHaveText('');

  // Five seconds before the end the countdown appears, and it names the reason.
  await expect(win.locator('.dock-stops b')).toHaveText(/^Stops in [1-5] s$/, { timeout: 40 * SECOND });
  await expect(win.locator('.dock-stops')).toContainText('Maximum length');

  // The recording ends by itself and what was said is delivered.
  await expect(dockStatus(win)).toContainText('Saved and copied', { timeout: 30 * SECOND });
  const events = await log(win);
  expect(events.outcomes).toEqual([{ kind: 'delivered', words: 4, result: 'copied' }]);

  // The numbers the window was given: elapsed time climbing to the cap, a level in range,
  // the countdown only in the last five seconds and counting down.
  const { telemetry } = events;
  expect(telemetry.length).toBeGreaterThan(30);
  const elapsed = telemetry.map((tick) => tick.elapsedSeconds);
  expect([...elapsed].sort((a, b) => a - b)).toEqual(elapsed);
  expect(Math.max(...elapsed)).toBeGreaterThanOrEqual(29);
  expect(Math.max(...elapsed)).toBeLessThan(33);
  for (const tick of telemetry) {
    expect(tick.level).toBeGreaterThanOrEqual(0);
    expect(tick.level).toBeLessThanOrEqual(1);
  }
  expect(Math.max(...telemetry.map((tick) => tick.level))).toBeGreaterThan(0);
  expect(telemetry.some((tick) => tick.silenceRemaining !== undefined)).toBe(false);
  const counts = telemetry.flatMap((tick) => (tick.maxRemaining === undefined ? [] : [tick.maxRemaining]));
  expect(counts.length).toBeGreaterThan(0);
  expect(Math.max(...counts)).toBeLessThanOrEqual(5);
  expect([...counts].sort((a, b) => b - a)).toEqual(counts);
  for (const tick of telemetry) {
    if (tick.elapsedSeconds < 24) expect(tick.maxRemaining).toBeUndefined();
  }
});

test('silence stops the recording after the chosen time, with the countdown, and keeps what was said', async () => {
  test.setTimeout(120 * SECOND);
  const { app, win, userData } = await start('silence', { emptyHistory: true });
  // The shortest silence limit the app allows. A one second tone, then nothing.
  await saveSettings(win, { silenceTimeoutSeconds: 15, maxRecordingSeconds: 600 });
  await useScriptedMicrophone(app, userData, 1000);

  const startedAt = Date.now();
  await startButton(win).click();
  await expect(stopButton(win)).toBeVisible({ timeout: 15 * SECOND });
  const recordingFrom = Date.now();

  // Before the last five seconds nothing is counting down.
  await win.waitForTimeout(5 * SECOND);
  await expect(win.locator('.dock-stops')).toHaveText('');

  await expect(win.locator('.dock-stops b')).toHaveText(/^Stops in [1-5] s$/, { timeout: 20 * SECOND });
  await expect(win.locator('.dock-stops')).toContainText('No speech for a while');

  // It stops by itself, long before the 10 minute cap, and delivers the second of speech.
  await expect(dockStatus(win)).toContainText('Saved and copied', { timeout: 20 * SECOND });
  const recorded = (Date.now() - recordingFrom) / SECOND;
  expect(recorded).toBeLessThan(45);
  expect(Date.now() - startedAt).toBeGreaterThan(14 * SECOND);

  const events = await log(win);
  expect(events.outcomes).toEqual([{ kind: 'delivered', words: 4, result: 'copied' }]);
  const { telemetry } = events;
  const counts = telemetry.flatMap((tick) => (tick.silenceRemaining === undefined ? [] : [tick.silenceRemaining]));
  expect(counts.length).toBeGreaterThan(0);
  expect(Math.max(...counts)).toBeLessThanOrEqual(5);
  expect([...counts].sort((a, b) => b - a)).toEqual(counts);
  expect(telemetry.some((tick) => tick.maxRemaining !== undefined)).toBe(false);
  // The tone was heard (a level above zero) and the quiet after it was too (a level of zero).
  expect(Math.max(...telemetry.map((tick) => tick.level))).toBeGreaterThan(0.05);
  expect(telemetry.at(-1)?.level).toBeLessThan(0.02);
});
