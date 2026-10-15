#!/usr/bin/env node
// Turns an electron-builder Windows build into the files one GitHub release carries:
//
//   Useful-Voice-<v>-x64.exe            NSIS installer (what install.ps1 and the updater fetch)
//   Useful-Voice-<v>-x64.exe.blockmap   lets electron-updater download only what changed
//   Useful-Voice-<v>-portable.exe       portable build (no auto-update)
//   Useful-Voice-Windows-Setup.exe      the same installer under a name that never changes, so
//                                       the site can link releases/latest/download/<name>
//   latest.yml                          electron-updater's feed, read from the newest release
//   install.ps1                         the `irm ... | iex` installer, pinned to this installer's SHA-256
//   SHA256SUMS-windows.txt              `sha256sum -c` format, for anyone checking by hand
//
// Nothing is uploaded. Publishing is attaching these files to the `v<version>` release in
// wasimjalali/useful-voice-releases (docs/distribution.md, "Windows release").
//
// Run after `npx electron-builder --win --publish never` (CI's release-windows workflow
// does both). It refuses, and writes nothing, when:
//   - the version is not plain semver, or the base URL is not HTTPS (127.0.0.1 is allowed
//     for the CI install test)
//   - the installer, its blockmap, the portable exe or latest.yml is missing
//   - latest.yml names another version, another file, another hash or size than the
//     installer on disk (an updater pointed at the wrong file fails on every machine)
//   - a published name has a character GitHub would rewrite on upload (spaces become dots,
//     and latest.yml would then point at a file that does not exist)
//   - install.ps1 is not ASCII, or still has a placeholder after filling
//   - the publish folder already exists
//
// Usage: node scripts/release.mjs [--out release] [--publish release/publish] [--base-url <url>]
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const windowsDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const RELEASES = 'https://github.com/wasimjalali/useful-voice-releases/releases';

const { values } = parseArgs({
  options: {
    out: { type: 'string', default: path.join(windowsDir, 'release') },
    publish: { type: 'string' },
    'base-url': { type: 'string' },
  },
});

function fail(message) {
  process.stderr.write(`release: ${message}\n`);
  process.exit(1);
}

const pkg = JSON.parse(readFileSync(path.join(windowsDir, 'package.json'), 'utf8'));
const version = pkg.version;
if (!/^\d+\.\d+\.\d+$/.test(version)) fail(`package.json version ${version} is not plain semver`);
const productName = pkg.build.productName;

const out = path.resolve(values.out);
const publish = path.resolve(values.publish ?? path.join(out, 'publish'));
const baseUrl = (values['base-url'] ?? `${RELEASES}/download/v${version}`).replace(/\/+$/, '');
if (!(baseUrl.startsWith('https://') || baseUrl.startsWith('http://127.0.0.1:'))) {
  fail(`base URL must be HTTPS: ${baseUrl}`);
}
// A loopback set is for tests only: it must never land where the real set goes.
if (baseUrl.startsWith('http://') && values.publish === undefined) {
  fail('a 127.0.0.1 base URL needs an explicit --publish folder');
}

// electron-builder's names (package.json `artifactName`), and the names GitHub keeps.
const built = {
  installer: `${productName}-${version}-x64.exe`,
  portable: `${productName}-${version}-portable.exe`,
};
const dashed = (name) => name.replace(/ /g, '-');
const names = {
  installer: dashed(built.installer),
  blockmap: `${dashed(built.installer)}.blockmap`,
  portable: dashed(built.portable),
  stableInstaller: 'Useful-Voice-Windows-Setup.exe',
};
for (const name of Object.values(names)) {
  if (!/^[A-Za-z0-9._-]+$/.test(name)) fail(`${name} has a character GitHub rewrites on upload`);
}

const sources = {
  installer: path.join(out, built.installer),
  blockmap: path.join(out, `${built.installer}.blockmap`),
  portable: path.join(out, built.portable),
  latest: path.join(out, 'latest.yml'),
};
for (const file of Object.values(sources)) {
  if (!existsSync(file)) fail(`missing ${file}; run \`npx electron-builder --win --publish never\` first`);
}

const digest = (file, algorithm, encoding) => createHash(algorithm).update(readFileSync(file)).digest(encoding);

// latest.yml as electron-builder writes it: top-level `version`, `path`, `sha512`, and one
// `files` entry. Read with patterns rather than a YAML dependency; anything unexpected fails.
const latest = readFileSync(sources.latest, 'utf8');
const field = (name) => {
  const matches = [...latest.matchAll(new RegExp(`^${name}: (.+)$`, 'gm'))];
  if (matches.length !== 1) fail(`latest.yml has ${matches.length} top-level "${name}" lines, expected 1`);
  return matches[0][1].trim().replace(/^'(.*)'$/, '$1');
};
const fileEntries = [...latest.matchAll(/^ {2}- url: (.+)\n {4}sha512: (.+)\n {4}size: (\d+)$/gm)];
if (fileEntries.length !== 1) fail(`latest.yml lists ${fileEntries.length} files, expected 1`);
const [, entryUrl, entrySha512, entrySize] = fileEntries[0];
const installerSha512 = digest(sources.installer, 'sha512', 'base64');
const installerSize = statSync(sources.installer).size;
const checks = [
  ['version', field('version'), version],
  ['path', field('path'), names.installer],
  ['sha512', field('sha512'), installerSha512],
  ['files[0].url', entryUrl.trim(), names.installer],
  ['files[0].sha512', entrySha512.trim(), installerSha512],
  ['files[0].size', Number(entrySize), installerSize],
];
for (const [key, got, want] of checks) {
  if (got !== want) fail(`latest.yml ${key} is ${got}, expected ${want}`);
}

const installerSha256 = digest(sources.installer, 'sha256', 'hex');
const template = readFileSync(path.join(windowsDir, 'scripts', 'install.ps1'), 'utf8');
if (!/^[\x09\x0a\x0d\x20-\x7e]*$/.test(template)) fail('scripts/install.ps1 has a non-ASCII character');
const installScript = template
  .replace("'@@VERSION@@'", `'${version}'`)
  .replace("'@@INSTALLER_URL@@'", `'${baseUrl}/${names.installer}'`)
  .replace("'@@INSTALLER_SHA256@@'", `'${installerSha256}'`);
if (/@@[A-Z_]+@@/.test(installScript)) fail('install.ps1 still has a placeholder after filling');

if (existsSync(publish)) fail(`${publish} already exists; remove it and run again`);
mkdirSync(publish, { recursive: true });
copyFileSync(sources.installer, path.join(publish, names.installer));
copyFileSync(sources.blockmap, path.join(publish, names.blockmap));
copyFileSync(sources.portable, path.join(publish, names.portable));
copyFileSync(sources.installer, path.join(publish, names.stableInstaller));
copyFileSync(sources.latest, path.join(publish, 'latest.yml'));
writeFileSync(path.join(publish, 'install.ps1'), installScript);

const summed = [names.installer, names.stableInstaller, names.portable, 'install.ps1', 'latest.yml'];
const sums = summed.map((name) => `${digest(path.join(publish, name), 'sha256', 'hex')}  ${name}`);
writeFileSync(path.join(publish, 'SHA256SUMS-windows.txt'), `${sums.join('\n')}\n`);

process.stdout.write(
  `${JSON.stringify({
    version,
    tag: `v${version}`,
    publish,
    installer: names.installer,
    installerSha256,
    installerBytes: installerSize,
    portable: names.portable,
    portableSha256: digest(path.join(publish, names.portable), 'sha256', 'hex'),
    installUrl: `${baseUrl}/install.ps1`,
  })}\n`,
);
