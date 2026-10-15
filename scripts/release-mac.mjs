#!/usr/bin/env node
// Builds a release of the macOS app: the app signed with the "Useful Voice
// Release" certificate, a zip signed for Sparkle, the one-item appcast that
// points at it, a DMG with the drag-to-Applications window for browser
// downloads, the curl installer and a release notes draft, all in dist/release.
// Ported from Useful Bot (scripts/release-mac.mjs). Plain Node, no npm packages.
//
//   node scripts/release-mac.mjs --version 1.0.0 [--feed-url URL] [--download-base URL] [--out DIR] [--allow-dirty]
//
// A test machine without the real keys builds with --ad-hoc and its own update
// key (--ed-account or --ed-key-file, and --ed-public-key, from its
// `generate_keys`; CI uses a key file, since reading another tool's Keychain
// item waits on a prompt nobody can answer there). Those builds
// can never update a real install: the app only trusts ED_PUBLIC_KEY, and an
// ad hoc signature loses the user's Accessibility and Microphone grants.
//
// Nothing is uploaded. Publishing is putting the zip, the DMG, appcast.xml and
// install.sh where --download-base and --feed-url say (docs/distribution.md).
import { execFileSync, spawnSync } from "node:child_process";
import { createHash, createPrivateKey, createPublicKey } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const RELEASES = "https://github.com/wasimjalali/useful-voice-releases/releases";
const SOURCE = "https://github.com/wasimjalali/usefulvoice";
// The public half of the update signing key. The private half lives only in
// the release Mac's Keychain (account "useful-voice") and the password manager.
// Empty until the owner makes the key (docs/distribution.md, "The update key"):
// no release can be built before then.
const ED_PUBLIC_KEY = "";
const ED_ACCOUNT = "useful-voice";
// UV-004: every release is signed with this one self-signed certificate, so the
// designated requirement stays the same across updates and macOS keeps the
// Accessibility and Microphone grants. Never re-create it.
const SIGN_IDENTITY = "Useful Voice Release";
const DESIGNATED = 'identifier "ai.useful.voice" and certificate root = H"0911ad559e52d79005ea0a35d43219b546e7cf83"';
const APP_NAME = "Useful Voice.app";
const ZIP = "Useful-Voice-macOS.zip";
const DMG = "Useful-Voice-macOS.dmg";
const NOTES = "release-notes.md";
const BUILT_APP = path.join(ROOT, "dist/UsefulVoice.app");
const SPARKLE_BIN = path.join(ROOT, ".build/artifacts/sparkle/Sparkle/bin");
// dmgbuild writes the DMG window's .DS_Store itself, so no Finder scripting.
// It lives in a venv under .build, never in the system Python.
const DMG_PACKAGES = ["dmgbuild==1.6.7", "ds_store==1.3.3", "mac_alias==2.2.3"];
const VOLUME = "Useful Voice";
const DMG_VENV = path.join(ROOT, ".build/dmg-venv");

const { values } = parseArgs({
  options: {
    version: { type: "string" },
    "feed-url": { type: "string", default: `${RELEASES}/latest/download/appcast.xml` },
    "download-base": { type: "string" },
    out: { type: "string", default: path.join(ROOT, "dist/release") },
    "allow-dirty": { type: "boolean", default: false },
    "ed-account": { type: "string", default: ED_ACCOUNT },
    "ed-key-file": { type: "string" },
    "ed-public-key": { type: "string", default: ED_PUBLIC_KEY },
    "ad-hoc": { type: "boolean", default: false },
  },
});
// Tools write their progress to stderr, so stdout carries only the summary JSON.
const TO_STDERR = ["ignore", 2, 2];
const fail = (message) => {
  process.stderr.write(`${message}\n`);
  process.exit(1);
};
const version = values.version;
if (!version || !/^\d+\.\d+\.\d+$/.test(version)) {
  process.stderr.write("usage: release-mac.mjs --version X.Y.Z [--feed-url URL] [--download-base URL] [--out DIR] [--allow-dirty] [--ad-hoc (--ed-account NAME | --ed-key-file FILE) --ed-public-key KEY]\n");
  process.exit(2);
}
const adHoc = values["ad-hoc"];
const edAccount = values["ed-account"];
const edKeyFile = values["ed-key-file"] && path.resolve(values["ed-key-file"]);
// How sign_update finds the private key.
const keySource = edKeyFile ? ["--ed-key-file", edKeyFile] : ["--account", edAccount];
const edPublicKey = values["ed-public-key"];
if (adHoc) {
  // An ad hoc build must not look like a real one: it may not use the real key.
  if (!edPublicKey || (!edKeyFile && edAccount === ED_ACCOUNT) || edPublicKey === ED_PUBLIC_KEY) {
    fail(`--ad-hoc is for test builds and needs a throwaway key: pass --ed-account and --ed-public-key for a key other than "${ED_ACCOUNT}"`);
  }
} else {
  if (!ED_PUBLIC_KEY) {
    fail(`there is no update key yet: make it on the release Mac (docs/distribution.md, "The update key") and set ED_PUBLIC_KEY in scripts/release-mac.mjs`);
  }
  // Installed copies trust only the real key, so a release signed with any
  // other could never update them.
  if (edKeyFile || edAccount !== ED_ACCOUNT || edPublicKey !== ED_PUBLIC_KEY) {
    fail(`a release is signed with the real update key (account "${ED_ACCOUNT}"); another key is only for an --ad-hoc test build`);
  }
  // Sparkle refuses a plain HTTP feed, and install.sh a plain HTTP download.
  for (const name of ["feed-url", "download-base"]) {
    if (values[name] !== undefined && !values[name].startsWith("https://")) fail(`--${name} must be an https:// URL for a release`);
  }
}
const git = (...args) => execFileSync("git", args, { cwd: ROOT, encoding: "utf8" }).trim();
if (!values["allow-dirty"] && git("status", "--porcelain", "--untracked-files=no") !== "") {
  fail("the tree has uncommitted changes; commit them or pass --allow-dirty for a test build");
}
// Sparkle compares CFBundleVersion, so it must only ever grow: the commit count does.
const build = git("rev-list", "--count", "HEAD");
const downloadBase = values["download-base"] ?? `${RELEASES}/download/v${version}`;

// The certificate, before the long build. Never created here (scripts/setup-signing.sh).
if (!adHoc) {
  const identities = spawnSync("security", ["find-identity", "-p", "codesigning"], { encoding: "utf8" }).stdout ?? "";
  if (!identities.includes(`"${SIGN_IDENTITY}"`)) {
    fail(`the "${SIGN_IDENTITY}" signing identity is not in the keychain; import it from the password manager (scripts/setup-signing.sh)`);
  }
}

// The key the app will trust must be the key the zip is signed with, or no
// update from this release could ever install. Checked before the long build.
// Sparkle's tools come with the Swift package; a fresh checkout has not fetched it yet.
if (!existsSync(path.join(SPARKLE_BIN, "generate_keys"))) {
  execFileSync("swift", ["package", "resolve"], { cwd: ROOT, stdio: TO_STDERR });
}
if (edKeyFile) {
  // Sparkle's exported key is base64: a 32-byte Ed25519 seed, or the older
  // 96-byte form that ends with the public key.
  const raw = Buffer.from(readFileSync(edKeyFile, "utf8").trim(), "base64");
  let derived;
  if (raw.length === 32) {
    const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), raw]);
    const jwk = createPublicKey(createPrivateKey({ key: der, format: "der", type: "pkcs8" })).export({ format: "jwk" });
    derived = Buffer.from(jwk.x, "base64url").toString("base64");
  } else if (raw.length === 96) {
    derived = raw.subarray(64).toString("base64");
  } else {
    fail(`${edKeyFile} is not a Sparkle EdDSA key (${raw.length} bytes)`);
  }
  if (derived !== edPublicKey) fail(`the key in ${edKeyFile} is not the public key given (${edPublicKey})`);
} else {
  const keyShown = spawnSync(path.join(SPARKLE_BIN, "generate_keys"), ["--account", edAccount, "-p"], { encoding: "utf8", timeout: 120_000 });
  if (keyShown.status !== 0 || keyShown.stdout.trim() !== edPublicKey) {
    fail(`the Keychain key for account "${edAccount}" is not the public key given (${edPublicKey}): ${(keyShown.stdout || keyShown.stderr || keyShown.error?.message || "").trim()}`);
  }
}

// The DMG tool, fetched once, before the long build. dmgbuild needs Python
// 3.10 or later; the Command Line Tools' python3 is 3.9.
const pyVersion = (python) => execFileSync(python, ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"], { encoding: "utf8" }).trim();
const pyOk = (v) => { const [major, minor] = v.split(".").map(Number); return major > 3 || (major === 3 && minor >= 10); };
// A venv made by an older Python, or one that no longer runs (its Python
// was upgraded or removed), is made again.
if (existsSync(DMG_VENV)) {
  let venvOk = false;
  try { venvOk = pyOk(pyVersion(path.join(DMG_VENV, "bin/python"))); } catch {}
  if (!venvOk) rmSync(DMG_VENV, { recursive: true, force: true });
}
if (!existsSync(path.join(DMG_VENV, "bin/python"))) {
  let system = "none";
  try { system = pyVersion("python3"); } catch {}
  if (!pyOk(system)) fail(`the DMG needs Python 3.10 or later for dmgbuild; python3 on PATH is ${system} (brew install python)`);
  execFileSync("python3", ["-m", "venv", DMG_VENV], { stdio: TO_STDERR });
}
// All three pinned: dmgbuild's own dependencies write the .DS_Store and alias.
execFileSync(path.join(DMG_VENV, "bin/pip"), ["install", "--quiet", "--disable-pip-version-check", ...DMG_PACKAGES], { stdio: TO_STDERR });
// dmgbuild mounts its working image by volume name. With a "Useful Voice"
// volume already mounted, its copy becomes "Useful Voice 1" and the window's
// background alias would point at that name.
if (existsSync(`/Volumes/${VOLUME}`)) fail(`/Volumes/${VOLUME} is mounted; eject it first (hdiutil detach "/Volumes/${VOLUME}")`);
const out = path.resolve(values.out);
// Only ever replace an earlier release folder, never an arbitrary one: every
// entry in it must be a file a release writes.
const RELEASE_FILES = new Set([ZIP, DMG, "install.sh", "appcast.xml", NOTES, ".DS_Store"]);
// A folder or link wearing a release file's name is foreign too: only plain files are replaced.
const foreign = existsSync(out)
  ? readdirSync(out, { withFileTypes: true }).filter((entry) => !RELEASE_FILES.has(entry.name) || !entry.isFile()).map((entry) => entry.name)
  : [];
if (foreign.length > 0) fail(`${out} holds files a release does not write (${foreign.join(", ")}); refusing to delete it`);

// The same bundle target as a local build, with the version, the certificate
// and the update feed a release carries.
execFileSync("make", [
  "bundle",
  `MARKETING_VERSION=${version}`,
  `BUILD_NUMBER=${build}`,
  `SIGN_IDENTITY=${adHoc ? "-" : SIGN_IDENTITY}`,
  `SU_FEED_URL=${values["feed-url"]}`,
  `SU_PUBLIC_ED_KEY=${edPublicKey}`,
], { cwd: ROOT, stdio: TO_STDERR });

const plist = (app, key) => execFileSync("plutil", ["-extract", key, "raw", "-o", "-", path.join(app, "Contents/Info.plist")], { encoding: "utf8" }).trim();
// The code directory hash, which names exactly one build of the app.
const cdhash = (app) => {
  const shown = spawnSync("codesign", ["-dvvv", app], { encoding: "utf8" });
  const match = /^CDHash=(\w+)$/m.exec(shown.stderr);
  if (!match) throw new Error(`codesign shows no CDHash for ${app}: ${shown.stderr}`);
  return match[1];
};
// What macOS keys the Accessibility and Microphone grants to.
const designated = (app) => {
  const shown = spawnSync("codesign", ["-d", "-r-", app], { encoding: "utf8" });
  const match = /^designated => (.+)$/m.exec(`${shown.stdout}\n${shown.stderr}`);
  if (!match) throw new Error(`codesign shows no designated requirement for ${app}: ${shown.stderr}`);
  return match[1].trim();
};
const checkApp = (app) => {
  execFileSync("codesign", ["--verify", "--strict", "--deep", app]);
  for (const [key, want] of [
    ["CFBundleIdentifier", "ai.useful.voice"],
    ["CFBundleShortVersionString", version],
    ["CFBundleVersion", build],
    ["SUFeedURL", values["feed-url"]],
    ["SUPublicEDKey", edPublicKey],
  ]) {
    const got = plist(app, key);
    if (got !== want) throw new Error(`${app}: ${key} is ${got}, not ${want}`);
  }
  if (!adHoc && designated(app) !== DESIGNATED) {
    throw new Error(`${app} is not signed with "${SIGN_IDENTITY}": its designated requirement is ${designated(app)}`);
  }
};
checkApp(BUILT_APP);

const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
// A detach that fails is retried, then forced, and only logged: an error
// from the steps before it must be the one that reaches the terminal.
const detach = (mount) => {
  for (const args of [["detach", mount], ["detach", mount], ["detach", mount], ["detach", "-force", mount]]) {
    const result = spawnSync("hdiutil", args, { encoding: "utf8" });
    if (result.status === 0) return true;
    process.stderr.write(`hdiutil ${args.join(" ")}: ${(result.stderr || result.error?.message || "").trim()}\n`);
    sleep(1000);
  }
  return false;
};
// Ctrl-C (or a closed terminal) reaches the running tool too, which then
// fails, so the step throws and the cleanup below runs (unmount, scratch,
// the half-written release) before the error exits. Without these handlers
// Node would die on the spot and skip it. A signal that lands after the last
// step changes nothing: the release is whole, so its JSON prints and it exits 0.
const SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"];
const onSignal = (signal) => process.stderr.write(`${signal}: finishing the current step, then cleaning up\n`);
for (const signal of SIGNALS) process.on(signal, onSignal);

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
const zip = path.join(out, ZIP);
const dmg = path.join(out, DMG);
const scratch = mkdtempSync(path.join(tmpdir(), "uv-release-"));
let mounted = false;
const mount = path.join(scratch, "mount");
let zipSha;
let dmgSha;
try {
  // Shipped as "Useful Voice.app", the name it is installed under, so Sparkle
  // and the installer find the same bundle. ditto keeps the signature whole.
  const app = path.join(scratch, "stage", APP_NAME);
  execFileSync("ditto", [BUILT_APP, app]);
  if (cdhash(app) !== cdhash(BUILT_APP)) throw new Error("the staged app is not the build (CDHash differs)");
  execFileSync("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", app, zip]);
  // What Sparkle and install.sh will unpack: the same build, whole.
  const unzipped = path.join(scratch, "unzipped");
  execFileSync("ditto", ["-x", "-k", zip, unzipped]);
  checkApp(path.join(unzipped, APP_NAME));
  if (cdhash(path.join(unzipped, APP_NAME)) !== cdhash(app)) throw new Error("the zip's app is not the build (CDHash differs)");

  // `sign_update` prints the enclosure attributes: sparkle:edSignature="…" length="…".
  // A Keychain prompt nobody answers would otherwise hang here for good.
  const signed = execFileSync(path.join(SPARKLE_BIN, "sign_update"), [...keySource, zip], { encoding: "utf8", timeout: 120_000 }).trim();
  if (!/sparkle:edSignature="[^"]+"/.test(signed) || !/length="\d+"/.test(signed)) throw new Error(`sign_update gave no signature: ${signed}`);

  // The DMG: the same app beside a link to /Applications over the brand
  // background (bundle/dmg/). Built before the appcast and installer, so a
  // folder that has those is a whole release.
  for (const [name, scale] of [["background.png", "1"], ["background@2x.png", "2"]]) {
    execFileSync("swift", [path.join(ROOT, "bundle/dmg/background.swift"), path.join(scratch, name), scale], { stdio: TO_STDERR });
  }
  // Checked again here: a volume mounted during the long build would rename
  // dmgbuild's working copy (see the check before the build).
  if (existsSync(`/Volumes/${VOLUME}`)) throw new Error(`/Volumes/${VOLUME} was mounted during the build; eject it and run again`);
  execFileSync(path.join(DMG_VENV, "bin/dmgbuild"), [
    "-s", path.join(ROOT, "bundle/dmg/settings.py"),
    "-D", `app=${app}`,
    "-D", `background=${path.join(scratch, "background.png")}`,
    VOLUME, dmg,
  ], { stdio: TO_STDERR });

  // Mounted read-only and out of Finder's sight, checked, then let go.
  mkdirSync(mount);
  execFileSync("hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, dmg], { stdio: "ignore" });
  mounted = true;
  const layout = execFileSync(path.join(DMG_VENV, "bin/python"), [
    path.join(ROOT, "bundle/dmg/verify.py"), mount, APP_NAME, VOLUME, version, build,
  ], { encoding: "utf8" }).trim();
  process.stderr.write(`dmg layout: ${layout}\n`);
  const inDmg = path.join(mount, APP_NAME);
  // The signature, the version, the feed and the certificate, as on the build.
  checkApp(inDmg);
  // The same build the zip carries, not a stale bundle.
  if (cdhash(inDmg) !== cdhash(app)) throw new Error("the DMG's app is not the build in the zip (CDHash differs)");
  mounted = !detach(mount);
  if (mounted) throw new Error(`could not detach ${mount}`);
  const format = execFileSync("hdiutil", ["imageinfo", "-plist", dmg], { encoding: "utf8" });
  if (!/<key>Format<\/key>\s*<string>UDZO<\/string>/.test(format)) throw new Error("the DMG is not a compressed (UDZO) image");
  dmgSha = createHash("sha256").update(readFileSync(dmg)).digest("hex");

  const appcast = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Useful Voice</title>
    <item>
      <title>${version}</title>
      <pubDate>${new Date().toUTCString()}</pubDate>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="${downloadBase}/${ZIP}" type="application/octet-stream" ${signed} />
    </item>
  </channel>
</rss>
`;

  // The installer names this release's zip and its hash, and refuses anything else.
  zipSha = createHash("sha256").update(readFileSync(zip)).digest("hex");
  const installer = readFileSync(path.join(ROOT, "scripts/install.sh"), "utf8")
    .replace("@@ZIP_URL@@", `${downloadBase}/${ZIP}`)
    .replace("@@ZIP_SHA256@@", zipSha);
  if (installer.includes("@@ZIP_")) throw new Error("install.sh placeholders were not filled");
  writeFileSync(path.join(out, "install.sh"), installer, { mode: 0o755 });
  // Published beside the appcast.
  const installUrl = new URL("install.sh", values["feed-url"]).href;
  const notes = readFileSync(path.join(ROOT, "bundle/release-notes.md"), "utf8")
    .replaceAll("@@VERSION@@", version)
    .replaceAll("@@INSTALL_COMMAND@@", `curl -fsSL ${installUrl} | sh`)
    .replaceAll("@@SOURCE_URL@@", SOURCE);
  if (/@@[A-Z_]+@@/.test(notes)) throw new Error("release-notes.md placeholders were not filled");
  writeFileSync(path.join(out, NOTES), notes);
  // Last: its presence marks a finished release folder.
  writeFileSync(path.join(out, "appcast.xml"), appcast);
} catch (error) {
  // Nothing half-built that looks publishable.
  rmSync(out, { recursive: true, force: true });
  throw error;
} finally {
  if (mounted) mounted = !detach(mount);
  // A volume still mounted there must not be walked into by rm.
  if (mounted) {
    process.stderr.write(`left ${mount} mounted; detach it by hand, then delete ${scratch}\n`);
  } else {
    try {
      rmSync(scratch, { recursive: true, force: true });
    } catch (error) {
      process.stderr.write(`could not delete ${scratch}: ${error.message}\n`);
    }
  }
  for (const signal of SIGNALS) process.off(signal, onSignal);
}

process.stdout.write(`${JSON.stringify({ version, build, adHoc, zip, bytes: statSync(zip).size, sha256: zipSha, dmg, dmgBytes: statSync(dmg).size, dmgSha256: dmgSha, appcast: path.join(out, "appcast.xml"), feed: values["feed-url"] })}\n`);
