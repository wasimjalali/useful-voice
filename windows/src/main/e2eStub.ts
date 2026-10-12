import { appendFileSync } from 'node:fs';
import path from 'node:path';

/**
 * Deepgram stand-in for the Playwright suite. Installed only when the app was launched
 * with `--e2e` (see `index.ts`), so a shipped build never reaches this file's code path.
 *
 * It answers every request to api.deepgram.com from the key in the `Authorization`
 * header, so the suite can walk the real key check and the real dictation pipeline:
 *   - a key that starts with `valid`: 200 with a fixture transcript
 *   - a key that starts with `slow`: the same, after 1.5 s (a check that is still running)
 *   - a key that starts with `offline`: the request fails like a dead network
 *   - any other key: 401, as Deepgram answers a wrong key
 * Each request is appended to `<userData>/e2e.log` (URL only, never the key or audio),
 * so a spec can assert which language the app asked for.
 */

export const E2E_TRANSCRIPT = 'Hello from Useful Voice.';

export function installDeepgramStub(userData: string): void {
  const real = globalThis.fetch.bind(globalThis);
  const log = (line: string): void => {
    try {
      appendFileSync(path.join(userData, 'e2e.log'), `${new Date().toISOString()} deepgram ${line}\n`);
    } catch {
      // The log is a diagnostic aid only.
    }
  };
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (!url.startsWith('https://api.deepgram.com/')) return real(input, init);
    const headers = new Headers(init?.headers);
    const key = (headers.get('authorization') ?? '').replace(/^Token\s+/i, '');
    log(url);
    if (key.startsWith('offline')) throw new TypeError('fetch failed');
    if (key.startsWith('slow')) await new Promise((resolve) => setTimeout(resolve, 1500));
    if (!key.startsWith('valid') && !key.startsWith('slow')) {
      return new Response(JSON.stringify({ err_code: 'INVALID_AUTH', err_msg: 'Invalid credentials.' }), {
        status: 401,
        headers: { 'content-type': 'application/json' },
      });
    }
    return new Response(
      JSON.stringify({
        results: { channels: [{ alternatives: [{ transcript: E2E_TRANSCRIPT }] }], duration: 1 },
      }),
      { status: 200, headers: { 'content-type': 'application/json' } },
    );
  }) as typeof fetch;
}
