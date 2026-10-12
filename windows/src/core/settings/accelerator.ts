/**
 * Validation for a global hotkey, before it is saved or registered. Electron's
 * `globalShortcut.register` throws on an accelerator it cannot parse, so a bad value must
 * never reach it (or the settings file).
 */

const MODIFIERS: Record<string, string> = {
  control: 'Control', ctrl: 'Control', commandorcontrol: 'Control', cmdorctrl: 'Control',
  alt: 'Alt', option: 'Alt',
  shift: 'Shift',
  super: 'Super', meta: 'Super', cmd: 'Super', command: 'Super', win: 'Super',
};
const ORDER = ['Control', 'Alt', 'Shift', 'Super'];

const NAMED_KEYS = new Set([
  'space', 'tab', 'backspace', 'delete', 'insert', 'return', 'enter', 'up', 'down', 'left',
  'right', 'home', 'end', 'pageup', 'pagedown', 'plus',
  ...Array.from({ length: 10 }, (_, i) => `num${i}`),
]);

function isKey(token: string): boolean {
  const lower = token.toLowerCase();
  if (NAMED_KEYS.has(lower)) return true;
  if (/^f([1-9]|1\d|2[0-4])$/.test(lower)) return true;
  return /^[A-Za-z0-9`\-=[\]\;',./]$/.test(token);
}

/** One spelling per combination: modifiers in a fixed order, the key last. Null if unparsable. */
function normalize(value: string): string | null {
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

/** Why `value` cannot be a dictation hotkey, or null when it can. `other` is the other hotkey. */
export function validateAccelerator(value: string, other = ''): string | null {
  const text = value.trim();
  if (text.length === 0) return 'A hotkey is required.';
  const parts = text.split('+').map((part) => part.trim());
  if (parts.some((part) => part.length === 0)) return 'Use one key with Ctrl or Alt, like Ctrl+Alt+Space.';
  const keys = parts.filter((part) => !MODIFIERS[part.toLowerCase()]);
  if (keys.length !== 1) return 'Use one key with Ctrl or Alt, like Ctrl+Alt+Space.';
  if (/^esc(ape)?$/i.test(keys[0] as string)) return 'Esc cancels a recording, so it cannot be the hotkey.';
  if (!isKey(keys[0] as string)) return `"${keys[0]}" is not a key Windows can use here.`;
  const normalized = normalize(text);
  if (normalized === null) return 'Use one key with Ctrl or Alt, like Ctrl+Alt+Space.';
  const modifiers = normalized.split('+').slice(0, -1);
  if (!modifiers.includes('Control') && !modifiers.includes('Alt')) return 'Add Ctrl or Alt, like Ctrl+Alt+Space.';
  if (other.trim().length > 0 && normalize(other) === normalized) {
    return "Dictation and the language picker can't share a hotkey.";
  }
  return null;
}
