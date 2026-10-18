/**
 * NVIDIA Parakeet TDT 0.6B, run on this PC. v2 is English only, v3 speaks 25 European languages.
 *
 * CONTRACT: the Settings UI, IPC and provider selection are written against these types and
 * channels while the sherpa-onnx implementation (src/main/parakeet.ts) is built separately.
 */
export type ParakeetVersion = 'v2' | 'v3';

export const PARAKEET_VERSIONS: readonly ParakeetVersion[] = ['v2', 'v3'];

export type ParakeetState =
  | { status: 'notDownloaded' }
  /** `progress` runs 0..1, or null while the download can't report it. */
  | { status: 'downloading'; progress: number | null }
  | { status: 'ready'; sizeBytes: number | null }
  | { status: 'failed'; message: string };

export function parakeetCatalogId(version: ParakeetVersion): string {
  return `parakeet:${version}`;
}

export function parakeetVersionFromCatalogId(id: string): ParakeetVersion | null {
  const version = id.startsWith('parakeet:') ? id.slice('parakeet:'.length) : '';
  return (PARAKEET_VERSIONS as readonly string[]).includes(version) ? (version as ParakeetVersion) : null;
}

/** IPC channels between the renderer and main. */
export const PARAKEET_CHANNELS = {
  /** invoke() -> Record<ParakeetVersion, ParakeetState> */
  states: 'parakeet:states',
  /** invoke(version) -> void; starts or resumes a download */
  download: 'parakeet:download',
  /** invoke(version) -> void */
  cancel: 'parakeet:cancel',
  /** invoke(version) -> void */
  remove: 'parakeet:remove',
  /** main -> renderer event with Record<ParakeetVersion, ParakeetState> */
  changed: 'parakeet:changed',
} as const;
