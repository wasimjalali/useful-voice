/**
 * The wiring between a dictation and the app category core: which category a captured
 * target belongs to, what the user's settings make of it, and the safe wrapper around the
 * per-category formatter. Pure and free of Electron: the main process supplies the
 * readers (browser address, text before the cursor) and this decides.
 *
 * The rules the Swift app follows, mirrored here:
 * - the category comes from the target captured at the hotkey press (never from what is in
 *   front after transcription), its browser page at that moment and the user's overrides;
 *   a window dictation or no target is `other`;
 * - the formatter only ever improves a dictation: if it throws or returns nothing, the
 *   text the pipeline had is delivered as it was;
 * - the text before the cursor lives in memory for one dictation, 200 characters at most.
 */
import { formatForCategory } from '../formatting/categoryFormatter.js';
import {
  allowedStyles,
  AUTO_SEND_KEYS,
  APP_CATEGORIES,
  isAppCategory,
  sendKeyChord,
  type AppCategory,
  type AutoSendKey,
  type FormattingStyle,
} from './appCategory.js';
import { isBrowser, normalizeAppID, parseCategoryOverrides, resolveCategory } from './appCategoryRegistry.js';

/** How much of the text before the caret is kept. */
export const TEXT_BEFORE_CURSOR_CHARS = 200;

/** Most per-app category choices a settings file may hold. */
export const MAX_APP_CATEGORIES = 200;

/** Longest name accepted for the email sign-off. */
export const MAX_USER_NAME_CHARS = 60;

/** The categories that may press a key after a delivery. Never Email, never Docs and notes. */
export function autoSendOffered(category: AppCategory): boolean {
  return category !== 'email' && category !== 'docsNotes';
}

/** The categories Settings offers a send key for, in the order Settings lists them. */
export const AUTO_SEND_CATEGORIES: readonly AppCategory[] = APP_CATEGORIES.filter(autoSendOffered);

/** Whether Settings offers a style for the category. Coding's rules ignore it. */
export function styleOffered(category: AppCategory): boolean {
  return category !== 'coding';
}

/**
 * The registry's id for a captured target. The target's app id is the executable name
 * without `.exe` (`slack`); the registry and the overrides use the executable name
 * (`slack.exe`), so a hand-written override reads the same on both platforms.
 */
export function registryAppID(appId: string | null | undefined): string | null {
  const id = (appId ?? '').trim();
  if (id === '') return null;
  return /\.exe$/i.test(id) ? id : `${id}.exe`;
}

// ---- settings, read leniently -------------------------------------------------

/** Styles per category, keeping only a style the category may use. Never throws. */
export function normaliseCategoryStyles(raw: unknown): Partial<Record<AppCategory, FormattingStyle>> {
  const out: Partial<Record<AppCategory, FormattingStyle>> = {};
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return out;
  const stored = raw as Record<string, unknown>;
  for (const category of APP_CATEGORIES) {
    const value = stored[category];
    if (allowedStyles(category).some((style) => style === value)) out[category] = value as FormattingStyle;
  }
  return out;
}

/** Send keys per category: a real key, for a category that may have one. Off is not stored. */
export function normaliseAutoSend(raw: unknown): Partial<Record<AppCategory, AutoSendKey>> {
  const out: Partial<Record<AppCategory, AutoSendKey>> = {};
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return out;
  const stored = raw as Record<string, unknown>;
  for (const category of AUTO_SEND_CATEGORIES) {
    const value = stored[category];
    if (value !== 'off' && AUTO_SEND_KEYS.some((key) => key === value)) out[category] = value as AutoSendKey;
  }
  return out;
}

/** One line, no control characters, trimmed and capped. Anything else is no name. */
export function normaliseUserName(raw: unknown): string {
  if (typeof raw !== 'string') return '';
  const clean = raw.replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, ' ').replace(/\s+/g, ' ').trim();
  return Array.from(clean).slice(0, MAX_USER_NAME_CHARS).join('').trim();
}

/**
 * The per-app choices from a settings file: the #51 decoder drops what it can't read, the
 * keys are put in the registry's form (`Slack.EXE` is `slack.exe`) and the list is capped.
 */
export function normaliseAppCategories(raw: unknown): Record<string, AppCategory> {
  const parsed = parseCategoryOverrides(raw);
  const out = new Map<string, AppCategory>();
  for (const key of Object.keys(parsed).sort()) {
    const id = normalizeAppID(key);
    const category = parsed[key];
    if (id === '' || !category || out.has(id)) continue;
    out.set(id, category);
    if (out.size >= MAX_APP_CATEGORIES) break;
  }
  return Object.fromEntries(out);
}

// ---- the captured context -----------------------------------------------------

/** What a dictation knows about where it is going, fixed at the hotkey press. */
export interface DictationContext {
  /** The app's executable name, or null for a window dictation and an unidentified app. */
  appID: string | null;
  category: AppCategory;
  /**
   * Up to 200 characters before the caret in the target's field, or null when unknown.
   * Memory only: never logged, never stored, never in History.
   */
  textBeforeCursor: string | null;
}

/** A window dictation, or a hotkey press with no readable target. */
export const NO_TARGET_CONTEXT: DictationContext = { appID: null, category: 'other', textBeforeCursor: null };

/**
 * The context the moment the press is handled (`initial`), and the one with the page and
 * the text before the cursor read (`settled`, which never rejects). The service waits a
 * short while for `settled` and uses `initial` when it is late.
 */
export interface ContextCapture {
  initial: DictationContext;
  settled: Promise<DictationContext>;
}

export const NO_TARGET_CAPTURE: ContextCapture = {
  initial: NO_TARGET_CONTEXT,
  settled: Promise.resolve(NO_TARGET_CONTEXT),
};

/** The last 200 characters (code points), or null for anything that is not text. */
export function clipTextBeforeCursor(text: string | null | undefined): string | null {
  if (typeof text !== 'string') return null;
  const chars = Array.from(text);
  return chars.slice(Math.max(0, chars.length - TEXT_BEFORE_CURSOR_CHARS)).join('');
}

export interface ContextReaders {
  /** The page address of the target, when it is a browser whose address bar can be read. */
  address?: () => Promise<string | null>;
  /** The text before the caret, or null. May reject: that is the same as null. */
  textBeforeCursor?: () => Promise<string | null>;
}

async function readOrNull<T>(read: (() => Promise<T>) | undefined): Promise<T | null> {
  if (!read) return null;
  try {
    return await read();
  } catch {
    return null;
  }
}

/**
 * Captures the context for a hotkey dictation. `appId` is the target's app id (the process
 * name without `.exe`); `overrides` are the user's choices at the press.
 */
export function captureContext(
  appId: string | null | undefined,
  overrides: Readonly<Record<string, AppCategory>>,
  readers: ContextReaders,
): ContextCapture {
  const appID = registryAppID(appId);
  if (appID === null) return NO_TARGET_CAPTURE;
  const initial: DictationContext = {
    appID,
    category: resolveCategory({ appID, overrides }),
    textBeforeCursor: null,
  };
  const settled = Promise.all([
    // Only a browser's page changes its category: no other app needs an address.
    isBrowser(appID) ? readOrNull(readers.address) : Promise.resolve(null),
    readOrNull(readers.textBeforeCursor),
  ]).then(
    ([url, text]): DictationContext => ({
      appID,
      category: resolveCategory({ appID, url, overrides }),
      textBeforeCursor: clipTextBeforeCursor(text),
    }),
    () => initial,
  );
  return { initial, settled };
}

// ---- formatting ---------------------------------------------------------------

export interface AppFormatSettings {
  categoryStyles: Partial<Record<AppCategory, FormattingStyle>>;
  userName: string;
}

export interface AppFormatResult {
  text: string;
  /** The formatter ran and gave back text. False means `text` is the input, untouched. */
  applied: boolean;
}

/**
 * Formats a dictation for its category. If the formatter throws or comes back empty (or
 * anything else is off), the input is returned as it was: a dictation is never lost to it.
 */
export function formatForApp(
  text: string,
  context: DictationContext,
  settings: AppFormatSettings,
  dictionaryWords: readonly string[],
): AppFormatResult {
  try {
    const name = settings.userName.trim();
    const formatted = formatForCategory(text, {
      category: context.category,
      style: settings.categoryStyles[context.category] ?? null,
      userName: name === '' ? null : name,
      textBeforeCursor: context.textBeforeCursor,
      dictionaryWords,
    });
    if (typeof formatted !== 'string' || formatted.trim() === '') return { text, applied: false };
    return { text: formatted, applied: true };
  } catch {
    return { text, applied: false };
  }
}

// ---- auto-send ----------------------------------------------------------------

/** The key to press after a landed delivery for the category, or `off`. */
export function autoSendKeyFor(
  autoSend: Partial<Record<AppCategory, AutoSendKey>>,
  category: AppCategory,
): AutoSendKey {
  if (!autoSendOffered(category)) return 'off';
  const key = autoSend[category];
  return key !== undefined && AUTO_SEND_KEYS.includes(key) ? key : 'off';
}

/**
 * The Windows `SendKeys` text for a send key, or null for none: Return, Shift+Return or
 * Ctrl+Return. The text is fixed by the key; nothing from a dictation ever reaches it.
 */
export function sendKeysFor(key: AutoSendKey): string | null {
  const chord = sendKeyChord(key, 'windows');
  if (!chord) return null;
  return `${chord.shift ? '+' : ''}${chord.control ? '^' : ''}{ENTER}`;
}

/** The category, for a stored value that may be anything. */
export function storedCategory(value: unknown): AppCategory | undefined {
  return isAppCategory(value) ? value : undefined;
}
