// Runs the real S1-mini through the shipped Windows runtime (child process, node-llama-cpp)
// and compares it with the eval's raw llama-server outputs. Linux or Windows.
//
//   node scripts/check-cleanup-model.mjs <model.gguf> <cases.json> <eval-raw.json> <out.json> [limit]
//
// <eval-raw.json> is one of evals/results/raw/2026-10-16-cleanup-r4-linux-*.json. For every
// case it sends the same rules-cleaned text and control line the eval sent and counts how
// many answers match the llama-server answer byte for byte. It also reports the latency of
// each answer, the worker's peak resident memory and the load time.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
// UV_DIST points at another build, for example <app>/resources/app.asar/dist of a packaged
// app run as `ELECTRON_RUN_AS_NODE=1 <app exe> scripts/check-cleanup-model.mjs ...`.
const dist = process.env.UV_DIST ?? new URL('../dist', import.meta.url).pathname;
const { LlamaCleanupGenerator } = await import(`${dist}/main/cleanupModel/llamaGenerator.js`);
const { LocalCleanupModel } = await import(`${dist}/core/formatting/localCleanupModel.js`);
const { s1ControlLine } = await import(`${dist}/core/formatting/cleanupControlLine.js`);

const [modelPath, casesFile, rawFile, outFile, limitArg] = process.argv.slice(2);
const cases = JSON.parse(readFileSync(casesFile, 'utf8'));
const raw = JSON.parse(readFileSync(rawFile, 'utf8')).raw;
const evalRows = new Map(raw.runs['rules+s1'].map((row) => [row.id, row]));
const limit = Number(limitArg ?? cases.length);

function workerRssMb() {
  try {
    const out = execFileSync('ps', ['-o', 'rss=', '--ppid', String(process.pid)], { encoding: 'utf8' });
    return Math.max(0, ...out.split('\n').map((l) => Number(l.trim()) || 0)) / 1024;
  } catch {
    return null;
  }
}

const generator = new LlamaCleanupGenerator({
  workerScript: `${dist}/main/cleanupModel/cleanupWorker.js`,
  warn: (m) => console.error('warn:', m),
});
const model = new LocalCleanupModel({ modelPath, generator, warn: (m) => console.error('warn:', m) });

const t0 = performance.now();
await model.begin();
const loadMs = performance.now() - t0;
const rssAfterLoad = workerRssMb();

const rows = [];
let peak = rssAfterLoad ?? 0;
for (const c of cases.slice(0, limit)) {
  const ev = evalRows.get(c.id);
  if (!ev) continue;
  const controlLine = s1ControlLine(c.app, null);
  const started = performance.now();
  const output = await model.clean(ev.model_input, controlLine, started + 60_000);
  const ms = performance.now() - started;
  peak = Math.max(peak, workerRssMb() ?? 0);
  rows.push({ id: c.id, ms: Math.round(ms), match: output === ev.output, output, evalOutput: ev.output });
}
await model.unload();

const lat = rows.map((r) => r.ms).sort((a, b) => a - b);
const q = (p) => lat[Math.min(lat.length - 1, Math.floor(p * lat.length))];
const summary = {
  cases: rows.length,
  identicalToEval: rows.filter((r) => r.match).length,
  loadMs: Math.round(loadMs),
  rssAfterLoadMb: rssAfterLoad && Math.round(rssAfterLoad),
  peakRssMb: Math.round(peak),
  latencyMs: { median: q(0.5), p95: q(0.95), max: lat.at(-1), over1500: lat.filter((v) => v > 1500).length },
};
console.log(JSON.stringify(summary, null, 2));
writeFileSync(outFile, JSON.stringify({ summary, rows }, null, 1));
