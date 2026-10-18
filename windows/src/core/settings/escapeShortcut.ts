/**
 * Whether the global Esc shortcut should be registered in a dictation state.
 *
 * Only while recording, matching the macOS build. Registered for the whole session it
 * would swallow Esc in every other app; held through transcription it would let an Esc
 * meant for the app in front discard a dictation that is already finished. A later
 * cancel is the tray's or the window's.
 */
export function escapeCancelsIn(state: 'idle' | 'recording' | 'transcribing' | 'delivering' | 'error'): boolean {
  return state === 'recording';
}
