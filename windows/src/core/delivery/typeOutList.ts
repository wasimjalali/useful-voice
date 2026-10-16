/**
 * Changing the per-app "type instead of paste" list from Settings.
 *
 * Each switch saves the whole list. Two switches flipped before the first save came
 * back would each save the list as it was, and the second save would drop the first
 * change. The updater runs the saves one at a time, each built from the list the
 * previous one saved.
 */

/** The list with `app` turned on or off, every other entry kept in order. */
export function withTypeOut(list: readonly string[], app: string, on: boolean): string[] {
  const rest = list.filter((id) => id !== app);
  return on ? [...rest, app] : rest;
}

/**
 * A setter for one app's switch. `read` returns the list as last saved; `save` writes
 * a whole list and resolves whether it was saved.
 */
export function serialTypeOutUpdater(
  read: () => readonly string[],
  save: (list: string[]) => Promise<boolean>,
): (app: string, on: boolean) => Promise<boolean> {
  let queue: Promise<unknown> = Promise.resolve();
  return (app, on) => {
    const run = queue.then(() => save(withTypeOut(read(), app, on)));
    // A failed save must not block the next one; its own caller sees the failure.
    queue = run.catch(() => false);
    return run;
  };
}
