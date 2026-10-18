/**
 * Whether a hotkey dictation should be copied instead of pasted.
 *
 * The text is pasted wherever the cursor is when it is ready, even if the user moved to
 * another field or window while it was transcribing. The one exception: one of Useful
 * Voice's own windows came to the front after the dictation started elsewhere (stopped
 * from the dock), where a paste would land nowhere useful, so it is copied instead.
 * A dictation started in our own window (a note) still pastes there.
 *
 * A foreground window that could not be read (`null`) pastes as it always has.
 */
export function pasteLandsInOwnWindow(
  startHandle: number | undefined,
  foregroundNow: { handle: number } | null,
  ownHandles: readonly number[],
): boolean {
  if (foregroundNow === null || !ownHandles.includes(foregroundNow.handle)) return false;
  return startHandle === undefined || !ownHandles.includes(startHandle);
}
