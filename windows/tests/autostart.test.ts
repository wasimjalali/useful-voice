import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  AUTOSTART_ARG,
  planLoginItem,
  wasAutoStarted,
} from '../src/core/settings/autostart.js';

/**
 * "Start with Windows", tested where it can be.
 *
 * `app.setLoginItemSettings` needs Electron and only does anything on Windows, so the
 * part that decides *what* to register and *how an auto-start is recognised* is pure
 * and lives in `src/core/settings/autostart.ts`. Two things are being pinned down:
 *
 *   1. the registered command line carries `--autostart`, because that flag is the only
 *      way a launch from the login entry can be told apart from the user opening the
 *      app — and it was previously registered without ever being read;
 *   2. nothing is written off Windows, where the same call manages a macOS Login Item
 *      and would add Electron.app to a developer's machine.
 */

const here = path.dirname(fileURLToPath(import.meta.url));
const mainSource = readFileSync(path.resolve(here, '../src/main/index.ts'), 'utf8');

const packaged = {
  platform: 'win32',
  isPackaged: true,
  execPath: 'C:\\Users\\ada\\AppData\\Local\\Programs\\Useful Voice\\Useful Voice.exe',
  appPath: 'C:\\Users\\ada\\AppData\\Local\\Programs\\Useful Voice\\resources\\app.asar',
};
const unpackaged = {
  ...packaged,
  isPackaged: false,
  execPath: 'C:\\dev\\useful-voice\\windows\\node_modules\\electron\\dist\\electron.exe',
  appPath: 'C:\\dev\\useful-voice\\windows',
};

describe('wasAutoStarted', () => {
  it('recognises the login entry command line', () => {
    expect(wasAutoStarted(['C:\\Program Files\\Useful Voice\\Useful Voice.exe', AUTOSTART_ARG])).toBe(true);
    expect(wasAutoStarted([AUTOSTART_ARG])).toBe(true);
  });

  it('does not fire for an ordinary launch', () => {
    expect(wasAutoStarted(['C:\\Program Files\\Useful Voice\\Useful Voice.exe'])).toBe(false);
    expect(wasAutoStarted([])).toBe(false);
  });

  it('does not fire for the self-test or another flag', () => {
    expect(wasAutoStarted(['electron.exe', '--self-test', '--report=out.txt'])).toBe(false);
  });

  it('matches the flag exactly, never as a prefix', () => {
    // A prefix test would treat any future `--autostart-report=…` or an explicit
    // `--autostart=false` as an auto-start, and the app would then decide, at login
    // time, that the user had asked for something they did not.
    expect(wasAutoStarted(['app.exe', `${AUTOSTART_ARG}=false`])).toBe(false);
    expect(wasAutoStarted(['app.exe', `--no${AUTOSTART_ARG}`])).toBe(false);
    expect(wasAutoStarted(['app.exe', `x${AUTOSTART_ARG}`])).toBe(false);
    expect(wasAutoStarted(['app.exe', `${AUTOSTART_ARG} `])).toBe(false);
  });
});

describe('planLoginItem on Windows', () => {
  it('registers the installed app with the auto-start flag', () => {
    const plan = planLoginItem({ ...packaged, enabled: true });
    expect(plan).toEqual({
      apply: true,
      reason: 'enabled',
      settings: { openAtLogin: true, path: packaged.execPath, args: [AUTOSTART_ARG] },
    });
  });

  it('removes the entry without a path or args', () => {
    // Strict equality on purpose: removal must not depend on the command line that was
    // written, so an update that moves the executable can still remove the entry.
    const plan = planLoginItem({ ...packaged, enabled: false });
    expect(plan).toEqual({ apply: true, reason: 'disabled', settings: { openAtLogin: false } });
    expect(plan.settings.path).toBeUndefined();
    expect(plan.settings.args).toBeUndefined();
  });

  it('tells Electron which app to run when unpackaged', () => {
    // `electron .` from a checkout: process.execPath is Electron's own binary, so
    // without the app directory the login entry would start Electron's default app.
    const plan = planLoginItem({ ...unpackaged, enabled: true });
    expect(plan).toEqual({
      apply: true,
      reason: 'unpackaged',
      settings: { openAtLogin: true, path: unpackaged.execPath, args: [unpackaged.appPath, AUTOSTART_ARG] },
    });
  });

  it('removes a development entry the same way', () => {
    const plan = planLoginItem({ ...unpackaged, enabled: false });
    expect(plan).toEqual({ apply: true, reason: 'disabled', settings: { openAtLogin: false } });
    expect(JSON.stringify(plan.settings)).not.toContain('--autostart');
  });

  it('registers the very flag the startup path reads', () => {
    // The bug this guards: the flag was put into the login entry and never consumed,
    // so an auto-start was indistinguishable from a user launch. Asserting both
    // directions means renaming the constant cannot silently break the pair.
    for (const plan of [
      planLoginItem({ ...packaged, enabled: true }),
      planLoginItem({ ...unpackaged, enabled: true }),
    ]) {
      const commandLine = [plan.settings.path ?? '', ...(plan.settings.args ?? [])];
      expect(wasAutoStarted(commandLine), JSON.stringify(plan)).toBe(true);
      const withoutFlag = commandLine.filter((argument) => argument !== AUTOSTART_ARG);
      expect(wasAutoStarted(withoutFlag), JSON.stringify(plan)).toBe(false);
    }
  });
});

describe('planLoginItem off Windows', () => {
  it('touches nothing on macOS, in either direction', () => {
    // `path` and `args` are win32-only, and on macOS the call manages a Login Item:
    // enabling it during development would add Electron.app to the developer's own
    // machine, and there is nothing there for the disable path to clean up.
    for (const platform of ['darwin', 'linux']) {
      for (const enabled of [true, false]) {
        const plan = planLoginItem({ ...packaged, platform, enabled });
        expect(plan.apply, `${platform} enabled=${enabled}`).toBe(false);
        expect(plan.reason).toBe('non-windows');
        expect(plan.settings).toEqual({ openAtLogin: false });
      }
    }
  });
});

describe('the main process wiring', () => {
  it('consumes the flag it registers', () => {
    // "Passed but never read" is exactly how this gap looked: the registration wrote
    // the flag and no code path looked at it. Both consumers matter — `process.argv`
    // says whether this launch came from the login entry, and the second-instance
    // command line says whether the launch being handed off came from it.
    expect(mainSource).toContain('wasAutoStarted(process.argv)');
    expect(mainSource).toContain('wasAutoStarted(commandLine)');
  });

  it('never spells the flag out as a bare string', () => {
    // One source of truth: the writer and the reader must not be able to drift.
    expect(mainSource.includes(`'${AUTOSTART_ARG}'`)).toBe(false);
  });

  it('routes every login-item write through the platform-guarded plan', () => {
    const writes = [...mainSource.matchAll(/app\.setLoginItemSettings\(/g)];
    const reads = [...mainSource.matchAll(/app\.getLoginItemSettings\(/g)];
    expect(writes).toHaveLength(1);
    expect(reads).toHaveLength(1);
    expect(mainSource).toContain('planLoginItem({');
    // The read-back has to use the same settings object the write used, because that
    // is how Electron matches the stored command line.
    expect(mainSource).toContain('setLoginItemSettings(plan.settings)');
    expect(mainSource).toContain('getLoginItemSettings(plan.settings)');
  });

  it('plans with the real platform and packaging facts', () => {
    // The plan is only as good as its inputs: `platform` decides whether anything is
    // written at all, and `isPackaged` decides whether Electron's own binary has to be
    // told which app to start.
    for (const field of [
      'platform: process.platform',
      'isPackaged: app.isPackaged',
      'execPath: process.execPath',
      'appPath: app.getAppPath()',
    ]) {
      expect(mainSource, field).toContain(field);
    }
  });
});
