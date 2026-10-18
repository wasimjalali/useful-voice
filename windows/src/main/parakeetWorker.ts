/**
 * Runs Parakeet recognition inside an Electron utilityProcess so the 600+ MB model never
 * blocks the main process. Started by parakeet.ts; one request at a time, answered in order.
 */
import { createRequire } from 'node:module';
import os from 'node:os';
import path from 'node:path';
import type { ParakeetWorkerRequest, ParakeetWorkerResponse } from '../core/models/parakeetProtocol.js';

interface Port {
  on(event: 'message', listener: (event: { data: unknown }) => void): void;
  postMessage(message: unknown): void;
}

interface Recognizer {
  createStream(): { acceptWaveform(w: { sampleRate: number; samples: Float32Array }): void };
  decode(stream: unknown): void;
  getResult(stream: unknown): { text: string };
}

const loadModule = createRequire(import.meta.url);
const port = (process as unknown as { parentPort?: Port }).parentPort;

let loaded: { dir: string; recognizer: Recognizer } | null = null;

function recognizerFor(dir: string): Recognizer {
  if (loaded?.dir === dir) return loaded.recognizer;
  loaded = null;
  const sherpa = loadModule('sherpa-onnx-node') as {
    OfflineRecognizer: new (config: unknown) => Recognizer;
  };
  const recognizer = new sherpa.OfflineRecognizer({
    featConfig: { sampleRate: 16000, featureDim: 80 },
    modelConfig: {
      transducer: {
        encoder: path.join(dir, 'encoder.int8.onnx'),
        decoder: path.join(dir, 'decoder.int8.onnx'),
        joiner: path.join(dir, 'joiner.int8.onnx'),
      },
      tokens: path.join(dir, 'tokens.txt'),
      numThreads: Math.max(1, Math.min(4, os.cpus().length)),
      provider: 'cpu',
      debug: 0,
      modelType: 'nemo_transducer',
    },
  });
  loaded = { dir, recognizer };
  return recognizer;
}

function handle(request: ParakeetWorkerRequest): ParakeetWorkerResponse {
  try {
    const t0 = Date.now();
    const recognizer = recognizerFor(request.modelDir);
    const t1 = Date.now();
    const stream = recognizer.createStream();
    stream.acceptWaveform({ sampleRate: request.sampleRate, samples: request.samples });
    recognizer.decode(stream);
    const text = recognizer.getResult(stream).text.trim();
    return { id: request.id, ok: true, text, loadMs: t1 - t0, decodeMs: Date.now() - t1 };
  } catch (error) {
    return { id: request.id, ok: false, error: error instanceof Error ? error.message : String(error) };
  }
}

if (port) {
  port.on('message', (event) => {
    port.postMessage(handle(event.data as ParakeetWorkerRequest));
  });
}
