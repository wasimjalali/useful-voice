/**
 * Saving the Apps group's settings one at a time.
 *
 * Each control saves a whole map (styles, send keys, app categories) built from the
 * settings as last saved. Two picks made before the first save came back would each
 * be built from the old map, and the second save would undo the first. The saver builds
 * each patch only when its turn comes, from what the previous save stored.
 */

/**
 * `save` writes one patch and resolves whether it was saved. The returned function takes
 * a builder, queues it and resolves with that save's result.
 */
export function serialSaver<Patch>(
  save: (patch: Patch) => Promise<boolean>,
): (build: () => Patch) => Promise<boolean> {
  let queue: Promise<unknown> = Promise.resolve();
  return (build) => {
    const run = queue.then(() => save(build()));
    // A failed save must not block the next one; its own caller sees the failure.
    queue = run.catch(() => false);
    return run;
  };
}
