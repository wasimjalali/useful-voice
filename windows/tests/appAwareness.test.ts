import { describe, expect, it } from 'vitest';
import { APP_CATEGORIES, type AppCategory } from '../src/core/apps/appCategory.js';
import {
  autoSendKeyFor,
  autoSendOffered,
  captureContext,
  clipTextBeforeCursor,
  formatForApp,
  normaliseAppCategories,
  normaliseAutoSend,
  normaliseCategoryStyles,
  normaliseUserName,
  NO_TARGET_CONTEXT,
  registryAppID,
  sendKeysFor,
  TEXT_BEFORE_CURSOR_CHARS,
  type DictationContext,
} from '../src/core/apps/appAwareness.js';

/**
 * The wiring around the #51 core. Ways it could fail, each pinned below:
 *  - the category comes from the wrong place: the Windows app id (`slack`) never meets the
 *    registry's executable name (`slack.exe`), so every Windows app is Other; a browser's
 *    page is ignored, or read for an app that is not a browser; an override loses to a seed;
 *  - a window dictation or an unidentified app is anything but Other;
 *  - a failing or late reader loses the context, or throws into the dictation;
 *  - more than 200 characters of the field are kept;
 *  - the formatter throws or returns nothing and the dictation goes with it;
 *  - settings read from an old or hand-edited file throw, keep a style the category can't
 *    use, or offer a send key for Email or Docs and notes;
 *  - the send key text is built from anything but the setting.
 */

const email: DictationContext = { appID: 'olk.exe', category: 'email', textBeforeCursor: null };
const work = (before: string | null = null): DictationContext => ({ appID: 'slack.exe', category: 'workChat', textBeforeCursor: before });

describe('registryAppID', () => {
  it('turns the target app id into the executable name the registry knows', () => {
    expect(registryAppID('slack')).toBe('slack.exe');
    expect(registryAppID(' Slack ')).toBe('Slack.exe');
    expect(registryAppID('slack.exe')).toBe('slack.exe');
    expect(registryAppID('SLACK.EXE')).toBe('SLACK.EXE');
  });

  it('is nothing for an app that could not be identified', () => {
    expect(registryAppID(undefined)).toBeNull();
    expect(registryAppID(null)).toBeNull();
    expect(registryAppID('')).toBeNull();
    expect(registryAppID('   ')).toBeNull();
  });
});

describe('captureContext', () => {
  it('has no target and no category beyond Other for a window dictation or an unidentified app', async () => {
    for (const appId of [undefined, null, '']) {
      const capture = captureContext(appId, { 'slack.exe': 'coding' }, { textBeforeCursor: async () => 'secret' });
      expect(capture.initial).toEqual(NO_TARGET_CONTEXT);
      expect(await capture.settled).toEqual(NO_TARGET_CONTEXT);
    }
  });

  it('sorts a Windows app into its seeded category', async () => {
    const cases: Array<[string, AppCategory]> = [
      ['olk', 'email'],
      ['outlook', 'email'],
      ['slack', 'workChat'],
      ['whatsapp', 'personalChat'],
      ['windowsterminal', 'coding'],
      ['code', 'coding'],
      ['winword', 'docsNotes'],
      ['notepad', 'other'],
      ['some-unknown-tool', 'other'],
    ];
    for (const [appId, category] of cases) {
      const capture = captureContext(appId, {}, {});
      expect(capture.initial.category).toBe(category);
      expect((await capture.settled).category).toBe(category);
      expect(capture.initial.appID).toBe(`${appId}.exe`);
    }
  });

  it('lets the user override a seed, whatever the case of the stored key', async () => {
    const capture = captureContext('slack', { 'Slack.EXE': 'personalChat' }, {});
    expect(capture.initial.category).toBe('personalChat');
    expect((await capture.settled).category).toBe('personalChat');
  });

  it('takes a browser category from the page captured at the press', async () => {
    const mail = captureContext('chrome', {}, { address: async () => 'https://mail.google.com/mail/u/0/#inbox' });
    expect(mail.initial.category).toBe('other');
    expect((await mail.settled).category).toBe('email');

    const slack = captureContext('msedge', {}, { address: async () => 'https://acme.slack.com/client/T1/C2' });
    expect((await slack.settled).category).toBe('workChat');

    const agent = captureContext('chrome', {}, { address: async () => 'https://claude.ai/code/session_1' });
    expect((await agent.settled).category).toBe('coding');
  });

  it('an override for the browser beats the page', async () => {
    const capture = captureContext('chrome', { 'chrome.exe': 'docsNotes' }, { address: async () => 'https://mail.google.com/' });
    expect(capture.initial.category).toBe('docsNotes');
    expect((await capture.settled).category).toBe('docsNotes');
  });

  it('never reads a page for an app that is not a browser', async () => {
    let asked = 0;
    const capture = captureContext('slack', {}, { address: async () => { asked += 1; return 'https://mail.google.com/'; } });
    expect((await capture.settled).category).toBe('workChat');
    expect(asked).toBe(0);
  });

  it('keeps going when a reader fails or answers nothing', async () => {
    const failing = captureContext('chrome', {}, {
      address: async () => { throw new Error('uia'); },
      textBeforeCursor: async () => { throw new Error('uia'); },
    });
    expect(await failing.settled).toEqual({ appID: 'chrome.exe', category: 'other', textBeforeCursor: null });

    const empty = captureContext('chrome', {}, { address: async () => null, textBeforeCursor: async () => null });
    expect(await empty.settled).toEqual({ appID: 'chrome.exe', category: 'other', textBeforeCursor: null });
  });

  it('keeps an empty field as an empty string: the caret is at the start', async () => {
    const capture = captureContext('slack', {}, { textBeforeCursor: async () => '' });
    expect((await capture.settled).textBeforeCursor).toBe('');
  });

  it('keeps at most the last 200 characters before the cursor', async () => {
    const long = `${'a'.repeat(500)}TAIL`;
    const capture = captureContext('slack', {}, { textBeforeCursor: async () => long });
    const text = (await capture.settled).textBeforeCursor ?? '';
    expect(Array.from(text)).toHaveLength(TEXT_BEFORE_CURSOR_CHARS);
    expect(text.endsWith('TAIL')).toBe(true);
    // By characters, not UTF-16 units: an emoji is not cut in half.
    expect(clipTextBeforeCursor('😀'.repeat(300))).toBe('😀'.repeat(200));
    expect(clipTextBeforeCursor('short')).toBe('short');
    expect(clipTextBeforeCursor(null)).toBeNull();
    expect(clipTextBeforeCursor(undefined)).toBeNull();
  });

  it('does not put the text before the cursor in the context a late read falls back to', async () => {
    const capture = captureContext('slack', {}, { textBeforeCursor: () => new Promise<string>(() => undefined) });
    expect(capture.initial.textBeforeCursor).toBeNull();
  });
});

describe('formatForApp', () => {
  const settings = { categoryStyles: {}, userName: '' };

  it('formats for the category and says it did', () => {
    const result = formatForApp('Sounds good, see you at five.', work(), settings, []);
    expect(result).toEqual({ text: 'Sounds good, see you at five', applied: true });
  });

  it('uses the style the user picked, and the default without one', () => {
    expect(formatForApp('See you at five.', work(), { categoryStyles: { workChat: 'formal' }, userName: '' }, []).text).toBe('See you at five.');
    expect(formatForApp('See you at five.', work(), settings, []).text).toBe('See you at five');
    const personal: DictationContext = { appID: 'whatsapp.exe', category: 'personalChat', textBeforeCursor: null };
    expect(formatForApp('See you at five.', personal, { categoryStyles: { personalChat: 'veryCasual' }, userName: '' }, []).text).toBe('see you at five');
  });

  it('adds the name under a dictated sign-off only, and only when one is set', () => {
    const dictation = 'Hi Sam, thanks for the update. I will send the report tomorrow. Best regards.';
    expect(formatForApp(dictation, email, { categoryStyles: {}, userName: 'Wasim' }, []).text).toBe(
      'Hi Sam,\n\nThanks for the update. I will send the report tomorrow.\n\nBest regards,\nWasim',
    );
    expect(formatForApp(dictation, email, { categoryStyles: {}, userName: '   ' }, []).text).toBe(
      'Hi Sam,\n\nThanks for the update. I will send the report tomorrow.\n\nBest regards.',
    );
    expect(formatForApp('Thanks for the update.', email, { categoryStyles: {}, userName: 'Wasim' }, []).text).not.toContain('Wasim');
  });

  it('continues the sentence the cursor is in', () => {
    expect(formatForApp('And then we ship it.', work('We agreed to wait, '), settings, []).text).toBe('and then we ship it');
  });

  it('hands back the input untouched when the formatter throws', () => {
    const exploding = {
      get categoryStyles(): never {
        throw new Error('boom');
      },
      userName: '',
    };
    expect(formatForApp('Sounds good.', work(), exploding, [])).toEqual({ text: 'Sounds good.', applied: false });
  });

  it('hands back the input untouched when the formatter returns nothing', () => {
    // A dictation that is only whitespace: the core returns it as it is, and it counts as not applied.
    expect(formatForApp('   ', work(), settings, [])).toEqual({ text: '   ', applied: false });
    expect(formatForApp('', work(), settings, [])).toEqual({ text: '', applied: false });
  });
});

describe('settings read from a file', () => {
  it('reads styles leniently and keeps only a style the category can use', () => {
    expect(normaliseCategoryStyles({ email: 'casual', workChat: 'veryCasual', personalChat: 'veryCasual', other: 'bogus', nope: 'formal' })).toEqual({
      email: 'casual',
      personalChat: 'veryCasual',
    });
    for (const junk of [undefined, null, 'casual', 5, [], ['casual']]) expect(normaliseCategoryStyles(junk)).toEqual({});
  });

  it('keeps a send key only for a category that may have one, and never stores off', () => {
    expect(
      normaliseAutoSend({
        email: 'return',
        docsNotes: 'modReturn',
        workChat: 'return',
        personalChat: 'shiftReturn',
        coding: 'modReturn',
        other: 'off',
      }),
    ).toEqual({ workChat: 'return', personalChat: 'shiftReturn', coding: 'modReturn' });
    expect(normaliseAutoSend({ workChat: 'enter', coding: 5, personalChat: null })).toEqual({});
    for (const junk of [undefined, null, 'return', [], 3]) expect(normaliseAutoSend(junk)).toEqual({});
  });

  it('offers a send key everywhere but Email and Docs and notes', () => {
    expect(APP_CATEGORIES.filter(autoSendOffered)).toEqual(['workChat', 'personalChat', 'coding', 'other']);
  });

  it('reads the name as one short line', () => {
    expect(normaliseUserName('  Wasim  ')).toBe('Wasim');
    expect(normaliseUserName('Wasim\nJalali\t')).toBe('Wasim Jalali');
    expect(normaliseUserName('x'.repeat(200))).toHaveLength(60);
    expect(normaliseUserName('Was\u0000im   \u2028 Jalali\u007f')).toBe('Was im Jalali');
    // Every control character is a space (C0, DEL and C1), but format characters stay.
    expect(normaliseUserName('ab\u0001cd')).toBe('ab cd');
    expect(normaliseUserName('ab\u0085cd\u009fef')).toBe('ab cd ef');
    expect(normaliseUserName('فاطمه\u200cزهرا')).toBe('فاطمه\u200cزهرا');
    expect(normaliseUserName('a\u200d\u200eb\u00adc')).toBe('a\u200d\u200eb\u00adc');
    expect(normaliseUserName(42)).toBe('');
    expect(normaliseUserName(undefined)).toBe('');
  });

  it('reads the per-app choices with the #51 decoder, in the registry form and capped', () => {
    expect(normaliseAppCategories({ 'Slack.EXE': 'personalChat', 'chrome.exe': 'nope', 'notepad.exe': 'coding', '': 'email' })).toEqual({
      'notepad.exe': 'coding',
      'slack.exe': 'personalChat',
    });
    const many: Record<string, string> = {};
    for (let i = 0; i < 400; i += 1) many[`app${i}.exe`] = 'coding';
    expect(Object.keys(normaliseAppCategories(many))).toHaveLength(200);
    for (const junk of [undefined, null, 'coding', 7, ['coding']]) expect(normaliseAppCategories(junk)).toEqual({});
  });

  it('keeps a __proto__ key as data and does not touch the prototype', () => {
    const parsed = normaliseAppCategories(JSON.parse('{"__proto__": "coding"}'));
    expect(Object.keys(parsed)).toEqual(['__proto__']);
    expect(({} as Record<string, unknown>).coding).toBeUndefined();
  });
});

describe('the send key', () => {
  it('is the setting for a category that may have one, and off for Email and Docs and notes whatever a file says', () => {
    const all: Partial<Record<AppCategory, 'return'>> = { email: 'return', docsNotes: 'return', workChat: 'return' };
    expect(autoSendKeyFor(all, 'workChat')).toBe('return');
    expect(autoSendKeyFor(all, 'email')).toBe('off');
    expect(autoSendKeyFor(all, 'docsNotes')).toBe('off');
    expect(autoSendKeyFor(all, 'coding')).toBe('off');
    expect(autoSendKeyFor({}, 'workChat')).toBe('off');
    expect(autoSendKeyFor({ workChat: 'bogus' as never }, 'workChat')).toBe('off');
  });

  it('is Return, Shift+Return or Ctrl+Return as SendKeys writes them, and nothing for off', () => {
    expect(sendKeysFor('off')).toBeNull();
    expect(sendKeysFor('return')).toBe('{ENTER}');
    expect(sendKeysFor('shiftReturn')).toBe('+{ENTER}');
    // Ctrl, not Command: this is the Windows app.
    expect(sendKeysFor('modReturn')).toBe('^{ENTER}');
  });
});
