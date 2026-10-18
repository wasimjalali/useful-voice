/**
 * Whether a hotkey dictation should be copied instead of pasted.
 *
 * The text is pasted wherever the cursor is when it is ready, even if the user moved to
 * another field or window while it was transcribing. The one exception: one of Useful
 * Voice's own windows came to the front after the dictation started elsewhere (stopped
 * from the dock), where a paste would land nowhere useful, so it is copied instead.
 * A dictation started in our own window (a note) still pastes there.
 *
 * Both facts are synchronous reads (`BrowserWindow.getFocusedWindow() !== null`), so
 * neither the start nor the delivery waits on a query to Windows for them.
 */
export function pasteLandsInOwnWindow(startedInOwnWindow: boolean, ownWindowInFront: boolean): boolean {
  return ownWindowInFront && !startedInOwnWindow;
}
