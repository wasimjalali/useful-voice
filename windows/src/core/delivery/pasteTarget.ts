/**
 * Whether the window a hotkey dictation started in is no longer in front.
 *
 * The text is pasted into the window that was frontmost when recording began. If the
 * user stopped from the dock, Useful Voice is in front by the time the text is ready,
 * and a blind paste would land in the wrong place. In that case the text is copied
 * instead and the user pastes it themselves.
 *
 * `undefined` means the start window was never known (reading it failed), so there is
 * nothing to compare with and the paste proceeds as it always has.
 */
export function pasteTargetMoved(
  startHandle: number | undefined,
  foregroundNow: { handle: number } | null,
): boolean {
  if (startHandle === undefined) return false;
  return foregroundNow === null || foregroundNow.handle !== startHandle;
}
