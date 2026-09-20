import { readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * The IPC contract between the preload and the main process, checked statically.
 *
 * Electron cannot be imported here — the suite runs on plain Node, which is what makes
 * a Windows app testable from macOS — so the channel names are read out of the two
 * source files as text with regular expressions. That is enough to catch the failure
 * modes that actually hurt:
 *
 *   - a channel the preload invokes with no `ipcMain.handle` in main, where the
 *     renderer's promise never settles and the UI hangs with nothing logged;
 *   - a channel main sends that the preload never subscribes to, where the UI
 *     silently stops updating;
 *   - a channel registered twice by `ipcMain.handle`, which throws inside Electron and
 *     takes the app down at startup.
 *
 * Every extractor is asserted non-trivial below: a regex that matched nothing would
 * leave this file green while verifying exactly nothing, which is worse than having no
 * test at all.
 *
 * The last block applies the same text-scan contract to a different property: that
 * the ESM main process contains no CommonJS `require(` call.
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, '..');

function readSource(relativePath: string): string {
  return readFileSync(path.join(projectRoot, relativePath), 'utf8');
}

/** Capture group 1 of every match; the channel name is always the first argument. */
function extracts(source: string, pattern: RegExp): string[] {
  return [...source.matchAll(pattern)].map((match) => match[1] ?? '');
}

function unique(values: readonly string[]): string[] {
  return [...new Set(values)].sort();
}

function duplicatesOf(values: readonly string[]): string[] {
  return unique(values.filter((value, index) => values.indexOf(value) !== index));
}

const preloadSource = readSource('src/preload/index.ts');
const mainSource = readSource('src/main/index.ts');

/** Channels the renderer calls and awaits an answer from. */
const invokedChannels = unique(extracts(preloadSource, /ipcRenderer\.invoke\(\s*'([^']+)'/g));
/** Channels the renderer fires at main without waiting for an answer. */
const channelsSentByPreload = unique(extracts(preloadSource, /ipcRenderer\.send\(\s*'([^']+)'/g));
/** Channels the renderer listens on. */
const channelsSubscribedByPreload = unique([
  ...extracts(preloadSource, /ipcRenderer\.on\(\s*'([^']+)'/g),
  // Some subscriptions route through the local `subscribe(channel, handler)` helper,
  // which exists so three similar listeners cannot drift apart. A channel registered
  // only that way is still a real subscription and must be counted, or the test would
  // report a live channel as unconsumed.
  ...extracts(preloadSource, /subscribe\(\s*'([^']+)'/g),
]);

/** Channels main answers with a handler. */
const handledChannelLiterals = extracts(mainSource, /ipcMain\.handle\(\s*'([^']+)'/g);
/** Channels main receives as one-way messages from the renderer. */
const channelsReceivedByMain = unique(extracts(mainSource, /ipcMain\.on\(\s*'([^']+)'/g));
/**
 * Channels main pushes to the renderer.
 *
 * `broadcast` is counted alongside `webContents.send` because it is a thin wrapper
 * that forwards to `webContents.send` for every live window, so its channel argument
 * is a renderer-bound channel just as much as a direct send is.
 */
const channelsSentToRenderer = unique([
  ...extracts(mainSource, /webContents\.send\(\s*'([^']+)'/g),
  ...extracts(mainSource, /this\.broadcast\(\s*'([^']+)'/g),
]);

const allChannels = unique([
  ...invokedChannels,
  ...channelsSentByPreload,
  ...channelsSubscribedByPreload,
  ...handledChannelLiterals,
  ...channelsReceivedByMain,
  ...channelsSentToRenderer,
]);

/**
 * Channels main broadcasts that the preload does NOT forward to the renderer.
 *
 * Empty on purpose, and it was not always. This list once held
 * `history:changed`, `memory:changed` and `notes:changed`: main signalled that a
 * dictation had been recorded, and that the dictionary or notes had changed, and
 * nothing was listening. An already-open page therefore kept a stale list after a
 * hotkey dictation or a tray action, because the renderer only refreshed for
 * mutations it had started itself.
 *
 * The preload now subscribes to all three and the renderer refetches the affected
 * page, so the honest state of this list is empty. Keeping the list (rather than
 * deleting the assertion) means a *new* dead channel still fails the test instead of
 * shipping silently.
 */
const KNOWN_UNSUBSCRIBED_BROADCASTS: string[] = [];

/**
 * Namespaces in use. A new namespace is a deliberate choice, so it has to be added
 * here rather than appearing silently.
 */
const NAMESPACES = [
  'app',
  'audio',
  'backup',
  'clipboard',
  'dictation',
  'history',
  'hud',
  'memory',
  'notes',
  'settings',
];

describe('channel extraction', () => {
  it('finds the channels both sides name', () => {
    // Loud on purpose: these are the counts at the time of writing, and a drop to
    // near zero means a regex stopped matching rather than that the app got simpler.
    expect(invokedChannels.length, 'invoke channels').toBeGreaterThanOrEqual(30);
    expect(channelsSentByPreload.length, 'ipcRenderer.send channels').toBeGreaterThanOrEqual(1);
    // Nine subscriptions today, registered directly and through the `subscribe` helper.
    // The minimum sits one below that so a broken helper extraction trips it as well as
    // the "everything main sends is subscribed" test below.
    expect(channelsSubscribedByPreload.length, 'subscribed channels').toBeGreaterThanOrEqual(8);
    expect(handledChannelLiterals.length, 'ipcMain.handle channels').toBeGreaterThanOrEqual(30);
    expect(channelsReceivedByMain.length, 'ipcMain.on channels').toBeGreaterThanOrEqual(1);
    expect(channelsSentToRenderer.length, 'renderer-bound channels').toBeGreaterThanOrEqual(5);
    expect(allChannels.length, 'unique channels').toBeGreaterThanOrEqual(40);
  });

  it('accounts for every ipcMain.handle call site', () => {
    // A handler registered from a variable cannot be compared by name, so the counts
    // are reconciled instead: a call site that neither regex matched would mean this
    // file is checking an incomplete picture.
    const allSites = [...mainSource.matchAll(/ipcMain\.handle\(/g)].length;
    const dynamicSites = [...mainSource.matchAll(/ipcMain\.handle\(\s*[^'\s)]/g)];
    expect(allSites).toBe(handledChannelLiterals.length + dynamicSites.length);

    // The one dynamic registration is the self-test stub loop, which registers and
    // removes its channels inside `runSelfTest` and never runs with the real handlers.
    // Anywhere else it would be a duplicate registration waiting to throw.
    const selfTestStart = mainSource.indexOf('export async function runSelfTest');
    expect(selfTestStart, 'runSelfTest must exist to anchor this check').toBeGreaterThan(0);
    const outsideSelfTest = dynamicSites
      .filter((match) => (match.index ?? 0) < selfTestStart)
      .map((match) => mainSource.slice(match.index, (match.index ?? 0) + 60).split('\n')[0]);
    expect(outsideSelfTest).toEqual([]);
  });
});

describe('preload -> main', () => {
  it('has a handler for every channel the preload invokes', () => {
    const missing = invokedChannels.filter((channel) => !handledChannelLiterals.includes(channel));
    expect(missing, 'invoked with no ipcMain.handle in main').toEqual([]);
  });

  it('registers no channel twice', () => {
    // Electron throws on a second handler for the same channel, so this is a crash at
    // startup rather than a subtle bug.
    expect(duplicatesOf(handledChannelLiterals), 'double-registered channels').toEqual([]);
  });

  it('has no handler that nothing invokes', () => {
    // A handler the preload never calls is dead weight, and usually the surviving half
    // of a renamed channel.
    const orphans = unique(handledChannelLiterals).filter((channel) => !invokedChannels.includes(channel));
    expect(orphans, 'handlers with no caller').toEqual([]);
  });

  it('receives every channel the preload sends one-way', () => {
    const unheard = channelsSentByPreload.filter((channel) => !channelsReceivedByMain.includes(channel));
    expect(unheard, 'ipcRenderer.send with no ipcMain.on').toEqual([]);
  });
});

describe('main -> renderer', () => {
  it('is subscribed to by the preload, apart from the known gaps', () => {
    const unsubscribed = channelsSentToRenderer.filter(
      (channel) => !channelsSubscribedByPreload.includes(channel),
    );
    expect(unsubscribed, 'channels main sends to a renderer that never listens').toEqual(
      KNOWN_UNSUBSCRIBED_BROADCASTS,
    );
  });

  it('keeps the known-gap list honest', () => {
    // Each entry must still be broadcast, or the list is documenting a channel that no
    // longer exists and the test above would keep passing for the wrong reason.
    const stale = KNOWN_UNSUBSCRIBED_BROADCASTS.filter((channel) => !channelsSentToRenderer.includes(channel));
    expect(stale, 'listed as unconsumed but no longer broadcast').toEqual([]);
  });

  it('delivers the data-change broadcasts, which were previously dropped', () => {
    // Named explicitly rather than left to the empty list above, so that deleting a
    // subscription fails here with a clear reason instead of silently reintroducing
    // the stale-list bug.
    for (const channel of ['history:changed', 'memory:changed', 'notes:changed']) {
      expect(channelsSentToRenderer, `${channel} must still be broadcast by main`).toContain(channel);
      expect(
        channelsSubscribedByPreload,
        `${channel} must be forwarded to the renderer by the preload`,
      ).toContain(channel);
    }
  });
});

describe('channel naming', () => {
  it('names every channel namespace:verb', () => {
    // The verb may be camelCase (`dictation:copyLast`); the rule is the namespace,
    // which is what keeps these channels greppable from either process.
    const offenders = allChannels.filter((channel) => !/^[a-z][a-z0-9]*:[A-Za-z][A-Za-z0-9-]*$/.test(channel));
    expect(offenders, 'channels without a namespace').toEqual([]);
  });

  it('uses only known namespaces', () => {
    const namespaces = unique(allChannels.map((channel) => channel.split(':')[0] ?? ''));
    expect(namespaces).toEqual(NAMESPACES);
  });

  it('matches the channel count the README documents', () => {
    // The security boundary is written down as a number in the README, and a number
    // that drifts away from the code is a boundary nobody has checked. The preload
    // takes `app:save-status` in both directions, so directions are counted, not
    // distinct names.
    const documented = /The renderer can call (\d+) named IPC channels/.exec(readSource('README.md'));
    expect(documented, 'README must keep documenting the channel count').not.toBeNull();
    const counted =
      invokedChannels.length + channelsSentByPreload.length + channelsSubscribedByPreload.length;
    expect(counted).toBe(Number(documented?.[1] ?? -1));
  });
});

/**
 * The main process compiles to ESM — the package is `"type": "module"` and tsc emits
 * `.js` files that Node runs as ES modules — so a bare `require(` is not a style
 * problem, it is a `ReferenceError: require is not defined` waiting for the code
 * path that calls it. tsc does not flag the call: `@types/node` still declares
 * `require` as a global, which is exactly how `require('electron').screen` once sat
 * latent inside `showHud`, a path the self-test never exercises.
 *
 * The scan is textual and deliberately approximate, like the channel checks above:
 * line and block comments are stripped first so a comment *mentioning* `require(`
 * cannot fail the build, while string literals are left alone — a `"require("`
 * inside a string still trips the check, which fails safe. The lookbehind excludes
 * identifiers that merely end in "require" (`createRequire`, `required`) and member
 * calls (`obj.require(`), neither of which is the CommonJS global.
 *
 * Two blind spots are accepted and documented rather than engineered away.
 * First, stripping is naive: a `//` or `/*` inside a string or regex literal (for
 * example `if (/^https:\/\//i.test(url))` in index.ts) eats real code to the end of
 * the line or block, so a `require(` appended to such a line would be invisible —
 * the only direction this guard can miss. Second, member or alias forms
 * (`globalThis.require(`, `const r = require`) are excluded on purpose: none is a
 * working CommonJS bypass under ESM — they all still throw at runtime — so they
 * only evade detection of a latent crash, which is what this guard exists for.
 *
 * Only `src/main` is scanned. The preload is out of scope on purpose: it bundles to
 * CJS for `contextIsolation`, where `require` is legitimate.
 */
const BARE_REQUIRE = /(?<![\w$.])require\s*\(/;

function stripComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

function mainSourceFiles(): { name: string; stripped: string }[] {
  const mainDir = path.join(projectRoot, 'src/main');
  return readdirSync(mainDir, { recursive: true })
    .map(String)
    .filter((name) => name.endsWith('.ts'))
    .map((name) => ({
      name,
      stripped: stripComments(readFileSync(path.join(mainDir, name), 'utf8')),
    }));
}

describe('main process module format', () => {
  it('matches a bare require( and nothing that merely resembles one', () => {
    // Asserted both ways, for the same reason the channel counts are: a pattern that
    // matched nothing would leave the scan below green while checking nothing, and
    // one that matched too much would fail on legitimate code.
    expect(BARE_REQUIRE.test("require('electron')")).toBe(true);
    expect(BARE_REQUIRE.test("require  ('electron')")).toBe(true);
    expect(BARE_REQUIRE.test('createRequire(import.meta.url)')).toBe(false);
    expect(BARE_REQUIRE.test('createrequire(mod)')).toBe(false);
    expect(BARE_REQUIRE.test('required(field)')).toBe(false);
    expect(BARE_REQUIRE.test('requirement met')).toBe(false);
    expect(BARE_REQUIRE.test("const importRequire = require")).toBe(false);
    expect(BARE_REQUIRE.test("obj.require('x')")).toBe(false);
    // A comment that talks about require( is not a call.
    expect(BARE_REQUIRE.test(stripComments("// use require('electron') here"))).toBe(false);
    expect(BARE_REQUIRE.test(stripComments("/* require('x') */ ok()"))).toBe(false);
  });

  it('finds no bare require( in any src/main TypeScript file', () => {
    const files = mainSourceFiles();
    // Non-trivial, like the extraction counts: an empty listing would pass the
    // assertion below while scanning nothing.
    expect(files.length, 'src/main files scanned').toBeGreaterThanOrEqual(4);
    const offenders = files.filter(({ stripped }) => BARE_REQUIRE.test(stripped)).map(({ name }) => name);
    expect(offenders, 'ESM main sources containing a CommonJS require').toEqual([]);
  });
});
