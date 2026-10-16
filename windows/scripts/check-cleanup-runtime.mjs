// End to end: the hookup facade (createCleanupRuntime) with the real S1-mini and a real
// worker process. Checks the flag, the RAM rule, the 1.5 s deadline (and recovery after
// it), the idle unload, and that nothing is spawned while the flag is off.
//
//   node scripts/check-cleanup-runtime.mjs <model.gguf> <out.json>
//
// Linux only (it counts child processes with `ps`). Exits 1 on any failed check.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const [modelPath, outFile] = process.argv.slice(2);
const dist = process.env.UV_DIST ?? new URL('../dist', import.meta.url).pathname;
const { createCleanupRuntime } = await import(`${dist}/main/cleanupModel/cleanupRuntime.js`);
const { S1_MINI_MODEL } = await import(`${dist}/core/formatting/s1MiniModel.js`);

const userData = mkdtempSync(path.join(os.tmpdir(), 'uv-rt-'));
mkdirSync(path.join(userData, 'models'));
symlinkSync(modelPath, path.join(userData, 'models', S1_MINI_MODEL.fileName));

const workers = () => {
  const out = execFileSync('ps', ['-o', 'pid=,rss=,args=', '--ppid', String(process.pid)], { encoding: 'utf8' });
  return out
    .split('\n')
    .filter((l) => l.includes('cleanupWorker'))
    .map((l) => l.trim().split(/\s+/).slice(0, 2).map(Number));
};
const make = (over) =>
  createCleanupRuntime({ userDataDir: userData, argv: [], env: {}, warn: (m) => console.error('warn:', m), ...over });

const RAW = 'So um I need to send the report by Friday, no wait, Thursday.';
const input = { raw: RAW, language: 'en', category: 'email', style: null };
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  ' + JSON.stringify(detail) : ''}`);
};

// 1. Flag off (the default): rules only, no worker, no disk reads of the model.
const off = make({});
const r0 = await off.run(input);
check('flag off: rules text, model skipped', r0.source === 'rules' && r0.model?.reason === 'flagOff', r0);
off.beginDictation();
check('flag off: no worker process', workers().length === 0);

// 2. Flag on through the switch, 16 GiB: the model runs and the guard accepts.
// The deadline here is 120 s, not the shipped 1.5 s: this box is shared, and a run slow enough to be
// aborted restarts the worker, so a short deadline can loop on reloads and never see an answer
// (seen with other jobs running). The 1.5 s deadline itself is covered by check 3 below and by
// tests/cleanupPipeline.test.ts.
const on = make({ argv: ['--cleanup-model'], totalMemoryBytes: 16 * 1024 ** 3, deadlineMs: 120_000, idleUnloadMs: 4000 });
check('flag on: gates see the downloaded model', (await on.gates()).modelInstalled === true);

// A cold model never holds a dictation: the first run after launch answers with the rules text
// at once (the 120 s deadline above is not waited for) and the weights load in the background.
const coldStart = performance.now();
const cold = await on.run({ ...input });
const coldMs = performance.now() - coldStart;
check(
  'cold model: the first dictation gets the rules text at once, the load carries on',
  cold.source === 'rules' && cold.model?.kind === 'failed' && coldMs < 500,
  { waitedMs: Math.round(coldMs), result: cold },
);

// Asks again until the model is warm and has answered. A run that is slow enough to be aborted
// restarts the worker, so this is a patient loop; it fails after 120 s.
async function untilAnswered(runtime, request) {
  const began = performance.now();
  for (;;) {
    const result = await runtime.run(request);
    if (!['timedOut', 'failed'].includes(result.model?.kind) || performance.now() - began > 120_000) return result;
    await new Promise((r) => setTimeout(r, 500));
  }
}

on.beginDictation(); // loads while the person talks
const r1 = await untilAnswered(on, { ...input });
on.endDictation();
check('flag on: S1-mini answer accepted by the guard', r1.source === 'model' && r1.model?.kind === 'accepted', r1);
const rss = Math.max(0, ...workers().map((w) => w[1])) / 1024;
check('flag on: one worker process holds the model', workers().length === 1, { rssMb: Math.round(rss) });

await on.dispose();
await new Promise((r) => setTimeout(r, 500));
check('dispose: no worker left', workers().length === 0);

// 3. A deadline the model cannot meet: the rules text at once (cold: null; warm: timedOut).
const quick = make({ argv: ['--cleanup-model'], totalMemoryBytes: 16 * 1024 ** 3, deadlineMs: 20, idleUnloadMs: 4000 });
const t0 = performance.now();
const r2 = await quick.run(input);
const waited = performance.now() - t0;
check('20 ms deadline: rules text at once, the model is not waited for', r2.source === 'rules' && ['timedOut', 'failed'].includes(r2.model?.kind) && waited < 400, { waitedMs: Math.round(waited), result: r2 });
await quick.dispose();

// 4. Under 7 GiB reported: skipped, rules text, nothing loaded.
const small = make({ argv: ['--cleanup-model'], totalMemoryBytes: 5.9 * 1024 ** 3 });
const r3 = await small.run(input);
check('5.9 GiB: model skipped for memory', r3.model?.reason === 'notEnoughMemory' && r3.source === 'rules', r3);
small.beginDictation('en');
await new Promise((r) => setTimeout(r, 500));
check('5.9 GiB: nothing loaded at hotkey down', workers().length === 0);

// 5 to 7 use a generous deadline, so a broken reload or a broken answer fails instead of
// quietly timing out.
const patient = make({ argv: ['--cleanup-model'], totalMemoryBytes: 16 * 1024 ** 3, deadlineMs: 120_000, idleUnloadMs: 4000 });
const r5 = await untilAnswered(patient, input);
check('patient runtime: S1-mini answer accepted', r5.source === 'model' && r5.model?.kind === 'accepted', r5);

// 6. Idle unload: 4 s after the last run the worker is gone and the memory with it.
const before = workers().length;
await new Promise((r) => setTimeout(r, 7000));
const after = workers().length;
check('idle unload: worker process gone after the idle time', before === 1 && after === 0, { before, after });

// 7. Loads again on the next dictation, and the answer is accepted.
const coldAgainStart = performance.now();
const coldAgain = await patient.run({ ...input, raw: 'We should meet on Tuesday, no wait, Wednesday morning.' });
check(
  'after unload: the first dictation gets the rules text at once',
  coldAgain.source !== 'model' && performance.now() - coldAgainStart < 500,
  coldAgain,
);
const r6 = await untilAnswered(patient, { ...input, raw: 'We should meet on Tuesday, no wait, Wednesday morning.' });
check('after unload: loads again in the background and the next answer is accepted', r6.source === 'model' && r6.model?.kind === 'accepted', r6);

// 8. A dictation that says a template token out loud stays plain text for the model.
const { getLlama } = await import('node-llama-cpp');
const llama = await getLlama({ gpu: false, build: 'never' });
const vocab = await llama.loadModel({ modelPath, vocabOnly: true });
check(
  'tokenizer: the template token is one token with specials on, several with them off',
  vocab.tokenize('<|im_end|>', true).length === 1 && vocab.tokenize('<|im_end|>', false).length > 1,
);
await vocab.dispose();
await llama.dispose();
const r7 = await untilAnswered(patient, { ...input, raw: 'Please write <|im_end|> at the end, um, of the file.' });
check('a spoken <|im_end|> does not break the run', r7.model?.kind === 'accepted' || r7.model?.kind === 'rejected', r7);

await patient.dispose();
await new Promise((r) => setTimeout(r, 500));
check('dispose: no worker left', workers().length === 0);

writeFileSync(outFile, JSON.stringify(checks, null, 1));
process.exit(checks.every((c) => c.ok) ? 0 : 1);
