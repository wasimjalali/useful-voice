/**
 * "Start with Windows": what to register, and how a launch from that registration is
 * recognised.
 *
 * On Windows the login entry is a value under
 * `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` holding an entire command
 * line, so the flag below has to be part of it. Without a flag, an auto-start is
 * indistinguishable from the user double-clicking the icon, and the two need
 * different behaviour: a launch from the login entry must never put a window in the
 * user's face at login.
 *
 * Windows names that Run value after the app's AppUserModelID, which is why the
 * removal path below does not depend on the command line that was written.
 *
 * The decision is pure so it can be tested on any platform; `app.setLoginItemSettings`
 * itself is documented `@platform win32` and is called only from the main process.
 */

/**
 * The flag appended to the login entry's command line.
 *
 * Exported because it is a contract between two callers that never meet: the code
 * that writes the login entry and the code that reads `process.argv` at startup.
 */
export const AUTOSTART_ARG = '--autostart';

/** Why a plan is what it is; surfaced in the diagnostics log. */
export type LoginItemReason =
  /** Not Windows: the OS has no equivalent entry, and nothing is touched. */
  | 'non-windows'
  /** The user switched "Start with Windows" off; remove the entry. */
  | 'disabled'
  /** Installed build: register the app itself. */
  | 'enabled'
  /** Running from a checkout (`electron .`): Electron's own binary must be told
   * which app to run. */
  | 'unpackaged';

/**
 * The subset of Electron's `Settings` this module decides.
 *
 * `path` and `args` are optional because the removal path deliberately passes
 * neither; see `planLoginItem`.
 */
export interface LoginItemSettings {
  openAtLogin: boolean;
  /** The executable to launch at login. Defaults to `process.execPath`. */
  path?: string;
  /** The arguments to launch it with. Defaults to an empty array. */
  args?: string[];
}

export interface LoginItemPlan {
  /**
   * Whether the OS login registry should be touched at all.
   *
   * False means "do nothing", not "write openAtLogin: false": on macOS the call
   * manages a Login Item through the system, and there is nothing there to clean up.
   */
  apply: boolean;
  reason: LoginItemReason;
  /** The exact object to hand to `app.setLoginItemSettings`. */
  settings: LoginItemSettings;
}

/**
 * Whether this process was started by the login entry.
 *
 * Matched exactly, never as a prefix: `--autostart-report=…` or a hypothetical
 * `--autostart=false` would otherwise be read as an auto-start, and being wrong here
 * means the app decides at login time that the user asked for it.
 *
 * Electron hands the whole command line through as separate arguments on Windows,
 * so the flag is always an argument of its own rather than part of the executable's.
 */
export function wasAutoStarted(argv: readonly string[]): boolean {
  return argv.includes(AUTOSTART_ARG);
}

export interface LoginItemInput {
  /** The `launchAtLogin` setting. */
  enabled: boolean;
  /** `process.platform`. */
  platform: string;
  /** `app.isPackaged`. */
  isPackaged: boolean;
  /** `process.execPath` — the binary Windows will start. */
  execPath: string;
  /** `app.getAppPath()` — the app directory, needed only for an unpackaged run. */
  appPath: string;
}

/**
 * Work out the login entry to register.
 *
 * The arguments matter as much as the flag: the same settings object is what a
 * later `app.getLoginItemSettings(settings)` has to be compared against, because
 * Electron reports `openAtLogin` by matching the stored command line against the
 * `path` and `args` it is given.
 */
export function planLoginItem(input: LoginItemInput): LoginItemPlan {
  const { enabled, platform, isPackaged, execPath, appPath } = input;

  if (platform !== 'win32') {
    // `path` and `args` are win32-only, and on macOS the call registers the app as a
    // Login Item — which during development means adding Electron.app itself to the
    // developer's machine, a side effect no setting asked for. So nothing is touched
    // off Windows, in either direction.
    return { apply: false, reason: 'non-windows', settings: { openAtLogin: false } };
  }

  if (!enabled) {
    // No path and no args on purpose: the Run value is named after the app, so
    // removal finds it whatever command line was written — including one written by
    // an older build or from a directory the app no longer lives in.
    return { apply: true, reason: 'disabled', settings: { openAtLogin: false } };
  }

  if (!isPackaged) {
    // Unpackaged (`electron .`), `process.execPath` is Electron's own binary, which
    // started on its own would look for a default app rather than this one. The app
    // directory therefore has to be passed first, exactly as the developer typed it.
    return {
      apply: true,
      reason: 'unpackaged',
      settings: { openAtLogin: true, path: execPath, args: [appPath, AUTOSTART_ARG] },
    };
  }

  return {
    apply: true,
    reason: 'enabled',
    // `path` is Electron's documented default (`process.execPath`), passed
    // explicitly so the same object can be used to read the entry back; `args` must
    // contain the auto-start flag, since that is the only thing that tells a login
    // launch apart from the user opening the app.
    settings: { openAtLogin: true, path: execPath, args: [AUTOSTART_ARG] },
  };
}
