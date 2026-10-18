// Real-model check for the Parakeet engine: downloads the model archive, unpacks it and
// transcribes a WAV through sherpa-onnx-node, the same calls src/main/parakeetWorker.ts makes.
//
//   node scripts/parakeet-check.mjs --wav speech.wav [--version v2|v3] [--cache <dir>]
//
// The WAV must be 16 kHz mono 16-bit PCM (macOS: say -o x.wav --data-format=LEI16@16000 "text").
// The archive and model are kept in --cache (default <tmp>/uv-parakeet-check) so reruns skip them.
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith('--') ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
);
const version = args.version ?? 'v2';
const wavPath = args.wav;
if (!wavPath || !['v2', 'v3'].includes(version)) {
  console.error('usage: node scripts/parakeet-check.mjs --wav speech.wav [--version v2|v3] [--cache dir]');
  process.exit(2);
}
const cache = path.resolve(args.cache ?? path.join(os.tmpdir(), 'uv-parakeet-check'));
const name = `sherpa-onnx-nemo-parakeet-tdt-0.6b-${version}-int8`;
const url = `https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${name}.tar.bz2`;
const modelDir = path.join(cache, name);
const files = ['encoder.int8.onnx', 'decoder.int8.onnx', 'joiner.int8.onnx', 'tokens.txt'];
const have = () => files.every((f) => fs.existsSync(path.join(modelDir, f)));

fs.mkdirSync(cache, { recursive: true });
if (!have()) {
  const archive = path.join(cache, `${name}.tar.bz2`);
  console.log(`downloading ${url}`);
  const t0 = Date.now();
  const res = await fetch(url);
  if (!res.ok || !res.body) throw new Error(`download failed: HTTP ${res.status}`);
  const out = fs.createWriteStream(archive);
  for await (const chunk of res.body) if (!out.write(chunk)) await new Promise((r) => out.once('drain', r));
  await new Promise((r) => out.end(r));
  console.log(`downloaded ${(fs.statSync(archive).size / 1e6).toFixed(0)} MB in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
  const t1 = Date.now();
  const tar = spawnSync('tar', ['-xjf', path.basename(archive)], { cwd: cache, stdio: 'inherit' });
  if (tar.status !== 0) throw new Error(`tar failed (${tar.status})`);
  console.log(`extracted in ${((Date.now() - t1) / 1000).toFixed(1)} s`);
  if (!have()) throw new Error('archive is missing model files');
}

// 16 kHz mono 16-bit PCM -> Float32, walking chunks like parseWavToFloat32.
const bytes = fs.readFileSync(wavPath);
const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
let off = 12;
let samples = null;
while (off + 8 <= bytes.length) {
  const id = bytes.toString('ascii', off, off + 4);
  const size = view.getUint32(off + 4, true);
  if (id === 'fmt ') {
    const ok = view.getUint16(off + 8, true) === 1 && view.getUint16(off + 10, true) === 1 &&
      view.getUint32(off + 12, true) === 16000 && view.getUint16(off + 22, true) === 16;
    if (!ok) throw new Error('WAV must be 16 kHz mono 16-bit PCM');
  } else if (id === 'data') {
    const n = Math.floor(Math.min(size || bytes.length, bytes.length - off - 8) / 2);
    samples = new Float32Array(n);
    for (let i = 0; i < n; i += 1) samples[i] = view.getInt16(off + 8 + i * 2, true) / 32768;
    break;
  }
  off += 8 + size + (size % 2);
}
if (!samples) throw new Error('no audio in WAV');

const sherpa = createRequire(import.meta.url)('sherpa-onnx-node');
const t2 = Date.now();
const recognizer = new sherpa.OfflineRecognizer({
  featConfig: { sampleRate: 16000, featureDim: 80 },
  modelConfig: {
    transducer: {
      encoder: path.join(modelDir, files[0]),
      decoder: path.join(modelDir, files[1]),
      joiner: path.join(modelDir, files[2]),
    },
    tokens: path.join(modelDir, files[3]),
    numThreads: Math.max(1, Math.min(4, os.cpus().length)),
    provider: 'cpu',
    debug: 0,
    modelType: 'nemo_transducer',
  },
});
const loadMs = Date.now() - t2;
const runs = [];
let text = '';
for (let i = 0; i < 3; i += 1) {
  const t = Date.now();
  const stream = recognizer.createStream();
  stream.acceptWaveform({ sampleRate: 16000, samples });
  recognizer.decode(stream);
  text = recognizer.getResult(stream).text.trim();
  runs.push(Date.now() - t);
}
console.log(JSON.stringify({ version, audioSeconds: samples.length / 16000, loadMs, decodeMs: runs, transcript: text }, null, 2));
