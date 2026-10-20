#!/usr/bin/env node
/**
 * Render the start/stop sound cues to dist/cues/<kind>.wav at build time.
 *
 * Rendering takes a few milliseconds of synchronous work. Done in the main process on the
 * first recording, it ran while the e2e driver's evaluate calls were in flight and they
 * failed ("Resulting promise was garbage collected"), so the app only copies these files.
 * Runs after `tsc -p tsconfig.main.json`, which builds the synth it imports.
 */

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const { chimeWav } = await import(pathToFileURL(path.join(root, 'dist', 'core', 'audio', 'chimeSynth.js')).href);
const out = path.join(root, 'dist', 'cues');
await fs.mkdir(out, { recursive: true });
for (const kind of ['start', 'stop']) {
  const wav = chimeWav(kind);
  await fs.writeFile(path.join(out, `${kind}.wav`), wav);
  console.log(`cue ${kind} -> dist/cues/${kind}.wav (${wav.length} bytes)`);
}
