/** Messages between the main process and the Parakeet utility process. */
export interface ParakeetWorkerRequest {
  id: number;
  /** Folder holding encoder/decoder/joiner/tokens. */
  modelDir: string;
  samples: Float32Array;
  sampleRate: number;
}

export type ParakeetWorkerResponse =
  | { id: number; ok: true; text: string; loadMs: number; decodeMs: number }
  | { id: number; ok: false; error: string };
