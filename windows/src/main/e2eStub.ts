import { appendFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

/**
 * Provider stand-ins for the Playwright suite. Installed only when the app was launched
 * with `--e2e` (see `index.ts`), so a shipped build never reaches this file's code path.
 *
 * Each answers every request to its provider's host from the key in the request, so the suite
 * can walk the real key checks and the real dictation pipeline:
 *   - a key that starts with `valid`: 200 with a fixture answer
 *   - a key that starts with `slow`: the same, after 1.5 s (a check that is still running)
 *   - a key that starts with `offline`: the request fails like a dead network
 *   - any other key: 401, as the provider answers a wrong key
 * Hosts: api.deepgram.com, api.elevenlabs.io, generativelanguage.googleapis.com (Gemini voice
 * and formatting) and api.anthropic.com (formatting). Each request is appended to
 * `<userData>/e2e.log` (URL only, never the key, audio or text), so a spec can assert which
 * model the app asked for.
 */

export const E2E_TRANSCRIPT = 'Hello from Useful Voice.';
export const E2E_ELEVENLABS_TRANSCRIPT = 'Hello from Scribe, the ElevenLabs model.';
export const E2E_GEMINI_TRANSCRIPT = 'Hello from Gemini, the voice model.';

/** What the formatter stubs make of a dictation: the text, marked with who formatted it. */
export function e2eFormatted(text: string, provider: 'Gemini' | 'Anthropic'): string {
  return `${text.trim()} (${provider})`;
}

type StubHost = 'deepgram' | 'elevenlabs' | 'gemini' | 'anthropic';

const HOSTS: Array<[string, StubHost]> = [
  ['https://api.deepgram.com/', 'deepgram'],
  ['https://api.elevenlabs.io/', 'elevenlabs'],
  ['https://generativelanguage.googleapis.com/', 'gemini'],
  ['https://api.anthropic.com/', 'anthropic'],
];

function keyOf(host: StubHost, headers: Headers): string {
  switch (host) {
    case 'deepgram':
      return (headers.get('authorization') ?? '').replace(/^Token\s+/i, '');
    case 'elevenlabs':
      return headers.get('xi-api-key') ?? '';
    case 'gemini':
      return headers.get('x-goog-api-key') ?? '';
    case 'anthropic':
      return headers.get('x-api-key') ?? '';
  }
}

const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

const refused = (host: StubHost): Response => {
  switch (host) {
    case 'deepgram':
      return json({ err_code: 'INVALID_AUTH', err_msg: 'Invalid credentials.' }, 401);
    case 'elevenlabs':
      return json({ detail: { status: 'invalid_api_key', message: 'Invalid API key' } }, 401);
    case 'gemini':
      return json({ error: { code: 400, status: 'INVALID_ARGUMENT', message: 'API key not valid. API_KEY_INVALID' } }, 400);
    case 'anthropic':
      return json({ type: 'error', error: { type: 'authentication_error', message: 'invalid x-api-key' } }, 401);
  }
};

/** The dictation text out of the formatter's user message. */
function dictationIn(userMessage: string): string {
  return /<dictation>\n([\s\S]*)\n<\/dictation>/.exec(userMessage)?.[1] ?? userMessage;
}

async function answer(host: StubHost, init: RequestInit | undefined): Promise<Response> {
  const method = (init?.method ?? 'GET').toUpperCase();
  if (host === 'deepgram') {
    return json({ results: { channels: [{ alternatives: [{ transcript: E2E_TRANSCRIPT }] }], duration: 1 } });
  }
  if (host === 'elevenlabs') {
    if (method === 'GET') return json({ models: [] });
    return json({ text: E2E_ELEVENLABS_TRANSCRIPT, language_code: 'eng', audio_duration_secs: 1 });
  }
  const body = typeof init?.body === 'string' ? (JSON.parse(init.body) as Record<string, unknown>) : {};
  if (host === 'gemini') {
    if (method === 'GET') return json({ name: 'models/gemini-3.8-flash' });
    const contents = body.contents as Array<{ parts: Array<{ text?: string; inlineData?: unknown }> }> | undefined;
    const parts = contents?.[0]?.parts ?? [];
    // Audio in: this is the voice model. Text in: this is the formatter.
    const text = parts.some((part) => part.inlineData !== undefined)
      ? E2E_GEMINI_TRANSCRIPT
      : e2eFormatted(dictationIn(parts.map((part) => part.text ?? '').join('')), 'Gemini');
    return json({ candidates: [{ content: { role: 'model', parts: [{ text }] } }] });
  }
  if (method === 'GET') return json({ data: [] });
  const messages = body.messages as Array<{ content?: string }> | undefined;
  return json({ content: [{ type: 'text', text: e2eFormatted(dictationIn(messages?.[0]?.content ?? ''), 'Anthropic') }] });
}

/**
 * Parakeet's download under `--e2e`: no request leaves the machine. The "server" answers a tiny
 * archive, the "extraction" writes four one-byte files, and each URL asked for lands in e2e.log.
 */
export function parakeetE2eDeps(userData: string): {
  fetch: typeof fetch;
  extract: (archive: string, destDir: string) => Promise<void>;
  spawnWorker: () => Promise<never>;
} {
  return {
    fetch: (async (input: RequestInfo | URL) => {
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
      try {
        appendFileSync(path.join(userData, 'e2e.log'), `${new Date().toISOString()} parakeet GET ${url}\n`);
      } catch {
        // The log is a diagnostic aid only.
      }
      return new Response(new Uint8Array(64), { status: 200, headers: { 'content-length': '64' } });
    }) as typeof fetch,
    extract: async (_archive, destDir) => {
      for (const name of ['encoder.int8.onnx', 'decoder.int8.onnx', 'joiner.int8.onnx', 'tokens.txt']) {
        writeFileSync(path.join(destDir, name), 'x');
      }
    },
    // The one-byte "model" can't be loaded: no recognition process under --e2e.
    spawnWorker: async () => {
      throw new Error('no recognition worker under --e2e');
    },
  };
}

export function installProviderStubs(userData: string): void {
  const real = globalThis.fetch.bind(globalThis);
  const log = (host: StubHost, line: string): void => {
    try {
      appendFileSync(path.join(userData, 'e2e.log'), `${new Date().toISOString()} ${host} ${line}\n`);
    } catch {
      // The log is a diagnostic aid only.
    }
  };
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    const host = HOSTS.find(([prefix]) => url.startsWith(prefix))?.[1];
    if (!host) return real(input, init);
    const key = keyOf(host, new Headers(init?.headers));
    log(host, `${(init?.method ?? 'GET').toUpperCase()} ${url}`);
    if (key.startsWith('offline')) throw new TypeError('fetch failed');
    if (key.startsWith('slow')) await new Promise((resolve) => setTimeout(resolve, 1500));
    if (!key.startsWith('valid') && !key.startsWith('slow')) return refused(host);
    return answer(host, init);
  }) as typeof fetch;
}
