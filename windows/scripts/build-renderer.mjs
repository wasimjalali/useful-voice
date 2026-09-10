#!/usr/bin/env node
/**
 * Build the renderer and preload bundles with esbuild.
 *
 * Two targets, deliberately built differently:
 *
 *   * **renderer** — an ES module, loaded by Chromium via `<script type="module">`.
 *     The page is a `file://` URL under a strict CSP, so everything must be inlined
 *     into one file; Chromium cannot resolve bare specifiers or npm packages.
 *
 *   * **preload** — CommonJS, *not* ESM. Electron's preload loader **ignores the
 *     `"type": "module"` field** in package.json, so a `.js` preload is evaluated as
 *     CommonJS regardless, and an ESM preload must carry the `.mjs` extension. Since
 *     tsc emits `.js`, a plain compiled preload would be parsed as CommonJS while
 *     containing `import` statements, fail to load, and leave `window.usefulVoice`
 *     undefined — a dead UI with no visible cause. Bundling as CommonJS sidesteps
 *     the extension rule entirely, which is what Electron's docs recommend.
 */

import { build } from 'esbuild';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const rendererSrc = path.join(root, 'src', 'renderer');
const rendererOut = path.join(root, 'dist', 'renderer');
const preloadOut = path.join(root, 'dist', 'preload');

async function buildRenderer() {
  await fs.mkdir(rendererOut, { recursive: true });

  await build({
    entryPoints: [path.join(rendererSrc, 'renderer.ts')],
    outfile: path.join(rendererOut, 'renderer.js'),
    bundle: true,
    // Electron 33 ships Chromium 130; targeting it keeps the output small.
    target: 'chrome130',
    format: 'esm',
    platform: 'browser',
    sourcemap: true,
    minify: false,
    logLevel: 'warning',
  });

  const contents = await fs.readFile(path.join(rendererOut, 'renderer.js'), 'utf8');
  // A dynamic import cannot be resolved from a file:// page under the app CSP, so
  // its presence would mean a silently broken bundle.
  const dynamic = contents.match(/\bimport\s*\(/g);
  if (dynamic && dynamic.length > 0) {
    throw new Error(
      `renderer bundle contains ${dynamic.length} dynamic import(s), which cannot `
      + 'be resolved from a file:// page under the app CSP.',
    );
  }

  await fs.copyFile(path.join(rendererSrc, 'styles.css'), path.join(rendererOut, 'styles.css'));
  await fs.copyFile(path.join(rendererSrc, 'index.html'), path.join(rendererOut, 'index.html'));
  await assertPresent('renderer assets', rendererOut, ['renderer.js', 'styles.css', 'index.html']);

  console.log(`renderer  -> dist/renderer  (${describe(contents.length)})`);
}

async function buildPreload() {
  await fs.mkdir(preloadOut, { recursive: true });

  await build({
    entryPoints: [path.join(root, 'src', 'preload', 'index.ts')],
    outfile: path.join(preloadOut, 'index.js'),
    bundle: true,
    target: 'node20',
    // CommonJS on purpose: see the note at the top of this file.
    format: 'cjs',
    platform: 'node',
    // Provided by the runtime; bundling it would break the preload.
    external: ['electron'],
    sourcemap: true,
    minify: false,
    logLevel: 'warning',
  });

  const contents = await fs.readFile(path.join(preloadOut, 'index.js'), 'utf8');
  // Guard against a future edit switching the preload to ESM, which would fail at
  // run time as a dead UI rather than an error anyone can see.
  if (/^\s*import\s/m.test(contents) || /^\s*export\s/m.test(contents)) {
    throw new Error('preload bundle contains ESM syntax but Electron requires CommonJS here.');
  }
  if (!contents.includes('contextBridge')) {
    throw new Error('preload bundle does not reference contextBridge; the API would not be exposed.');
  }
  await assertPresent('preload bundle', preloadOut, ['index.js']);

  console.log(`preload   -> dist/preload   (${describe(contents.length)})`);
}

/**
 * The main process output must exist, or the app cannot start at all.
 *
 * `package.json` `main` and `build.extraMetadata.main` are checked against the
 * real emitted file: a mismatch between them and tsc's output path produces a
 * build that looks fine and an app that opens no window at all.
 */
async function verifyMain() {
  await assertPresent('main process output', path.join(root, 'dist'), ['main/index.js']);
  await assertPresent('core modules', path.join(root, 'dist'), ['core/models.js']);

  const pkg = JSON.parse(await fs.readFile(path.join(root, 'package.json'), 'utf8'));
  const declared = pkg.main;
  const packaged = pkg.build?.extraMetadata?.main ?? declared;
  for (const [label, entry] of [['package.json main', declared], ['extraMetadata.main', packaged]]) {
    if (entry !== 'dist/main/index.js') {
      throw new Error(
        `${label} is "${entry}" but the main process is emitted at `
        + '"dist/main/index.js". Electron would fail to find the app.',
      );
    }
  }
}

async function assertPresent(label, directory, names) {
  for (const name of names) {
    try {
      await fs.access(path.join(directory, name));
    } catch {
      throw new Error(`${label} missing: ${path.relative(root, path.join(directory, name))}`);
    }
  }
}

function describe(bytes) {
  return `${(bytes / 1024).toFixed(1)} kB`;
}

async function main() {
  await verifyMain();
  // `clean` guarantees the preload in dist is the bundle this script produced.
  // tsc (tsconfig.main.json) deliberately excludes src/preload so that the two
  // builds can never fight over the same output path.
  await clean(path.join(preloadOut, 'index.js'));
  await buildPreload();
  await buildRenderer();
  console.log('build complete');
}

/** Remove a stale artefact so a failed build cannot masquerade as a good one. */
async function clean(file) {
  await fs.rm(file, { force: true });
  await fs.rm(`${file}.map`, { force: true });
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
