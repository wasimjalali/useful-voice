/**
 * Preview flags. A local stand-in until W-shell's version lands: the real one reads the
 * `--preview-features` launch flag the main process exposes. Features without a backend
 * yet (Reprocess, saved recordings) stay hidden unless this returns true.
 */
export function previewFeatures(): boolean {
  return false;
}
