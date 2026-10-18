/**
 * How every way of ending the app reaches the one orderly quit (`runQuit` in `index.ts`),
 * so what must happen before exit, such as playing paused media again, happens once on all
 * of them. No Electron import: the handlers take the event as a parameter and the app as
 * injected functions, so they are driven by fake events in tests.
 *
 * Three ways in:
 *  - Our own Quit (the tray, the window, an update restart) calls `quit()` directly.
 *  - Anything else that calls `app.quit()` (an installer asking us to close, another part of
 *    the app) emits `before-quit`. It is stopped there and routed into `quit()`, which
 *    runs once however often it is asked.
 *  - Windows ending the session (logoff, shutdown, restart). For the pinned Electron (43.7.0)
 *    the documented events are `query-session-end` on a window, which may be vetoed with
 *    `preventDefault()` (the docs advise against it unless data is at risk), and then
 *    `session-end`, after which "there is no way to prevent the session from ending". Electron
 *    gives that second event no time of its own: unless the app is already quitting, the
 *    process is ended right after it, so async work started there never finishes.
 *    So `session-end` asks Electron to quit (`app.quit()`), which makes the app "quitting" as
 *    far as Windows handling is concerned, lets `before-quit` through, and then `will-quit`
 *    is held (`preventDefault`) while the orderly quit, media resume included, runs to its
 *    own `app.exit`.
 *
 * `query-session-end` is deliberately not handled: it is a question, not an ending. Other
 * apps can still veto the shutdown after it, and resuming media there would switch off the
 * pause feature for the rest of a session that carries on. Vetoing it ourselves to buy time
 * would hold up the person's logoff for music, which the docs advise against.
 */
export interface QuitEvent {
  preventDefault(): void;
}

export interface QuitCoordinatorDeps {
  /** The orderly quit: runs once however often it is called, and ends in `app.exit`. */
  quit: () => Promise<void>;
  /** Asks Electron to quit (`app.quit()`), which marks the app as quitting for Windows. */
  requestAppQuit: () => void;
  /** Plays paused media again, within a budget. Runs once; later calls share it. */
  shutdownMedia: (budgetMs: number) => Promise<unknown>;
}

/** Windows gives a session end very little time: the media gets about a second. */
export const SESSION_END_MEDIA_BUDGET_MS = 1000;

/**
 * What the last step of an orderly quit does about a downloaded update. A logoff or shutdown
 * must not start the installer (nor relaunch): the person is leaving, and an installer
 * spawned into a closing session is killed halfway or surprises them at the next login. The
 * update then installs on a normal quit, or the next time they choose Restart to update.
 */
export function installerPlan(input: { restartToUpdate: boolean; sessionEnded: boolean }): {
  install: boolean;
  relaunch: boolean;
} {
  if (input.sessionEnded) return { install: false, relaunch: false };
  // Whether an update is waiting is the updater's to say: it is asked on every other quit.
  return { install: true, relaunch: input.restartToUpdate };
}

export class QuitCoordinator {
  private sessionEnding = false;

  /** Windows is ending the session: the quit that follows is a logoff or shutdown. */
  get sessionEnded(): boolean {
    return this.sessionEnding;
  }

  constructor(private readonly deps: QuitCoordinatorDeps) {}

  /** `app.on('before-quit')`. */
  onBeforeQuit(event: QuitEvent): void {
    // The session is ending: Electron's own quit must go on, to `will-quit`, which holds it.
    if (this.sessionEnding) return;
    // Otherwise the orderly quit takes over, and a second quit while it runs is held too,
    // since the orderly quit ends in `app.exit` by itself.
    event.preventDefault();
    void this.deps.quit();
  }

  /** `window.on('session-end')`, from every window that gets it. */
  onSessionEnd(): void {
    if (this.sessionEnding) return;
    this.sessionEnding = true;
    // Started now, in case the process is ended sooner than the orderly quit can finish.
    void this.deps.shutdownMedia(SESSION_END_MEDIA_BUDGET_MS);
    this.deps.requestAppQuit();
  }

  /** `app.on('will-quit')`: Electron's quit has got as far as exiting. */
  onWillQuit(event: QuitEvent): void {
    // Only the session end holds the exit; any other quit already went through `quit()`.
    // Held even if the orderly quit is already running: it ends in `app.exit` by itself.
    if (!this.sessionEnding) return;
    event.preventDefault();
    void this.deps.quit();
  }
}
