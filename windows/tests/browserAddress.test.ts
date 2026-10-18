import { execFileSync, spawn, type ChildProcess } from 'node:child_process';
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
 * elsewhere. A wrong or missing read fails, and so does a read slower than a delivery
 * waits for (`DELIVERY_ADDRESS_MS`), which would switch the page check off unseen.
 */
const edge = [
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
].find((candidate) => process.platform === 'win32' && existsSync(candidate));

const TITLE = 'uv-address-check';

function powershell(script: string, timeout = 30_000): string {
  return execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script], {
    encoding: 'utf8',
    timeout,
    windowsHide: true,
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
    let handle = 0;
    const deadline = Date.now() + 45_000;
    while (Date.now() < deadline && handle === 0) {
      const out = powershell(
        `Get-Process msedge -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like '*${TITLE}*' } | Select-Object -First 1 -ExpandProperty MainWindowHandle`,
      ).trim();
      handle = Number(out) || 0;
      if (handle === 0) await new Promise((resolve) => setTimeout(resolve, 1000));
    }
    if (handle === 0) {
      if (process.env.CI) expect.fail('Edge never opened a window, so the address bar read was not checked');
      ctx.skip();
    }

    let value = '';
    // UI Automation on a page that just loaded can need a moment to build its tree.
    for (let attempt = 0; attempt < 5 && value === ''; attempt += 1) {
      const encoded = powershell(browserAddressScript(handle, 'chromium')).trim().split(/\r?\n/).pop() ?? '';
      value = encoded ? Buffer.from(encoded, 'base64').toString('utf8').trim() : '';
      if (value === '') await new Promise((resolve) => setTimeout(resolve, 1500));
    }
    expect(value).toContain(`127.0.0.1:${port}/compose?draft=1`);
    expect(value).not.toContain('decoy.example');
    // The way `browserAddress` completes it, the same at the press and at delivery.
    const address = /^[a-z][a-z0-9+.-]*:\/\//i.test(value) ? value : `https://${value}`;
    expect(pageKey(address)).toMatch(new RegExp(`^https?://127\\.0\\.0\\.1:${port}/compose\\?draft=1$`));

    // Warm, the whole read (PowerShell start included) fits what a delivery waits for.
    const timings: number[] = [];
    for (let run = 0; run < 3; run += 1) {
      const started = Date.now();
      const encoded = powershell(browserAddressScript(handle, 'chromium'), DELIVERY_ADDRESS_MS).trim().split(/\r?\n/).pop() ?? '';
      timings.push(Date.now() - started);
      expect(Buffer.from(encoded, 'base64').toString('utf8')).toContain(`127.0.0.1:${port}/compose?draft=1`);
    }
    console.log(`address bar read, warm: ${timings.join(', ')} ms (cap ${DELIVERY_ADDRESS_MS} ms)`);
  }, 120_000);
});
