/**
 * Whether the dictation hotkey, pressed while Useful Voice is in front, has a field of
 * ours to type into.
 *
 * The page reports what has focus (`FOCUSED_FIELD_PROBE`) and this decides. Anything
 * unclear is "no", and a password field is never a yes.
 */

/** What the page tells main about its focused element. */
export interface FocusedFieldInfo {
  tag: string;
  type: string;
  contentEditable: boolean;
  readOnly: boolean;
  disabled: boolean;
}

/** An expression for `executeJavaScript` in our own page. Reads only; returns a plain object or null. */
export const FOCUSED_FIELD_PROBE = `(() => {
  const e = document.activeElement;
  if (!e) return null;
  return {
    tag: String(e.tagName || ''),
    type: typeof e.type === 'string' ? e.type : '',
    contentEditable: e.isContentEditable === true,
    readOnly: e.readOnly === true,
    disabled: e.disabled === true,
  };
})()`;

/** How long main waits for the page to answer. No answer is "no". */
export const OWN_FIELD_TIMEOUT_MS = 300;

const TEXT_INPUT_TYPES: ReadonlySet<string> = new Set(['', 'text', 'search', 'url', 'email', 'tel', 'number']);

/** Whether `info` is a field that takes typed text: an input, a textarea or a contenteditable element. */
export function isEditableField(info: unknown): boolean {
  if (typeof info !== 'object' || info === null) return false;
  const field = info as Partial<FocusedFieldInfo>;
  if (field.disabled === true || field.readOnly === true) return false;
  const tag = typeof field.tag === 'string' ? field.tag.toLowerCase() : '';
  const type = typeof field.type === 'string' ? field.type.toLowerCase() : '';
  if (tag === 'input') return TEXT_INPUT_TYPES.has(type);
  if (tag === 'textarea') return type !== 'password';
  return field.contentEditable === true;
}
