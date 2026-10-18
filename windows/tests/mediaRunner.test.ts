import { describe, expect, it } from 'vitest';
import { createMediaRunner } from '../src/main/mediaRunner.js';
import { PowerShellHostError } from '../src/main/powershellHost.js';

/** A host whose queued requests wait until it is stopped, then fail the way the real one does. */
function fakeHost() {
  const queued: Array<(error: PowerShellHostError) => void> = [];
  let unavailable = false;
  return {
    get isUnavailable() {
      return unavailable;
    },
    run(): Promise<string> {
      if (unavailable) return Promise.reject(new PowerShellHostError('unavailable', 'stopped', false));
      return new Promise<string>((_resolve, reject) => queued.push(reject));
    },
    /** What `PowerShellHost.dispose` does: reject everything waiting as unavailable and never sent. */
    stop(): void {
      unavailable = true;
      for (const reject of queued.splice(0)) reject(new PowerShellHostError('unavailable', 'the PowerShell host was stopped', false));
    },
  };
}

const timeouts = { hostMs: 1000, oneShotMs: 1000 };

describe('createMediaRunner', () => {
  it('falls back to a one-shot process when the host is unavailable, as the other scripts do', async () => {
    const host = fakeHost();
    host.stop();
    const runner = createMediaRunner({ host: () => host, oneShot: async () => 'one-shot output', timeouts });
    await expect(runner.run('host', 'one-shot')).resolves.toBe('one-shot output');
  });

  it('drops a request that was queued when it is disposed, rather than rerouting it to a one-shot process', async () => {
    const host = fakeHost();
    let oneShots = 0;
    const runner = createMediaRunner({
      host: () => host,
      oneShot: async () => {
        oneShots += 1;
        return 'ran';
      },
      timeouts,
    });
    const queuedPause = runner.run('pause', 'prelude pause');
    // Quit: the runner is disposed, then the host stops and rejects what it still held.
    runner.dispose();
    host.stop();
    await expect(queuedPause).rejects.toMatchObject({ kind: 'aborted', sent: false });
    expect(oneShots).toBe(0);
  });

  it('refuses a new request once disposed, without touching the host or a one-shot', async () => {
    let touched = 0;
    const runner = createMediaRunner({
      host: () => {
        touched += 1;
        return fakeHost();
      },
      oneShot: async () => {
        touched += 1;
        return 'ran';
      },
      timeouts,
    });
    runner.dispose();
    await expect(runner.run('x', 'y')).rejects.toMatchObject({ kind: 'aborted' });
    expect(touched).toBe(0);
    expect(runner.disposed).toBe(true);
  });
});
