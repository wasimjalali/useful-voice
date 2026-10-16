import { expect, test, type Page } from '@playwright/test';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { seedUserData } from './fixtures.js';
import {
  clipboardText,
  collect,
  historyWhere,
  hook,
  launch,
  log,
  out,
  remove,
  setKey,
  type Running,
} from './harness.js';

// App-aware formatting on the built app, end to end: a real recording from the fake
// microphone, the real key check against the e2e Deepgram stub, the real pipeline, delivery
// and history. Only the desktop is scripted (`__uv.useFakeDesktop`): who is in front, the
// browser page, the text before the caret. A paste, a typed text and a send key are
// recorded instead of sent, so no spec ever pastes into, or presses Return in, whatever is
// in front of the machine running the suite.
//
//   1. an email with a greeting and sign-off to a mail app, your name set, a hand-written
//      send key for Email that must be ignored; then a chat message whose send key fires once
//   2. copy-only deliveries (the window moved, a line-break text for a typing app) where the
//      send key must NOT fire
//   3. the hotkey pressed in Useful Voice itself: a window dictation, copied, never pasted
//   4. a browser page decides the category, text before the caret continues the sentence,
//      and an override beats the page
//   5. Format for the app off leaves the text alone
//   6. the Settings controls and the app list

const SECOND = 1000;
const shots = path.join(out, 'shots-app-aware');

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

interface StartOptions {
  settings?: Record<string, unknown>;
  history?: Array<Record<string, unknown>>;
}

async function start(name: string, options: StartOptions = {}): Promise<Running> {
  const userData = await seedUserData({ emptyHistory: options.history !== undefined });
  if (options.history) {
    const file = path.join(userData, 'data.json');
    const data = JSON.parse(await fs.readFile(file, 'utf8')) as { payload: { history: unknown[] } };
    data.payload.history = options.history;
    await fs.writeFile(file, JSON.stringify(data));
  }
  await fs.writeFile(
    path.join(userData, 'settings.json'),
    JSON.stringify({ version: 1, firstRunCompleted: true, settings: options.settings ?? {} }),
  );
  run = await launch(name, userData);
  await collect(run.win);
  await setKey(run.win, 'valid-e2e-key');
  return run;
}

async function shot(win: Page, name: string): Promise<void> {
  await win.waitForTimeout(350);
  await fs.mkdir(shots, { recursive: true });
  const file = path.join(shots, `${name}.png`);
  await win.screenshot({ path: file });
  await test.info().attach(name, { path: file, contentType: 'image/png' });
}

interface Call {
  kind: string;
  inserted?: string;
  typed?: string;
  key?: string;
}

const calls = async (app: Running['app']): Promise<Call[]> => (await hook(app, 'fakeCalls')) as Call[];

/** One whole hotkey dictation: press, speak for a moment, press, wait until it is over. */
async function hotkeyDictation(r: Running, transcript: string, seconds = 1.5): Promise<void> {
  await hook(r.app, 'setTranscript', transcript);
  const before = (await log(r.win)).outcomes.length;
  await hook(r.app, 'pressHotkey');
  await expect.poll(() => hook(r.app, 'serviceState'), { timeout: 15 * SECOND }).toBe('recording');
  await r.win.waitForTimeout(seconds * SECOND);
  await hook(r.app, 'pressHotkey');
  await expect.poll(async () => (await log(r.win)).outcomes.length, { timeout: 30 * SECOND }).toBe(before + 1);
  await expect.poll(() => hook(r.app, 'serviceState')).toBe('idle');
}

async function savedSettings(userData: string): Promise<Record<string, unknown>> {
  const file = JSON.parse(await fs.readFile(path.join(userData, 'settings.json'), 'utf8')) as { settings?: Record<string, unknown> };
  return file.settings ?? {};
}

const EMAIL =
  'Hi Sam, thanks for the update. I will send the report tomorrow. Best regards.';
const EMAIL_FORMATTED =
  'Hi Sam,\n\nThanks for the update. I will send the report tomorrow.\n\nBest regards,\nWasim';

test('an email is laid out with your name, a chat message is sent once, and Email never gets a send key', async () => {
  // The file also holds a send key for Email, which a person could only have typed by hand.
  const r = await start('email-and-chat', {
    settings: { userName: 'Wasim', autoSend: { email: 'return', workChat: 'return' } },
    history: [],
  });
  await hook(r.app, 'useFakeDesktop', { foreground: { processName: 'olk', title: 'Inbox - Outlook' } });

  await hotkeyDictation(r, EMAIL);
  expect(await calls(r.app)).toEqual([expect.objectContaining({ kind: 'paste', inserted: EMAIL_FORMATTED })]);
  expect((await log(r.win)).outcomes.at(-1)).toMatchObject({ kind: 'delivered', result: 'pasted' });

  // A chat: casual drops the closing full stop, and the send key goes out once, after the paste.
  await hook(r.app, 'fakeDesktop', { foreground: { processName: 'slack', title: 'general - Slack' } });
  await hotkeyDictation(r, 'Sounds good, see you at five.');
  const all = await calls(r.app);
  expect(all.slice(1).map((call) => call.kind)).toEqual(['paste', 'sendKey']);
  expect(all[1]).toMatchObject({ inserted: 'Sounds good, see you at five' });
  expect(all[2]).toMatchObject({ key: 'return' });
  expect(all.filter((call) => call.kind === 'sendKey')).toHaveLength(1);

  // History keeps the app and the category it was written for, and the row says so.
  const history = await historyWhere(r.userData, (rows) => rows.length === 2);
  expect(history.map((row) => [row.appID, row.category])).toEqual([['slack.exe', 'workChat'], ['olk.exe', 'email']]);
  await r.win.locator('.rail-item', { hasText: 'Dictations' }).click();
  await expect(r.win.locator('.bubble')).toHaveCount(2);
  await expect(r.win.locator('.bubble .bubble-meta', { hasText: 'Work chat' })).toHaveCount(1);
  await expect(r.win.locator('.bubble .bubble-meta', { hasText: 'Email' })).toHaveCount(1);
  await shot(r.win, 'app-aware-01-stream-categories');
});

test('the send key stays quiet after a copy-only delivery', async () => {
  const r = await start('copy-only', {
    settings: { autoSend: { workChat: 'return', coding: 'return' }, typeOutApps: ['windowsterminal'] },
    history: [],
  });
  await hook(r.app, 'useFakeDesktop', { foreground: { processName: 'slack', title: 'general - Slack' }, reactivate: 'refused' });

  // The window in front moved to another app while it transcribed, and could not be brought back.
  await hook(r.app, 'setTranscript', 'Sounds good, see you at five.');
  await hook(r.app, 'pressHotkey');
  await expect.poll(() => hook(r.app, 'serviceState'), { timeout: 15 * SECOND }).toBe('recording');
  await hook(r.app, 'fakeDesktop', { foreground: { processName: 'notepad', title: 'Untitled - Notepad' } });
  await r.win.waitForTimeout(1500);
  await hook(r.app, 'pressHotkey');
  await expect.poll(async () => (await log(r.win)).outcomes.length, { timeout: 30 * SECOND }).toBe(1);
  expect((await log(r.win)).outcomes[0]).toMatchObject({ kind: 'delivered', result: 'copiedNotPasted' });
  expect(await clipboardText(r.app)).toBe('Sounds good, see you at five');
  expect((await calls(r.app)).filter((call) => ['paste', 'typeOut', 'sendKey'].includes(call.kind))).toEqual([]);

  // A text with a line break for an app that types is copied only, and Coding's send key stays quiet.
  await hook(r.app, 'fakeDesktop', { foreground: { processName: 'WindowsTerminal', title: 'PowerShell' } });
  await hotkeyDictation(r, 'ls dash la.\nnpm test.');
  expect((await log(r.win)).outcomes[1]).toMatchObject({ kind: 'delivered', result: 'copiedNotPasted', lineBreaks: true });
  expect((await calls(r.app)).filter((call) => ['paste', 'typeOut', 'sendKey'].includes(call.kind))).toEqual([]);
  expect((await clipboardText(r.app)).includes('\n')).toBe(true);

  // And the same terminal with one line is typed, and then the send key does go out.
  await hotkeyDictation(r, 'npm test');
  const keys = (await calls(r.app)).map((call) => call.kind);
  expect(keys.slice(-2)).toEqual(['typeOut', 'sendKey']);
});

test('the hotkey pressed in Useful Voice itself is a window dictation: copied, saved, never pasted', async () => {
  const r = await start('own-window', { settings: { autoSend: { other: 'return' } }, history: [] });
  const own = (await hook(r.app, 'ownProcess')) as { name: string; pid: number };
  await hook(r.app, 'useFakeDesktop', { foreground: { processName: own.name, processId: own.pid, title: 'Useful Voice' } });

  await hotkeyDictation(r, 'Notes to self, buy milk.');
  // It started as a window dictation: every delivering status says copy, none says paste.
  const delivering = (await log(r.win)).states.filter((state) => state.state === 'delivering');
  expect(delivering.length).toBeGreaterThan(0);
  expect(delivering.every((state) => state.delivery === 'copy')).toBe(true);
  expect((await log(r.win)).outcomes.at(-1)).toMatchObject({ kind: 'delivered', result: 'copied' });
  expect(await calls(r.app)).toEqual([]);
  expect(await clipboardText(r.app)).toBe('Notes to self, buy milk.');
  const history = await historyWhere(r.userData, (rows) => rows.length === 1);
  expect(history[0]).toMatchObject({ appName: '', category: 'other' });
  expect(history[0]?.appID).toBeUndefined();
});

test('a browser page decides the category, the text before the caret continues the sentence, an override beats the page', async () => {
  const r = await start('browser', { history: [] });
  await hook(r.app, 'useFakeDesktop', {
    foreground: { processName: 'chrome', title: 'Slack - Acme' },
    address: 'https://acme.slack.com/client/T1/C2',
    textBefore: 'We agreed to wait, ',
  });
  await hotkeyDictation(r, 'And then we ship it.');
  expect((await calls(r.app)).at(-1)).toMatchObject({ kind: 'paste', inserted: 'and then we ship it' });
  await expect.poll(async () => (await historyWhere(r.userData, () => true))[0]?.category).toBe('workChat');

  // The same page, but Mail: Gmail is Email, so the sentence is laid out and kept formal.
  await hook(r.app, 'fakeDesktop', { address: 'https://mail.google.com/mail/u/0/#inbox', textBefore: '' });
  await hotkeyDictation(r, 'Thanks for the update.');
  expect((await calls(r.app)).at(-1)).toMatchObject({ inserted: 'Thanks for the update.' });
  expect((await historyWhere(r.userData, (rows) => rows.length === 2))[0]?.category).toBe('email');

  // The user says Chrome is Coding: the choice wins over the page.
  await r.win.evaluate(() => (window as unknown as { usefulVoice: { saveSettings(patch: unknown): Promise<unknown> } }).usefulVoice.saveSettings({ appCategories: { 'chrome.exe': 'coding' } }));
  await hotkeyDictation(r, 'And then we ship it.');
  expect((await historyWhere(r.userData, (rows) => rows.length === 3))[0]?.category).toBe('coding');
});

test('Format for the app off leaves the dictation as it was transcribed', async () => {
  const r = await start('off', { settings: { appAwareFormatting: false, userName: 'Wasim' }, history: [] });
  await hook(r.app, 'useFakeDesktop', { foreground: { processName: 'slack', title: 'general - Slack' } });
  await hotkeyDictation(r, 'Sounds good, see you at five.');
  expect((await calls(r.app)).at(-1)).toMatchObject({ kind: 'paste', inserted: 'Sounds good, see you at five.' });
  // The category is still recorded: it is the app, not the formatting.
  expect((await historyWhere(r.userData, (rows) => rows.length === 1))[0]).toMatchObject({ category: 'workChat', appID: 'slack.exe' });
});

test('Settings: the switch, the name, a style and a send key per category, and the app list with reset', async () => {
  const stamp = (minutes: number): string => new Date(Date.now() - minutes * 60_000).toISOString();
  const row = (id: string, appID: string | undefined, category: string | undefined, minutes: number) => ({
    id, text: `text ${id}`, rawText: `text ${id}`, intermediateText: `text ${id}`, language: 'en', appName: appID ? appID.replace('.exe', '') : '',
    ...(appID ? { appID } : {}), ...(category ? { category } : {}),
    durationSeconds: 2, mode: 'formatted', createdAt: stamp(minutes), replacementRuleIds: [], memoryHitIds: [], snippetIds: [],
  });
  const r = await start('settings', {
    // A file from before app-aware formatting: none of the new keys.
    settings: { languagePin: 'de' },
    history: [row('a', 'slack.exe', 'workChat', 5), row('b', 'olk.exe', 'email', 10), row('c', 'notepad.exe', 'other', 20), row('d', undefined, undefined, 30)],
  });
  const { win, userData } = r;
  await win.locator('.rail-item', { hasText: 'Settings' }).click();
  await win.locator('.s-index-item', { hasText: 'Apps' }).click();
  const group = win.locator('#settings-apps');
  await expect(group).toBeVisible();

  // Defaults of an old file: on, no name, the category defaults, no send key anywhere.
  const format = group.getByRole('switch', { name: 'Format for the app' });
  await expect(format).toHaveAttribute('aria-checked', 'true');
  await expect(group.getByRole('textbox', { name: 'Your name' })).toHaveValue('');
  await expect(group.getByRole('button', { name: 'Work chat style' })).toContainText('Casual');
  await expect(group.getByRole('button', { name: 'Email style' })).toContainText('Formal');
  await expect(group.getByRole('button', { name: 'Work chat send key' })).toContainText('No send key');
  // Email and Docs and notes are never offered a send key; Coding has no style.
  await expect(group.getByRole('button', { name: 'Email send key' })).toHaveCount(0);
  await expect(group.getByRole('button', { name: 'Docs and notes send key' })).toHaveCount(0);
  await expect(group.getByRole('button', { name: 'Coding style' })).toHaveCount(0);
  await expect(group.getByRole('button', { name: 'Coding send key' })).toHaveCount(1);
  await shot(win, 'app-aware-02-settings-defaults');

  await format.click();
  await expect(format).toHaveAttribute('aria-checked', 'false');
  await expect.poll(async () => (await savedSettings(userData)).appAwareFormatting).toBe(false);
  await format.click();
  await expect.poll(async () => (await savedSettings(userData)).appAwareFormatting).toBe(true);

  const name = group.getByRole('textbox', { name: 'Your name' });
  await name.fill('  Wasim Jalali ');
  await name.press('Tab');
  await expect.poll(async () => (await savedSettings(userData)).userName).toBe('Wasim Jalali');
  await expect(name).toHaveValue('Wasim Jalali');

  // Very casual is a Personal chat style only.
  await group.getByRole('button', { name: 'Work chat style' }).click();
  await expect(win.getByRole('option', { name: 'Very casual' })).toHaveCount(0);
  await win.getByRole('option', { name: 'Formal' }).click();
  await group.getByRole('button', { name: 'Personal chat style' }).click();
  await expect(win.getByRole('option', { name: 'Very casual' })).toHaveCount(1);
  await win.getByRole('option', { name: 'Very casual' }).click();
  await expect.poll(async () => (await savedSettings(userData)).categoryStyles).toEqual({ workChat: 'formal', personalChat: 'veryCasual' });

  await group.getByRole('button', { name: 'Work chat send key' }).click();
  await win.getByRole('option', { name: 'Send with Ctrl+Enter' }).click();
  await expect.poll(async () => (await savedSettings(userData)).autoSend).toEqual({ workChat: 'modReturn' });
  await group.getByRole('button', { name: 'Work chat send key' }).click();
  await win.getByRole('option', { name: 'No send key' }).click();
  await expect.poll(async () => (await savedSettings(userData)).autoSend).toEqual({});

  // The app list: the apps seen in History, newest first, each with the category it has.
  await expect(group.getByRole('button', { name: 'slack category' })).toContainText('Work chat');
  await expect(group.getByRole('button', { name: 'olk category' })).toContainText('Email');
  await expect(group.getByRole('button', { name: 'notepad category' })).toContainText('Other');
  await expect(group.getByRole('button', { name: 'Reset slack' })).toBeHidden();
  await group.getByRole('button', { name: 'slack category' }).click();
  await win.getByRole('option', { name: 'Personal chat' }).click();
  await expect.poll(async () => (await savedSettings(userData)).appCategories).toEqual({ 'slack.exe': 'personalChat' });
  await expect(group.getByRole('button', { name: 'Reset slack' })).toBeVisible();
  await shot(win, 'app-aware-03-settings-override');
  await group.getByRole('button', { name: 'Reset slack' }).click();
  await expect.poll(async () => (await savedSettings(userData)).appCategories).toEqual({});
  await expect(group.getByRole('button', { name: 'slack category' })).toContainText('Work chat');
  await expect(group.getByRole('button', { name: 'Reset slack' })).toBeHidden();

  // Nothing else in the old file was disturbed.
  expect((await savedSettings(userData)).languagePin).toBe('de');
  await shot(win, 'app-aware-04-settings-final');
});
