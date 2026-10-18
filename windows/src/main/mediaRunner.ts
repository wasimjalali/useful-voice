import { PowerShellHostError } from './powershellHost.js';
import { runHosted, type OneShotRunner, type ScriptHost, type Timeouts } from './keystroke.js';

/**
 * Runs the media scripts in their PowerShell host, with the one-shot fallback the other
 * scripts have, and one rule of its own: after `dispose`, nothing runs. A host that is
 * disposed rejects what it still had queued as "unavailable, never sent", which the usual
 * fallback would answer by starting a one-shot process, so a pause queued behind the
 * resume at quit would run after the app had played the media again and left. Here a
 * disposed runner refuses the request instead, whether it is new or was already waiting.
 *
 * No Electron import, so the rule is tested with a fake host on any platform.
 */
export interface MediaRunnerDeps {
  host: () => ScriptHost;
  oneShot: OneShotRunner;
  timeouts: Timeouts;
}

export interface MediaRunner {
  run(hostScript: string, oneShotScript: string): Promise<string>;
  dispose(): void;
  readonly disposed: boolean;
}

export function createMediaRunner(deps: MediaRunnerDeps): MediaRunner {
  let disposed = false;
  const refusal = (): PowerShellHostError => new PowerShellHostError('aborted', 'the media service was shut down', false);
  const oneShot: OneShotRunner = async (script, timeoutMs, signal) => {
    if (disposed) throw refusal();
    return deps.oneShot(script, timeoutMs, signal);
  };
  return {
    run(hostScript, oneShotScript) {
      if (disposed) return Promise.reject(refusal());
      return runHosted(deps.host(), oneShot, hostScript, oneShotScript, deps.timeouts);
    },
    dispose() {
      disposed = true;
    },
    get disposed() {
      return disposed;
    },
  };
}
