/**
 * Whether the focused element of a page accepts a paste, as a script for
 * `webContents.executeJavaScript`.
 *
 * Used for a dictation that started in one of our own windows and is delivered while one
 * of them is in front: it pastes only when a text field has focus, the same rule as the
 * macOS build. Anything else (a button, the page body, a password box, a read-only or
 * disabled field) means the keystroke would land nowhere useful, and the text is copied.
 *
 * It reads `document.activeElement`, descending into open shadow roots. It runs in the
 * page, so it is a string; tests evaluate it against a fake `document`.
 */
export const EDITABLE_FOCUS_SCRIPT = `(() => {
  let element = document.activeElement;
  while (element && element.shadowRoot && element.shadowRoot.activeElement) element = element.shadowRoot.activeElement;
  if (!element || element === document.body) return false;
  const tag = String(element.tagName || '').toUpperCase();
  if (tag === 'TEXTAREA') return !element.disabled && !element.readOnly;
  if (tag === 'INPUT') {
    const type = String(element.type || 'text').toLowerCase();
    const textual = ['', 'text', 'search', 'email', 'url', 'tel', 'number'];
    return textual.includes(type) && !element.disabled && !element.readOnly;
  }
  return element.isContentEditable === true;
})()`;
