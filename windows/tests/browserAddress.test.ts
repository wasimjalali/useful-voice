import { execFile, execFileSync, spawn, type ChildProcess } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { pageKey } from '../src/core/delivery/deliveryTarget.js';
import { DELIVERY_ADDRESS_MS } from '../src/main/deliveryGlue.js';
import { browserAddressScript } from '../src/main/powershellScripts.js';

/**
 * The address-bar read against a real Edge on Windows (CI's windows job): the target
 * lock compares page addresses, so the read has to return the address bar and nothing
 * else. The page puts a focused text field holding another address first in the page,
 * which the old "first edit control" read would have returned.
 *
 * Skipped where there is no Edge. When Edge never opens a window it fails on CI (the
 * windows-latest runner has Edge, so a skip there would hide a broken check) and skips
 * elsewhere. A wrong or missing read fails, and so do two or more warm reads slower than
 * a delivery waits for (`DELIVERY_ADDRESS_MS`), which would switch the page check off
 * unseen. It runs alone (`vitest.desktop.config.ts`): beside the other test files, a read
 * timed a C# compile on the same runner.
 */
const edge = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
].find((candidate) => process.platform === 'win32' && existsSync(candidate));

const TITLE = 'uv-address-check';

// Edge's first start on a fresh runner profile can take most of a minute on a slow runner,
// so one PowerShell waits for the window inside its own loop (no new PowerShell per look),
// and its call gets room for a slow PowerShell start on top. A call that still times out
// only means "no window yet". The test's own limit is built from the same numbers, so it
// can't expire before the wait plus the reads.
const WINDOW_WAIT_MS = 90_000;
const WINDOW_WAIT_CALL_MS = WINDOW_WAIT_MS + 60_000;
const READ_ATTEMPTS = 5;
const READ_CALL_MS = 30_000;
const READ_PAUSE_MS = 1500;
// Warm reads are timed, not killed at the cap: one slow sample on a shared runner is
// noise, a second one is a read that no longer reliably fits a delivery.
const WARM_RUNS = 5;
const WARM_CALL_MS = 10_000;
const TEST_TIMEOUT_MS =
  WINDOW_WAIT_CALL_MS + READ_ATTEMPTS * (READ_CALL_MS + READ_PAUSE_MS) + WARM_RUNS * 2 * WARM_CALL_MS + 30_000;

/** Whether `error` is `execFile` killing a script that ran past its timeout. */
function timedOut(error: unknown): boolean {
  return (error as { killed?: boolean } | undefined)?.killed === true;
}

/**
 * Asynchronous on purpose: the page Edge loads is served by this same process, so a
 * synchronous spawn would leave Edge's request unanswered for as long as the script runs.
 */
function powershell(script: string, timeout = 30_000): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
      { encoding: 'utf8', timeout, windowsHide: true },
      (error, stdout) => (error ? reject(error) : resolve(stdout)),
    );
  });
}

describe.skipIf(!edge)('address bar read on a real Edge', () => {
  let server: Server;
  let port = 0;
  let browser: ChildProcess | null = null;
  let profile = '';

  beforeAll(async () => {
    server = createServer((_request, response) => {
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      response.end(
        `<!doctype html><title>${TITLE}</title>` +
          '<input id="decoy" type="text" value="https://decoy.example/not-the-page" autofocus>',
      );
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    port = (server.address() as AddressInfo).port;
    profile = mkdtempSync(path.join(os.tmpdir(), 'uv-edge-'));
    browser = spawn(
      edge!,
      [
        `--user-data-dir=${profile}`,
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-sync',
        '--new-window',
        `http://127.0.0.1:${port}/compose?draft=1#top`,
      ],
      { stdio: 'ignore' },
    );
  }, 30_000);

  afterAll(() => {
    if (browser?.pid) {
      try {
        execFileSync('taskkill', ['/PID', String(browser.pid), '/T', '/F'], { stdio: 'ignore' });
      } catch {
        // Already gone.
      }
    }
    server?.close();
    try {
      rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 });
    } catch {
      // Edge can hold the profile a moment after it exits; the runner is thrown away.
    }
  });

  it('returns the page address, not the focused field on the page', async (ctx) => {
    let out = '';
    try {
      out = (
        await powershell(
          `$deadline = (Get-Date).AddMilliseconds(${WINDOW_WAIT_MS})
do {
  $handle = Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like '*${TITLE}*' } | Select-Object -First 1 -ExpandProperty MainWindowHandle
  if ($handle) { Write-Output $handle; exit 0 }
  Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)`,
          WINDOW_WAIT_CALL_MS,
        )
      ).trim();
    } catch (error) {
      // A PowerShell that was too slow to start is "no window yet"; anything else is a real failure.
      if (!timedOut(error)) throw error;
    }
    const handle = Number(out) || 0;
    if (handle === 0) {
      if (process.env.CI) expect.fail('Edge never opened a window, so the address bar read was not checked');
      ctx.skip();
    }

    let value = '';
    // UI Automation on a page that just loaded can need a moment to build its tree.
    for (let attempt = 0; attempt < READ_ATTEMPTS && value === ''; attempt += 1) {
      const encoded = (await powershell(browserAddressScript(handle, 'chromium'), READ_CALL_MS)).trim().split(/\r?\n/).pop() ?? '';
      value = encoded ? Buffer.from(encoded, 'base64').toString('utf8').trim() : '';
      if (value === '') await new Promise((resolve) => setTimeout(resolve, READ_PAUSE_MS));
    }
    expect(value).toContain(`127.0.0.1:${port}/compose?draft=1`);
    expect(value).not.toContain('decoy.example');
    // The way `browserAddress` completes it, the same at the press and at delivery.
    const address = /^[a-z][a-z0-9+.-]*:\/\//i.test(value) ? value : `https://${value}`;
    expect(pageKey(address)).toMatch(new RegExp(`^https?://127\\.0\\.0\\.1:${port}/compose\\?draft=1$`));

    // Warm, the whole read (PowerShell start included) fits what a delivery waits for. A bare
    // PowerShell start is timed beside each read, so the log shows how much of it is the start.
    const timings: number[] = [];
    const starts: number[] = [];
    for (let run = 0; run < WARM_RUNS; run += 1) {
      let started = Date.now();
      try {
        await powershell('exit 0', WARM_CALL_MS);
        starts.push(Date.now() - started);
      } catch (error) {
        if (!timedOut(error)) throw error;
        starts.push(WARM_CALL_MS);
      }
      started = Date.now();
      try {
        const encoded = (await powershell(browserAddressScript(handle, 'chromium'), WARM_CALL_MS)).trim().split(/\r?\n/).pop() ?? '';
        timings.push(Date.now() - started);
        expect(Buffer.from(encoded, 'base64').toString('utf8')).toContain(`127.0.0.1:${port}/compose?draft=1`);
      } catch (error) {
        if (!timedOut(error)) throw error;
        timings.push(WARM_CALL_MS);
      }
    }
    const median = (values: number[]): number => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
    console.log(
      `address bar read, warm: ${timings.join(', ')} ms (median ${median(timings)}, cap ${DELIVERY_ADDRESS_MS} ms); ` +
        `PowerShell start alone: ${starts.join(', ')} ms (median ${median(starts)})`,
    );
    const over = timings.filter((ms) => ms > DELIVERY_ADDRESS_MS).length;
    expect(over, `warm reads ${timings.join(', ')} ms, ${over} over the cap`).toBeLessThanOrEqual(1);
  }, TEST_TIMEOUT_MS);
});
