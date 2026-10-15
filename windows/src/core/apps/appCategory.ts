/**
 * App categories, per-category writing styles and the optional auto-send key.
 * Mirrors `Sources/UsefulVoiceCore/AppAwareness/AppCategory.swift` rule for rule.
 *
 * Pure data and mappings only. Nothing here reads the foreground app, a settings file
 * or the screen: the wiring layer feeds these functions and stores their results.
 */

export type AppCategory = 'email' | 'workChat' | 'personalChat' | 'coding' | 'docsNotes' | 'other';

/** Every category, in the order Settings lists them. */
export const APP_CATEGORIES: readonly AppCategory[] = [
  'email',
  'workChat',
  'personalChat',
  'coding',
  'docsNotes',
  'other',
];

export const APP_CATEGORY_NAMES: Record<AppCategory, string> = {
  email: 'Email',
  workChat: 'Work chat',
  personalChat: 'Personal chat',
  coding: 'Coding',
  docsNotes: 'Docs and notes',
  other: 'Other',
};

export function isAppCategory(value: unknown): value is AppCategory {
  return typeof value === 'string' && (APP_CATEGORIES as readonly string[]).includes(value);
}

export type FormattingStyle = 'formal' | 'casual' | 'veryCasual';

/**
 * Email, Docs and notes and Other default to Formal; both chat categories to Casual.
 * Coding has no style (its rules ignore it); Formal is the neutral value for it.
 */
export function defaultStyle(category: AppCategory): FormattingStyle {
  switch (category) {
    case 'workChat':
    case 'personalChat':
      return 'casual';
    case 'email':
    case 'coding':
    case 'docsNotes':
    case 'other':
      return 'formal';
  }
}

/** The styles Settings may offer for a category. Very casual is Personal chat only. */
export function allowedStyles(category: AppCategory): FormattingStyle[] {
  return category === 'personalChat' ? ['formal', 'casual', 'veryCasual'] : ['formal', 'casual'];
}

/**
 * The style that actually applies: the requested one (or the category default when none
 * is set), with Very casual falling back to Casual outside Personal chat.
 */
export function effectiveStyle(
  requested: FormattingStyle | null | undefined,
  category: AppCategory,
): FormattingStyle {
  const style = requested ?? defaultStyle(category);
  if (style === 'veryCasual' && category !== 'personalChat') return 'casual';
  return style;
}

export type AutoSendKey = 'off' | 'return' | 'shiftReturn' | 'modReturn';

export const AUTO_SEND_KEYS: readonly AutoSendKey[] = ['off', 'return', 'shiftReturn', 'modReturn'];

export type AppPlatform = 'macOS' | 'windows';

/** The Return key plus modifiers to post after a paste. Always the Return key. */
export interface SendKeyChord {
  shift: boolean;
  command: boolean;
  control: boolean;
}

/**
 * The key to send after a paste, or null for none. "Cmd/Ctrl+Return" is Command on macOS
 * and Control on Windows.
 */
export function sendKeyChord(key: AutoSendKey, platform: AppPlatform): SendKeyChord | null {
  switch (key) {
    case 'off':
      return null;
    case 'return':
      return { shift: false, command: false, control: false };
    case 'shiftReturn':
      return { shift: true, command: false, control: false };
    case 'modReturn':
      return platform === 'macOS'
        ? { shift: false, command: true, control: false }
        : { shift: false, command: false, control: true };
  }
}
