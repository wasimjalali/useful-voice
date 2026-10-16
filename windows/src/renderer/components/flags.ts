import { api } from '../api.js';

/**
 * Launch flags from the main process. Loaded once at boot (`await loadFlags()`), then
 * read synchronously.
 *
 * `previewFeatures` is the `--preview-features` command-line flag: it reveals controls
 * whose backend does not exist yet (saved recordings, Reprocess).
 *
 * `cleanupModel` is the hidden S1-mini flag (`--cleanup-model`): it only decides whether
 * Settings credits the model.
 */
let flags = { previewFeatures: false, cleanupModel: false };

export async function loadFlags(): Promise<void> {
  flags = await api.getFlags();
}

export function previewFeatures(): boolean {
  return flags.previewFeatures;
}

export function cleanupModelOn(): boolean {
  return flags.cleanupModel;
}
