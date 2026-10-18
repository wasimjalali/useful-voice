import { api } from '../api.js';

/**
 * Launch flags from the main process. Loaded once at boot (`await loadFlags()`), then
 * read synchronously.
 *
 * `previewFeatures` is the `--preview-features` command-line flag: it reveals controls
 * whose backend does not exist yet (saved recordings, Reprocess).
 */
let flags = { previewFeatures: false };

export async function loadFlags(): Promise<void> {
  flags = await api.getFlags();
}

export function previewFeatures(): boolean {
  return flags.previewFeatures;
}
