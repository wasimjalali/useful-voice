import type { ParakeetState, ParakeetVersion } from '../core/models/parakeet.js';
import type { Transcript } from '../core/transcription/deepgramProvider.js';
import { ProviderError } from '../core/transcription/deepgramProvider.js';

/**
 * Downloads, deletes and runs the Parakeet models in the main process.
 *
 * CONTRACT STUB: index.ts (IPC handlers, provider selection) is written against this class
 * while the sherpa-onnx implementation is built separately. Keep these signatures.
 */
export class ParakeetModels {
  private readonly listeners = new Set<(states: Record<ParakeetVersion, ParakeetState>) => void>();

  /** `dataDir` is the app's data folder; models live in `<dataDir>/models/parakeet-<version>/`. */
  constructor(readonly dataDir: string) {}

  states(): Record<ParakeetVersion, ParakeetState> {
    return { v2: { status: 'notDownloaded' }, v3: { status: 'notDownloaded' } };
  }

  /** Called with every state change (download progress included). Returns an unsubscribe. */
  onChange(listener: (states: Record<ParakeetVersion, ParakeetState>) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  async download(_version: ParakeetVersion): Promise<void> {}

  cancel(_version: ParakeetVersion): void {}

  async remove(_version: ParakeetVersion): Promise<void> {}

  /**
   * Transcribe a 16 kHz mono 16-bit WAV. Throws ProviderError('notConfigured') when the model
   * isn't downloaded. Honors `signal`.
   */
  async transcribe(_wav: Uint8Array, _version: ParakeetVersion, _signal?: AbortSignal): Promise<Transcript> {
    throw new ProviderError('notConfigured', 'Parakeet is not downloaded. Download it in Settings to use it.');
  }

  /** Stop any worker process and downloads. Called at quit. */
  dispose(): void {}
}
