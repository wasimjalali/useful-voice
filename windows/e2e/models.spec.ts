import { expect, test, type Page } from '@playwright/test';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { seedUserData } from './fixtures.js';
import { collect, historyWhere, launch, log, out, remove, saveSettings, sendToMain, type Running } from './harness.js';

// Settings > Models and the model-aware dictation pipeline, end to end on the built app.
// Every provider (Deepgram, ElevenLabs, Gemini, Anthropic) is answered by the e2e stub in main:
// a key starting `valid` works, `bad` is refused, `offline` fails like a dead network. The
// formatter stubs answer "<the dictation> (formatted by <provider>)", so what reaches the
// history proves which model ran and that its text is what was delivered.
//
//  1. pick models: a cloud model without its key can't be picked and sends you to its key row,
//     a refused key says so, a good key unlocks the row, the choice is saved
//  2. a model with no key fails a dictation with the fix, and adding the key makes it work
//  3. AI formatting: off delivers the plain text, on delivers the formatter's text, the history
//     keeps what was heard, a refused key delivers the plain text
//  4. each voice model reaches its own provider, and nothing falls back to another
//
// Nothing here presses the hotkey to completion: that would paste into whatever is in front of
// the machine running the suite.

const SECOND = 1000;
const shots = path.join(out, 'screens');

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
  return run;
}

type Provider = 'deepgram' | 'elevenlabs' | 'gemini' | 'anthropic';

/** Saves a key in main the way Settings does. */
async function setKey(win: Page, provider: Provider, key: string): Promise<void> {
  const result = await win.evaluate(
    ({ provider: p, key: k }) =>
      (window as unknown as { usefulVoice: { setProviderKey(p: string, k: string): Promise<{ ok: boolean; error?: string }> } }).usefulVoice.setProviderKey(p, k),
    { provider, key },
  );
  if (!result.ok) throw new Error(`the ${provider} key was not saved: ${result.error ?? 'no reason'}`);
}

function currentSettings(win: Page): Promise<{ voiceModelId: string; formatterId: string | null; keys: Record<Provider, boolean> }> {
  return win.evaluate(() => (window as unknown as { usefulVoice: { getSettings(): Promise<never> } }).usefulVoice.getSettings());
}

/** Saves settings through the bridge, then reloads so the window shows them (the page does this itself). */
async function choose(win: Page, patch: Record<string, unknown>): Promise<void> {
  await saveSettings(win, patch);
  await win.reload();
  await win.waitForSelector('.dock');
  await collect(win);
}

async function openSettings(win: Page): Promise<void> {
  await win.locator('.rail-item', { hasText: 'Settings' }).click();
  await expect(win.locator('#settings-models')).toBeVisible();
}

const voiceList = (win: Page) => win.getByRole('radiogroup', { name: 'Voice model' });
const formatList = (win: Page) => win.getByRole('radiogroup', { name: 'AI formatting' });
const keyRow = (win: Page, provider: Provider) => win.locator(`[data-provider="${provider}"]`);

/** Pastes a key into the row's field and saves it. */
async function saveKeyInRow(win: Page, provider: Provider, label: string, key: string): Promise<void> {
  const field = win.getByLabel(`${label} API key`);
  await field.fill(key);
  await keyRow(win, provider).getByRole('button', { name: 'Save key' }).click();
}

const dockStatus = (win: Page) => win.locator('.dock .dock-inner:not(.is-leaving) .dock-status');
const startButton = (win: Page) => win.getByRole('button', { name: 'Start dictating' });
const stopButton = (win: Page) => win.getByRole('button', { name: 'Stop and transcribe' });

/** One whole dictation from the dock. Waits for the outcome or the error. */
async function dictate(win: Page): Promise<void> {
  const before = (await log(win)).outcomes.length + (await log(win)).states.filter((state) => state.state === 'error').length;
  await win.locator('.rail-item').first().click();
  await startButton(win).click();
  await expect(stopButton(win)).toBeVisible({ timeout: 15 * SECOND });
  await win.waitForTimeout(1500);
  await stopButton(win).click();
  await expect
    .poll(async () => {
      const events = await log(win);
      return events.outcomes.length + events.states.filter((state) => state.state === 'error').length;
    }, { timeout: 25 * SECOND })
    .toBeGreaterThan(before);
}

interface Stored {
  text: string;
  rawText: string;
  mode: string;
}

async function lastDictation(userData: string, count: number): Promise<Stored> {
  const rows = (await historyWhere(userData, (history) => history.length >= count)) as unknown as Stored[];
  expect(rows.length).toBeGreaterThanOrEqual(count);
  return rows[0] as Stored;
}

async function shot(win: Page, name: string): Promise<void> {
  await fs.mkdir(shots, { recursive: true });
  await win.waitForTimeout(350);
  await win.screenshot({ path: path.join(shots, `${name}.png`) });
}

test('a cloud model needs its key before it can be picked, and the choice is saved', async () => {
  const { win } = await start('models-pick');
  await openSettings(win);

  // The defaults: Nova-3 and AI formatting off.
  await expect(voiceList(win).getByRole('radio', { name: /^Nova-3,/ })).toHaveAttribute('aria-checked', 'true');
  await expect(formatList(win).getByRole('radio', { name: /^Off/ })).toHaveAttribute('aria-checked', 'true');
  await shot(win, 'models-default');

  // Scribe has no key: picking it changes nothing and takes you to the key.
  const scribe = voiceList(win).getByRole('radio', { name: /^Scribe v2,/ });
  await expect(scribe).toHaveAttribute('aria-disabled', 'true');
  await expect(voiceList(win).getByRole('button', { name: 'Add key' })).toHaveCount(4);
  await scribe.click({ force: true });
  await expect(scribe).toHaveAttribute('aria-checked', 'false');
  await expect(win.getByLabel('ElevenLabs API key')).toBeFocused();
  expect((await currentSettings(win)).voiceModelId).toBe('deepgram:nova-3');

  // A refused key is saved, tested and reported; the row stays locked.
  await saveKeyInRow(win, 'elevenlabs', 'ElevenLabs', 'bad-eleven');
  await expect(keyRow(win, 'elevenlabs').getByRole('button', { name: 'Test ElevenLabs connection' })).toBeVisible();
  await keyRow(win, 'elevenlabs').getByRole('button', { name: 'Test ElevenLabs connection' }).click();
  await expect(keyRow(win, 'elevenlabs')).toContainText('ElevenLabs rejected the key.');
  expect((await currentSettings(win)).keys.elevenlabs).toBe(true);

  // Replace it with a good one: the test passes and Scribe can be picked.
  await saveKeyInRow(win, 'elevenlabs', 'ElevenLabs', 'valid-eleven');
  await keyRow(win, 'elevenlabs').getByRole('button', { name: 'Test ElevenLabs connection' }).click();
  await expect(keyRow(win, 'elevenlabs')).toContainText('The key works.');
  await expect(scribe).not.toHaveAttribute('aria-disabled', 'true');
  await scribe.click();
  await expect(scribe).toHaveAttribute('aria-checked', 'true');
  await expect(voiceList(win).getByRole('radio', { name: /^Nova-3,/ })).toHaveAttribute('aria-checked', 'false');
  expect((await currentSettings(win)).voiceModelId).toBe('elevenlabs:scribe_v2');

  // Nova-3 was the default but its key was never added, so it is locked too.
  await expect(voiceList(win).getByRole('radio', { name: /^Nova-3,/ })).toHaveAttribute('aria-disabled', 'true');
  await setKey(win, 'deepgram', 'valid-deepgram');
  await win.reload();
  await win.waitForSelector('.dock');
  await openSettings(win);

  // The keyboard picks too: arrows move between rows, Space chooses.
  await voiceList(win).getByRole('radio', { name: /^Nova-3,/ }).focus();
  await win.keyboard.press('Space');
  await expect(voiceList(win).getByRole('radio', { name: /^Nova-3,/ })).toHaveAttribute('aria-checked', 'true');
  await win.keyboard.press('ArrowDown');
  await expect(voiceList(win).getByRole('radio', { name: /^Nova-3 Medical,/ })).toBeFocused();
  await win.keyboard.press('Space');
  await expect(voiceList(win).getByRole('radio', { name: /^Nova-3 Medical,/ })).toHaveAttribute('aria-checked', 'true');
  expect((await currentSettings(win)).voiceModelId).toBe('deepgram:nova-3-medical');

  // AI formatting: the same lock, then on and off.
  const gemini = formatList(win).getByRole('radio', { name: /^Gemini 3.8 Flash,/ });
  await gemini.click({ force: true });
  await expect(win.getByLabel('Gemini API key')).toBeFocused();
  await saveKeyInRow(win, 'gemini', 'Gemini', 'valid-gemini');
  await expect(gemini).not.toHaveAttribute('aria-disabled', 'true');
  await gemini.click();
  await expect(gemini).toHaveAttribute('aria-checked', 'true');
  expect((await currentSettings(win)).formatterId).toBe('gemini:gemini-3.8-flash');
  await shot(win, 'models-picked');
  await formatList(win).getByRole('radio', { name: /^Off/ }).click();
  expect((await currentSettings(win)).formatterId).toBeNull();

  // A key can be removed again; the row locks.
  await keyRow(win, 'elevenlabs').getByRole('button', { name: 'Remove ElevenLabs key' }).click();
  await expect(scribe).toHaveAttribute('aria-disabled', 'true');
  expect((await currentSettings(win)).keys.elevenlabs).toBe(false);
});

test('a model with no key says which key to add, and adding it makes the dictation work', async () => {
  const { win } = await start('models-missing-key');
  await choose(win, { voiceModelId: 'gemini-audio:gemini-3.8-flash' });

  await dictate(win);
  const error = (await log(win)).states.filter((state) => state.state === 'error').at(-1)?.error;
  expect(error).toMatchObject({ kind: 'noProvider', fix: 'openEngineSettings', message: 'Add your Gemini key in Settings.' });
  await expect(dockStatus(win)).toContainText('Add your Gemini key in Settings.');
  await expect(win.locator('.banner')).toContainText('No Gemini key.');

  // The fix opens Models, where the row is waiting for the key.
  await win.locator('.dock').getByRole('button', { name: 'Open settings' }).click();
  await expect(win.locator('#settings-models')).toBeVisible();
  await win.getByRole('radio', { name: /^Gemini 3.8 Flash,/ }).first().click({ force: true });
  await expect(win.getByLabel('Gemini API key')).toBeFocused();
  await saveKeyInRow(win, 'gemini', 'Gemini', 'valid-gemini');
  await expect(win.locator('.banner')).toHaveCount(0);

  await dictate(win);
  const saved = await lastDictation(run!.userData, 1);
  expect(saved.text).toBe('Hello from Gemini, the voice model.');
});

test('AI formatting delivers the formatter\'s text, keeps what was heard, and never blocks a dictation', async () => {
  const { win, userData } = await start('models-formatter');
  for (const [provider, key] of [['deepgram', 'valid-deepgram'], ['gemini', 'valid-gemini'], ['anthropic', 'valid-anthropic']] as const) {
    await setKey(win, provider, key);
  }
  await win.reload();
  await win.waitForSelector('.dock');
  await collect(win);

  // Off: the plain transcript.
  await dictate(win);
  expect((await lastDictation(userData, 1)).text).toBe('Hello from Useful Voice.');

  // Gemini on: its text is what was delivered; the history keeps the raw transcript.
  await choose(win, { formatterId: 'gemini:gemini-3.8-flash' });
  await dictate(win);
  const gemini = await lastDictation(userData, 2);
  expect(gemini).toMatchObject({ text: 'Hello from Useful Voice. (formatted by Gemini)', rawText: 'Hello from Useful Voice.', mode: 'formatted' });
  await expect(dockStatus(win)).toContainText('Saved and copied');

  // Anthropic on.
  await choose(win, { formatterId: 'anthropic:claude-sonnet-5-5' });
  await dictate(win);
  expect((await lastDictation(userData, 3)).text).toBe('Hello from Useful Voice. (formatted by Anthropic)');

  // Off again.
  await choose(win, { formatterId: null });
  await dictate(win);
  expect((await lastDictation(userData, 4))).toMatchObject({ text: 'Hello from Useful Voice.', mode: 'raw' });

  // A refused formatter key: the dictation still arrives, unformatted.
  await setKey(win, 'gemini', 'bad-gemini');
  await choose(win, { formatterId: 'gemini:gemini-3.8-flash' });
  await dictate(win);
  expect((await lastDictation(userData, 5))).toMatchObject({ text: 'Hello from Useful Voice.', mode: 'raw' });
  expect((await log(win)).states.filter((state) => state.state === 'error')).toHaveLength(0);
  const diagnostics = await fs.readFile(path.join(userData, 'diagnostics.log'), 'utf8').catch(() => '');
  expect(diagnostics).not.toContain('bad-gemini');
  expect(diagnostics).not.toContain('Hello from Useful Voice');

  // A dead network to the formatter: the same.
  await setKey(win, 'gemini', 'offline-gemini');
  await dictate(win);
  expect((await lastDictation(userData, 6))).toMatchObject({ text: 'Hello from Useful Voice.', mode: 'raw' });
});

test('each voice model reaches its own provider, and the formatter works on top of it', async () => {
  const { win, userData } = await start('models-providers');
  for (const [provider, key] of [['deepgram', 'valid-deepgram'], ['elevenlabs', 'valid-eleven'], ['gemini', 'valid-gemini'], ['anthropic', 'valid-anthropic']] as const) {
    await setKey(win, provider, key);
  }
  await win.reload();
  await win.waitForSelector('.dock');
  await collect(win);

  const cases: Array<[string, string]> = [
    ['deepgram:nova-3', 'Hello from Useful Voice.'],
    ['deepgram:nova-3-medical', 'Hello from Useful Voice.'],
    ['elevenlabs:scribe_v2', 'Hello from Scribe, the ElevenLabs model.'],
    ['gemini-audio:gemini-3.8-flash', 'Hello from Gemini, the voice model.'],
  ];
  let count = 0;
  for (const [model, text] of cases) {
    await choose(win, { voiceModelId: model });
    await dictate(win);
    count += 1;
    expect((await lastDictation(userData, count)).text, model).toBe(text);
  }

  // Scribe heard it, Claude formatted it.
  await choose(win, { voiceModelId: 'elevenlabs:scribe_v2', formatterId: 'anthropic:claude-haiku-5-5' });
  await dictate(win);
  count += 1;
  expect((await lastDictation(userData, count)).text).toBe('Hello from Scribe, the ElevenLabs model. (formatted by Anthropic)');

  // The app asked each provider exactly for the model chosen: no other host was called for a voice model.
  const requests = await fs.readFile(path.join(userData, 'e2e.log'), 'utf8');
  expect(requests).toMatch(/deepgram POST .*model=nova-3-medical/);
  expect(requests).toMatch(/elevenlabs POST https:\/\/api\.elevenlabs\.io\/v1\/speech-to-text/);
  expect(requests).toMatch(/gemini POST .*gemini-3\.8-flash:generateContent/);
  expect(requests).not.toContain('key=');
});

test('Nova-3 Medical refuses a language it does not speak before anything is sent', async () => {
  const { win, userData } = await start('models-medical-german');
  await setKey(win, 'deepgram', 'valid-deepgram');
  await choose(win, { voiceModelId: 'deepgram:nova-3-medical', languagePin: 'de' });
  await dictate(win);
  const error = (await log(win)).states.filter((state) => state.state === 'error').at(-1)?.error;
  expect(error?.message).toBe('Nova-3 Medical only speaks English. Pick another voice model or switch the language to English.');
  const requests = await fs.readFile(path.join(userData, 'e2e.log'), 'utf8');
  expect(requests).not.toContain('nova-3-medical');
});

test('a local model starts its download when picked and becomes the voice model when it is ready', async () => {
  const { app, win } = await start('models-local');
  await setKey(win, 'deepgram', 'valid-deepgram');
  await win.reload();
  await win.waitForSelector('.dock');
  await openSettings(win);

  // The stub reports every Parakeet model as not downloaded: the row offers the download.
  const parakeet = voiceList(win).getByRole('radio', { name: /^Parakeet,/ });
  await expect(voiceList(win).getByRole('button', { name: 'Download Parakeet', exact: true })).toBeVisible();
  await parakeet.click();
  // Not switched yet: nothing is on this PC to dictate with.
  await expect(parakeet).toHaveAttribute('aria-checked', 'false');
  expect((await currentSettings(win)).voiceModelId).toBe('deepgram:nova-3');

  // Main reports progress, then the finished model.
  const states = (v2: unknown) => ({ v2, v3: { status: 'notDownloaded' } });
  await sendToMain(app, 'parakeet:changed', states({ status: 'downloading', progress: 0.4 }));
  const bar = voiceList(win).getByRole('progressbar', { name: 'Downloading Parakeet' });
  await expect(bar).toHaveAttribute('aria-valuenow', '40');
  await expect(voiceList(win).getByRole('button', { name: 'Cancel' })).toBeVisible();
  await sendToMain(app, 'parakeet:changed', states({ status: 'ready', sizeBytes: 482_000_000 }));
  await expect(parakeet).toHaveAttribute('aria-checked', 'true');
  await expect(voiceList(win).getByRole('button', { name: 'Delete Parakeet' })).toBeVisible();
  expect((await currentSettings(win)).voiceModelId).toBe('parakeet:v2');

  // A failed download offers a retry, and does not switch anything.
  const multilingual = voiceList(win).getByRole('radio', { name: /^Parakeet Multilingual,/ });
  await multilingual.click();
  await sendToMain(app, 'parakeet:changed', { v2: { status: 'ready', sizeBytes: 482_000_000 }, v3: { status: 'failed', message: 'offline' } });
  await expect(voiceList(win).getByRole('button', { name: 'Retry Parakeet Multilingual' })).toBeVisible();
  await expect(multilingual).toHaveAttribute('aria-checked', 'false');
  expect((await currentSettings(win)).voiceModelId).toBe('parakeet:v2');
});

test('Settings > Models in light and dark, wide and narrow (screenshots)', async () => {
  const { win } = await start('models-screens');
  await setKey(win, 'deepgram', 'valid-deepgram');
  await setKey(win, 'elevenlabs', 'valid-eleven');
  await setKey(win, 'gemini', 'valid-gemini');
  for (const appearance of ['light', 'dark'] as const) {
    await saveSettings(win, { appearance, voiceModelId: 'elevenlabs:scribe_v2', formatterId: 'gemini:gemini-3.8-flash' });
    await win.reload();
    await win.waitForSelector('.dock');
    for (const [label, width, height] of [['wide', 1280, 900], ['narrow', 420, 900]] as const) {
      await win.setViewportSize({ width, height });
      await openSettings(win);
      await win.locator('#settings-models').scrollIntoViewIfNeeded();
      await shot(win, `models-${appearance}-${label}`);
      await win.locator('#settings-keys').scrollIntoViewIfNeeded();
      await shot(win, `keys-${appearance}-${label}`);
    }
  }
});
