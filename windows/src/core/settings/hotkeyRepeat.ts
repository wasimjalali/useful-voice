/**
 * Held-key protection for the dictation hotkey.
 *
 * `globalShortcut` on Windows can fire repeatedly while the accelerator is held, and
 * each event toggles dictation: a held key would start, stop and start again. Events
 * that arrive within `HOTKEY_REPEAT_WINDOW_MS` of the PREVIOUS event are ignored, and
 * an ignored event still counts as the previous one. The window therefore slides, so a
 * key that stays down never re-toggles, however long it is held.
 *
 * The window must be longer than Windows' default keyboard repeat delay of 500 ms: a shorter
 * one lets the first auto-repeat through as a second toggle. It stays short enough that a
 * real stop press about 0.7 s after the start still works. The 750 ms and 1 s repeat-delay
 * settings let one repeat through; that is the price of the shorter window.
 */
export const HOTKEY_REPEAT_WINDOW_MS = 600;

/**
 * Whether a hotkey event at `now` should act.
 *
 * `previousEventAt` is the time of the last hotkey event, accepted or ignored, or null
 * before the first. A clock that went backwards is treated as a repeat, never as a new
 * press, since ignoring one real press costs less than toggling twice.
 */
export function acceptsHotkeyEvent(
  previousEventAt: number | null,
  now: number,
  windowMs: number = HOTKEY_REPEAT_WINDOW_MS,
): boolean {
  if (previousEventAt === null) return true;
  return now - previousEventAt >= windowMs;
}

/** A stateful guard: call it for every hotkey event, act only when it returns true. */
export function createHotkeyRepeatGuard(
  now: () => number = () => Date.now(),
  windowMs: number = HOTKEY_REPEAT_WINDOW_MS,
): () => boolean {
  let previousEventAt: number | null = null;
  return () => {
    const at = now();
    const accepted = acceptsHotkeyEvent(previousEventAt, at, windowMs);
    previousEventAt = at;
    return accepted;
  };
}
