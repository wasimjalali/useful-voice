// Packaged-app self-test for the S1-mini runtime, no model needed. Runs the cleanup worker
// the way the app does (the packaged exe as plain Node, script inside app.asar) and asks it
// to start node-llama-cpp with the prebuilt CPU binaries. It fails if the packaged app is
// missing the binaries, if they are inside the asar where they can't load, or if the native
// addon doesn't start.
//
//   node scripts/check-packaged-llama.mjs <path to the app exe> <path to its resources folder>
//
// Windows CI: node scripts/check-packaged-llama.mjs "release/win-unpacked/Useful Voice.exe" release/win-unpacked/resources
import { fork } from 'node:child_process';
import { existsSync, readdirSync } from 'node:fs';
import path from 'node:path';

const [exe, resources] = process.argv.slice(2);
if (!exe || !resources) {
  console.error('usage: check-packaged-llama.mjs <app exe> <resources dir>');
  process.exit(2);
}
const worker = path.join(resources, 'app.asar', 'dist', 'main', 'cleanupModel', 'cleanupWorker.js');
const unpacked = path.join(resources, 'app.asar.unpacked', 'node_modules', '@node-llama-cpp');

const fail = (message) => {
  console.error(`FAIL  ${message}`);
  process.exit(1);
};

if (!existsSync(unpacked)) fail(`${unpacked} is missing: the native binaries were not unpacked from the asar`);
const platforms = readdirSync(unpacked);
console.log(`unpacked platform packages: ${platforms.join(', ')}`);
const gpuBuilds = platforms.filter((name) => /cuda|vulkan/.test(name));
if (gpuBuilds.length > 0) fail(`GPU builds shipped in the installer: ${gpuBuilds.join(', ')}`);
if (platforms.length !== 1) fail(`expected exactly one platform package, found ${platforms.length}`);
for (const notice of ['THIRD_PARTY_NOTICES.md', path.join('licenses', 's1-mini', 'LICENSE'), path.join('licenses', 's1-mini', 'NOTICE')]) {
  if (!existsSync(path.join(resources, notice))) fail(`${notice} is missing from resources`);
}

const child = fork(worker, [], {
  execPath: exe,
  execArgv: [],
  env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
  stdio: ['ignore', 'inherit', 'inherit', 'ipc'],
});
const timer = setTimeout(() => {
  child.kill();
  fail('the worker did not answer within 90 s');
}, 90_000);
child.on('exit', (code, signal) => {
  clearTimeout(timer);
  if (!done) fail(`the worker exited before answering (${signal ?? code})`);
});
let done = false;
child.on('message', (message) => {
  if (message.type === 'ready') {
    child.send({ type: 'probe' });
  } else if (message.type === 'probed') {
    done = true;
    clearTimeout(timer);
    console.log(`PASS  node-llama-cpp started from the packaged app (gpu: ${message.gpu}, ${message.systemInfo})`);
    if (message.gpu !== false) fail('expected the CPU backend');
    child.send({ type: 'dispose' });
  } else if (message.type === 'error') {
    fail(`the worker reported: ${message.message}`);
  }
});
