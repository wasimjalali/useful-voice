/**
 * Whether the global Esc shortcut should be registered in a dictation state.
 *
 * Cancel is documented to work while transcribing as well as while recording (a hung
 * upload must be abortable), so Esc is held through both. It is released for
 * `delivering`: by then the text is on its way to the app in front, and a global Esc
 * would swallow the key in that app. Registered for the whole session it would swallow
 * Esc everywhere, so idle and error release it too.
 */
export function escapeCancelsIn(state: 'idle' | 'recording' | 'transcribing' | 'delivering' | 'error'): boolean {
  return state === 'recording' || state === 'transcribing';
}
