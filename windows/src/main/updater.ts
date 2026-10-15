import { existsSync } from 'node:fs';
import path from 'node:path';
import { app } from 'electron';
import electronUpdater from 'electron-updater';

/**
 * In-app updates for the installed (NSIS) build, through `electron-updater`.
 *
 * The feed is the `publish` entry in package.json's build config: the GitHub provider
 * reading `latest.yml` from the newest release of `wasimjalali/useful-voice-releases`.
 * electron-builder bakes it into `resources/app-update.yml` at package time. The
 * download is checked against the SHA-512 in that `latest.yml`, fetched over HTTPS.
 * The builds are not Authenticode-signed yet, so `win.verifyUpdateCodeSignature` is
 * off; turn it back on in the release that ships the first signed build.
 *
 * An update downloads in the background and installs when the app quits, or at once
 * from the tray's "Restart to update". Nothing is sent but the requests GitHub sees.
 */

/** First check this long after launch, so it never competes with startup. */
const FIRST_CHECK_DELAY_MS = 60_000;
/** Then twice a day: the app sits in the tray for weeks. */
const CHECK_INTERVAL_MS = 12 * 60 * 60 * 1000;

export interface UpdaterOptions {
  log: (message: string) => void;
  /** The downloaded update's version, once it is ready to install. */
  onReady: (version: string) => void;
}

/** Why updates are off for this launch, or null when they are on. */
export function updatesDisabledReason(input: {
  isPackaged: boolean;
  platform: NodeJS.Platform;
  e2e: boolean;
  portable: boolean;
  /** The NSIS uninstaller sits beside the exe: a real install, not `release/win-unpacked`. */
  installed: boolean;
}): string | null {
  if (input.platform !== 'win32') return 'not Windows';
  if (!input.isPackaged) return 'not a packaged build';
  if (input.e2e) return 'E2E run';
  // The portable exe unpacks to a temp folder on every launch: there is nothing to update in place.
  if (input.portable) return 'portable build';
  if (!input.installed) return 'not an installed copy';
  return null;
}

export class Updater {
  private readyVersion: string | null = null;
  private timer: NodeJS.Timeout | null = null;
  private checking = false;

  constructor(private readonly options: UpdaterOptions) {}

  get ready(): string | null {
    return this.readyVersion;
  }

  start(e2e: boolean): void {
    const reason = updatesDisabledReason({
      isPackaged: app.isPackaged,
      platform: process.platform,
      e2e,
      portable: Boolean(process.env.PORTABLE_EXECUTABLE_DIR),
      installed: existsSync(path.join(path.dirname(process.execPath), `Uninstall ${app.getName()}.exe`)),
    });
    if (reason) {
      this.options.log(`updates off: ${reason}`);
      return;
    }
    const updater = electronUpdater.autoUpdater;
    // The library's own log lines, minus debug, so a failed update is diagnosable
    // from Settings. They carry versions, URLs and file paths, never user data.
    updater.logger = {
      info: (message?: unknown) => this.options.log(String(message)),
      warn: (message?: unknown) => this.options.log(`warn: ${String(message)}`),
      error: (message?: unknown) => this.options.log(`error: ${String(message)}`),
      debug: () => undefined,
    };
    updater.autoDownload = true;
    // Installing is `quit()`'s job only. The library's own quit hook could also fire at
    // logoff or shutdown, and an installer cut off mid-run can leave the app half removed.
    updater.autoInstallOnAppQuit = false;
    updater.disableWebInstaller = true;
    // electron-updater sends a random per-install ID with every check (for staged rollouts,
    // which this app does not use). A fixed value keeps the check anonymous.
    updater.requestHeaders = { 'x-user-staging-id': '00000000-0000-0000-0000-000000000000' };
    updater.on('update-downloaded', (info) => {
      this.readyVersion = info.version;
      this.options.onReady(info.version);
    });
    updater.on('error', (error) => this.options.log(`error: ${error.message}`));
    const check = (): void => {
      if (this.checking || this.readyVersion) return;
      this.checking = true;
      updater
        .checkForUpdates()
        // A failed download rejects this promise too; the 'error' listener has already logged it.
        .then((result) => result?.downloadPromise?.catch(() => undefined))
        .catch((error: unknown) => this.options.log(`check failed: ${(error as Error).message}`))
        .finally(() => {
          this.checking = false;
        });
    };
    setTimeout(check, FIRST_CHECK_DELAY_MS).unref();
    this.timer = setInterval(check, CHECK_INTERVAL_MS);
    this.timer.unref();
  }

  /**
   * Run the downloaded installer silently, if there is one. Called just before the app
   * exits; the installer waits for this process to end. Returns whether it started.
   */
  installOnExit(relaunch: boolean): boolean {
    if (!this.readyVersion) return false;
    if (this.timer) clearInterval(this.timer);
    const updater = electronUpdater.autoUpdater;
    if (!(updater instanceof electronUpdater.BaseUpdater)) return false;
    try {
      return updater.install(true, relaunch);
    } catch (error) {
      this.options.log(`install failed: ${(error as Error).message}`);
      return false;
    }
  }
}
