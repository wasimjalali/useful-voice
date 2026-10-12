/**
 * Validation for a global hotkey, before it is saved or registered. Electron's
 * `globalShortcut.register` throws on an accelerator it cannot parse, so a bad value must
 * never reach it (or the settings file).
 */

// The modifiers and key codes below are Electron's documented accelerator set:
// https://www.electronjs.org/docs/latest/api/accelerator
const MODIFIERS: Record<string, string> = {
  control: 'Control', ctrl: 'Control', commandorcontrol: 'Control', cmdorctrl: 'Control',
  alt: 'Alt', option: 'Alt', altgr: 'AltGr',
  shift: 'Shift',
  super: 'Super', meta: 'Super', cmd: 'Super', command: 'Super',
};
const ORDER = ['Control', 'Alt', 'AltGr', 'Shift', 'Super'];

const NAMED_KEYS = new Set([
  'plus', 'space', 'tab', 'capslock', 'numlock', 'scrolllock', 'backspace', 'delete', 'insert',
  'return', 'enter', 'up', 'down', 'left', 'right', 'home', 'end', 'pageup', 'pagedown',
  'volumeup', 'volumedown', 'volumemute', 'medianexttrack', 'mediaprevioustrack', 'mediastop',
  'mediaplaypause', 'printscreen', 'numdec', 'numadd', 'numsub', 'nummult', 'numdiv',
  ...Array.from({ length: 10 }, (_, i) => `num${i}`),
]);

/** The single-character keys the docs list: 0-9, A-Z and the punctuation set. */
const SINGLE = /^[A-Za-z0-9)!@#$%^&*(:;=<,_\->.?/~`{\]\[|\\}"]$/;

function isKey(token: string): boolean {
  const lower = token.toLowerCase();
  if (NAMED_KEYS.has(lower)) return true;
  if (/^f([1-9]|1\d|2[0-4])$/.test(lower)) return true;
  return SINGLE.test(token);
}

/** One spelling per combination: modifiers in a fixed order, the key last. Null if unparsable. */
export function normalizeAccelerator(value: string): string | null {
  const modifiers = new Set<string>();
  let key: string | null = null;
  for (const raw of value.split('+')) {
    const token = raw.trim();
    if (token.length === 0) return null;
    const modifier = MODIFIERS[token.toLowerCase()];
    if (modifier) {
      if (modifiers.has(modifier)) return null;
      modifiers.add(modifier);
    } else {
      if (key !== null) return null;
      key = token.toLowerCase();
    }
  }
  if (key === null) return null;
  return [...ORDER.filter((name) => modifiers.has(name)), key].join('+');
}

/** Whether two accelerators are the same combination, whatever the spelling or order. */
export function sameAccelerator(a: string, b: string): boolean {
  const left = normalizeAccelerator(a);
  return left !== null && left === normalizeAccelerator(b);
}

/** Why `value` cannot be a dictation hotkey, or null when it can. `other` is the other hotkey. */
export function validateAccelerator(value: string, other = ''): string | null {
  const text = value.trim();
  if (text.length === 0) return 'A hotkey is required.';
  const parts = text.split('+').map((part) => part.trim());
  if (parts.some((part) => part.length === 0)) return 'Use one key with Ctrl or Alt, like Ctrl+Alt+Space.';
  const keys = parts.filter((part) => !MODIFIERS[part.toLowerCase()]);
  if (keys.length !== 1) return 'Use one key with Ctrl or Alt, like Ctrl+Alt+Space.';
  if (/^esc(ape)?$/i.test(keys[0] as string)) return 'Esc cancels a recording, so it cannot be the hotkey.';
  if (!isKey(keys[0] as string)) return `"${keys[0]}" is not a key a hotkey can use.`;
  const normalized = normalizeAccelerator(text);
  if (normalized === null) return 'Use one key with Ctrl or Alt, like Ctrl+Alt+Space.';
  const modifiers = normalized.split('+').slice(0, -1);
  if (!modifiers.includes('Control') && !modifiers.includes('Alt') && !modifiers.includes('AltGr')) return 'Add Ctrl or Alt, like Ctrl+Alt+Space.';
  if (other.trim().length > 0 && normalizeAccelerator(other) === normalized) {
    return "Dictation and the language picker can't share a hotkey.";
  }
  return null;
}
