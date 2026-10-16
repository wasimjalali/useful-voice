import { _electron as electron, type ElectronApplication, type Page } from '@playwright/test';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// What the dictation specs share: launching the built app on a scratch folder, finding its
// windows, calling the e2e-only hooks in main (`__uv`, `__uvTray`) and the renderer's own
// bridge (`window.usefulVoice`), and replacing the microphone with a controllable one.

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const out = process.env.E2E_OUT ?? path.join(root, 'e2e-results');

export interface Running {
  app: ElectronApplication;
  win: Page;
  userData: string;
  stop: () => Promise<void>;
}

/** Resolves to `fallback` if `promise` takes longer than `ms`, so diagnostics never hang. */
function within<T>(promise: Promise<T>, ms: number, fallback: T): Promise<T> {
  return Promise.race([promise.catch(() => fallback), new Promise<T>((resolve) => setTimeout(() => resolve(fallback), ms))]);
}

/** The window whose address holds `view=<view>`. */
export async function pageFor(app: ElectronApplication, view: string, userData: string, output: string[] = []): Promise<Page> {
  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    for (const page of app.windows()) {
      const href = await within(page.evaluate(() => location.href), 2_000, page.url());
      if (href.includes(`view=${view}`)) return page;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  const log = await fs.readFile(path.join(userData, 'e2e.log'), 'utf8').catch(() => '(no e2e.log)');
  throw new Error(`the ${view} window never opened\nlog:\n${log}\n${output.join('')}`);
}

/** Launches the built app with video and a trace and waits for the main window. */
export async function launch(name: string, userData: string, flags: string[] = []): Promise<Running> {
  const env = { ...process.env } as Record<string, string>;
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({
    args: [path.join(root, 'dist', 'main', 'index.js'), `--uv-data-dir=${userData}`, '--e2e', ...flags],
    env,
    // `_electron.launch` bypasses the config's `use` options, so video and trace are switched on here.
    recordVideo: { dir: path.join(out, 'video-dictation', name), size: { width: 1180, height: 740 } },
  });
  const output: string[] = [];
  app.process().stdout?.on('data', (chunk: Buffer) => output.push(chunk.toString()));
  app.process().stderr?.on('data', (chunk: Buffer) => output.push(chunk.toString()));
  await app.context().tracing.start({ screenshots: true, snapshots: true });
  const win = await pageFor(app, 'main', userData, output);
  await win.setViewportSize({ width: 1180, height: 740 });
  await win.waitForSelector('.dock');
  const stop = async (): Promise<void> => {
    try {
      await app.context().tracing.stop({ path: path.join(out, `trace-dictation-${name}.zip`) });
    } finally {
      await app.close();
    }
  };
  return { app, win, userData, stop };
}

export async function remove(dir: string): Promise<void> {
  await fs.rm(dir, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}

// ---- main-process hooks ----------------------------------------------------

type Hooks = Record<string, (value?: unknown) => unknown>;

/** Calls `__uv[name](arg)` in main (installed only under `--e2e`). */
export function hook(app: ElectronApplication, name: string, arg?: unknown): Promise<unknown> {
  return app.evaluate((_electron, args) => (globalThis as unknown as { __uv: Hooks }).__uv[args.name]?.(args.arg), { name, arg });
}

export interface TrayItem {
  label: string;
  enabled: boolean;
  type: string;
}

/** The tray menu the app would show right now (no icon is created under `--e2e`). */
export function trayMenu(app: ElectronApplication): Promise<TrayItem[]> {
  return app.evaluate(() => (globalThis as unknown as { __uvTray: { menu(): TrayItem[] } }).__uvTray.menu());
}

export async function trayItem(app: ElectronApplication, label: string): Promise<TrayItem | undefined> {
  return (await trayMenu(app)).find((item) => item.label === label);
}

/** Sends a message to the main window the way main does, for states a Linux or CI box cannot reach. */
export function sendToMain(app: ElectronApplication, channel: string, payload: unknown): Promise<void> {
  return app.evaluate(
    ({ BrowserWindow }, args) => {
      const win = BrowserWindow.getAllWindows().find((w) => w.webContents.getURL().includes('view=main'));
      win?.webContents.send(args.channel, args.payload);
    },
    { channel, payload },
  );
}

export function clipboardText(app: ElectronApplication): Promise<string> {
  return app.evaluate(({ clipboard }) => clipboard.readText());
}

export function writeClipboard(app: ElectronApplication, text: string): Promise<void> {
  return app.evaluate(({ clipboard }, value) => clipboard.writeText(value), text);
}

// ---- the renderer's bridge -------------------------------------------------

export interface Log {
  outcomes: Array<{ kind: string; words?: number; result?: string; appName?: string }>;
  states: Array<{ state: string; delivery?: string; message?: string; error?: { kind: string; fix?: string; message: string } }>;
  telemetry: Array<{ level: number; elapsedSeconds: number; silenceRemaining?: number; maxRemaining?: number }>;
}

/** Starts collecting every dictation event the window receives into `window.__log`. */
export async function collect(win: Page): Promise<void> {
  await win.evaluate(() => {
    const w = window as unknown as { __log?: unknown; usefulVoice: Record<string, (handler: (value: unknown) => void) => void> };
    const log = { outcomes: [] as unknown[], states: [] as unknown[], telemetry: [] as unknown[] };
    w.__log = log;
    w.usefulVoice.onOutcome?.((value) => log.outcomes.push(value));
    w.usefulVoice.onState?.((value) => log.states.push(value));
    w.usefulVoice.onTelemetry?.((value) => log.telemetry.push(value));
  });
}

export function log(win: Page): Promise<Log> {
  return win.evaluate(() => (window as unknown as { __log: unknown }).__log as never);
}

/** Saves a key in main the way Settings does. The e2e stub accepts a key starting `valid`. */
export async function setKey(win: Page, key: string): Promise<void> {
  const result = await win.evaluate((value) => (window as unknown as { usefulVoice: { setApiKey(key: string): Promise<{ ok: boolean; error?: string }> } }).usefulVoice.setApiKey(value), key);
  if (!result.ok) throw new Error(`the key was not saved: ${result.error ?? 'no reason given'}`);
}

export function saveSettings(win: Page, patch: Record<string, unknown>): Promise<unknown> {
  return win.evaluate((value) => (window as unknown as { usefulVoice: { saveSettings(patch: unknown): Promise<unknown> } }).usefulVoice.saveSettings(value), patch);
}

// ---- stored data -----------------------------------------------------------

export interface StoredRecord {
  id: string;
  text: string;
  appName: string;
  language: string;
  appID?: string;
  category?: string;
}

/** The history as saved on disk. Main writes a moment after the change, so poll until `ok` accepts it. */
export async function historyWhere(userData: string, ok: (history: StoredRecord[]) => boolean): Promise<StoredRecord[]> {
  const deadline = Date.now() + 10_000;
  let last: StoredRecord[] = [];
  while (Date.now() < deadline) {
    try {
      const parsed = JSON.parse(await fs.readFile(path.join(userData, 'data.json'), 'utf8')) as { payload: { history: StoredRecord[] } };
      last = parsed.payload.history;
      if (ok(last)) return last;
    } catch {
      // Mid-write: try again.
    }
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  return last;
}

// ---- the microphone --------------------------------------------------------

/**
 * Replaces the recorder window's microphone with a tone that plays for `toneMs` and is silent
 * after. Chromium's own fake device beeps all the time, so it can never reach a silence limit.
 * Installed before the dictation starts; it lasts until the app closes.
 */
export async function useScriptedMicrophone(app: ElectronApplication, userData: string, toneMs: number): Promise<void> {
  const recorder = await pageFor(app, 'recorder', userData);
  await recorder.evaluate((ms) => {
    navigator.mediaDevices.getUserMedia = async (): Promise<MediaStream> => {
      const context = new AudioContext();
      const destination = context.createMediaStreamDestination();
      const gain = context.createGain();
      gain.gain.value = 0.5;
      const tone = context.createOscillator();
      tone.frequency.value = 440;
      tone.connect(gain).connect(destination);
      tone.start();
      window.setTimeout(() => {
        gain.gain.value = 0;
      }, ms);
      return destination.stream;
    };
  }, toneMs);
}
