import { describe, expect, it, vi } from 'vitest';
import {
  ASSUMED_UPLOAD_BYTES_PER_SECOND,
  MAXIMUM_DEADLINE_SECONDS,
  MINIMUM_DEADLINE_SECONDS,
  ProviderError,
  buildRequest,
  classifyHttpError,
  deadlineForAudioBytes,
  describeErrorBody,
  parseResponse,
  parseRetryAfter,
  transcribe,
} from '../src/core/transcription/deepgramProvider.js';

const CONFIG = { apiKey: 'test-key-123', smartFormat: true };

describe('deadlineForAudioBytes', () => {
  /**
   * A fixed total deadline cannot work here: recording is capped at 10 minutes,
   * which is 19.2 MB at 16 kHz mono 16-bit, and 19.2 MB inside 15 seconds needs
   * ~10 Mbps of sustained uplink plus time for the server to decode it. The
   * advertised long-dictation feature could therefore never succeed.
   */
  it('scales with payload size', () => {
    const small = deadlineForAudioBytes(32_000);
    const large = deadlineForAudioBytes(19_200_000);
    expect(large).toBeGreaterThan(small);
  });

  it('never goes below the floor', () => {
    expect(deadlineForAudioBytes(0)).toBe(MINIMUM_DEADLINE_SECONDS);
    expect(deadlineForAudioBytes(1)).toBeGreaterThanOrEqual(MINIMUM_DEADLINE_SECONDS);
  });

  it('never exceeds the ceiling', () => {
    expect(deadlineForAudioBytes(1_000_000_000)).toBe(MAXIMUM_DEADLINE_SECONDS);
  });

  it('covers a realistic 10-minute recording at the assumed throughput', () => {
    // The longest recording the app allows must fit inside one attempt even at
    // the pessimistic assumed upload rate, otherwise the long-dictation feature
    // fails by design.
    const tenMinutes = 600 * 32_000;
    const deadline = deadlineForAudioBytes(tenMinutes);
    const requiredUploadSeconds = tenMinutes / ASSUMED_UPLOAD_BYTES_PER_SECOND;
    expect(deadline).toBeGreaterThanOrEqual(requiredUploadSeconds);
    expect(deadline).toBeLessThanOrEqual(MAXIMUM_DEADLINE_SECONDS);
  });

  it('scales proportionally below the ceiling', () => {
    // Below the ceiling the deadline is the upload estimate plus the fixed
    // processing allowance, so a doubling of payload roughly doubles it.
    const one = deadlineForAudioBytes(1_000_000);
    const two = deadlineForAudioBytes(2_000_000);
    expect(two).toBeGreaterThan(one);
    expect(two).toBeLessThan(one * 2 + 20);
  });

  it('treats a negative size as zero rather than throwing', () => {
    expect(deadlineForAudioBytes(-5)).toBe(MINIMUM_DEADLINE_SECONDS);
  });
});

describe('buildRequest', () => {
  it('uses nova-3 and the documented parameters', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
    });
    const url = new URL(request.url);
    expect(url.searchParams.get('model')).toBe('nova-3');
    expect(url.searchParams.get('language')).toBe('en');
    expect(url.searchParams.get('smart_format')).toBe('true');
  });

  it('maps auto to the multi-language mode', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'auto', keyterms: [] },
      config: CONFIG,
    });
    expect(new URL(request.url).searchParams.get('language')).toBe('multi');
  });

  it('repeats keyterm once per term', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'en', keyterms: ['Kubernetes', 'Claude Code'] },
      config: CONFIG,
    });
    expect(new URL(request.url).searchParams.getAll('keyterm')).toEqual(['Kubernetes', 'Claude Code']);
  });

  it('omits blank keyterms rather than sending an empty parameter', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'en', keyterms: ['', '  ', 'Kubernetes'] },
      config: CONFIG,
    });
    expect(new URL(request.url).searchParams.getAll('keyterm')).toEqual(['Kubernetes']);
  });

  it('sends the API key as a Token authorization header', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
    });
    expect(request.headers.Authorization).toBe('Token test-key-123');
    expect(request.headers['Content-Type']).toBe('audio/wav');
  });

  it('honours a custom endpoint', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'en', keyterms: [] },
      config: { ...CONFIG, endpoint: 'https://example.test/listen' },
    });
    expect(request.url.startsWith('https://example.test/listen?')).toBe(true);
  });

  it('encodes a term containing characters that would break the URL', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'en', keyterms: ['C++ & more'] },
      config: CONFIG,
    });
    expect(new URL(request.url).searchParams.get('keyterm')).toBe('C++ & more');
  });
});

describe('parseResponse', () => {
  it('reads the transcript, duration and detected language', () => {
    const transcript = parseResponse({
      results: {
        channels: [{ alternatives: [{ transcript: '  hello world  ' }], detected_language: 'en' }],
        duration: 1.5,
      },
    });
    expect(transcript.text).toBe('hello world');
    expect(transcript.durationSeconds).toBe(1.5);
    expect(transcript.detectedLanguage).toBe('en');
  });

  it('falls back to metadata duration', () => {
    const transcript = parseResponse({
      results: { channels: [{ alternatives: [{ transcript: 'hi' }] }] },
      metadata: { duration: 2.25 },
    });
    expect(transcript.durationSeconds).toBe(2.25);
  });

  it('returns an empty transcript for a silent response', () => {
    expect(parseResponse({ results: { channels: [{ alternatives: [{}] }] } }).text).toBe('');
  });

  it('throws a malformedResponse error on a nonsense payload', () => {
    expect(() => parseResponse(null)).toThrow(ProviderError);
    expect(() => parseResponse('nope')).toThrow(ProviderError);
  });

  it('reports a non-finite duration as null rather than NaN', () => {
    const transcript = parseResponse({ results: { duration: Number.NaN, channels: [] } });
    expect(transcript.durationSeconds).toBeNull();
  });
});

describe('describeErrorBody', () => {
  it('bounds the length and collapses whitespace', () => {
    const described = describeErrorBody(`line one\n\n  line two ${'x'.repeat(500)}`);
    expect(described.length).toBeLessThanOrEqual(300);
    expect(described).not.toContain('\n');
  });

  it('redacts the API key if the response echoes it', () => {
    expect(describeErrorBody('bad key test-key-123 here', 'test-key-123')).not.toContain('test-key-123');
  });
});

describe('classifyHttpError', () => {
  it('marks a rejected key as permanent', () => {
    const error = classifyHttpError(401, 'invalid credentials');
    expect(error.kind).toBe('unauthorized');
    expect(error.isTransient).toBe(false);
  });

  it('marks rate limiting as transient', () => {
    expect(classifyHttpError(429, '').isTransient).toBe(true);
  });

  it('marks server errors as transient', () => {
    expect(classifyHttpError(503, '').isTransient).toBe(true);
    expect(classifyHttpError(500, '').isTransient).toBe(true);
  });

  it('marks a bad request as permanent', () => {
    const error = classifyHttpError(400, 'unsupported audio');
    expect(error.kind).toBe('badRequest');
    expect(error.isTransient).toBe(false);
  });

  it('surfaces the documented keyterm ceiling message', () => {
    const body = 'Keyterm limit exceeded. The maximum number of tokens across all keyterms is 500.';
    expect(classifyHttpError(400, body).message).toContain('maximum number of tokens');
  });
});

describe('parseRetryAfter', () => {
  it('parses a seconds value', () => {
    expect(parseRetryAfter('2')).toBe(2);
  });

  it('parses an HTTP date', () => {
    const now = new Date('2026-01-01T00:00:00Z');
    expect(parseRetryAfter('Thu, 01 Jan 2026 00:00:05 GMT', now)).toBe(5);
  });

  it('caps a long wait', () => {
    expect(parseRetryAfter('9999')).toBe(60);
  });

  it('returns undefined for missing or unparseable values', () => {
    expect(parseRetryAfter(null)).toBeUndefined();
    expect(parseRetryAfter('soon')).toBeUndefined();
  });
});

/** A minimal fetch stub that records calls and replays scripted responses. */
function stubFetch(
  responses: Array<{ status?: number; body?: unknown; text?: string; headers?: Record<string, string> }>,
) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  let index = 0;
  const impl = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init ?? {} });
    const scripted = responses[Math.min(index, responses.length - 1)] ?? {};
    index += 1;
    const status = scripted.status ?? 200;
    const headers = new Headers(scripted.headers ?? {});
    const payload = scripted.body ?? { results: { channels: [{ alternatives: [{ transcript: 'ok' }] }] } };
    return new Response(
      scripted.text ?? JSON.stringify(payload),
      { status, headers },
    );
  }) as unknown as typeof fetch;
  return { impl, calls, count: () => index };
}

const AUDIO = new Uint8Array(1024);

describe('transcribe', () => {
  it('returns the parsed transcript on success', async () => {
    const { impl, calls } = stubFetch([{ body: { results: { channels: [{ alternatives: [{ transcript: 'hello' }] }] } } }]);
    const result = await transcribe({
      audio: AUDIO,
      hint: { language: 'en', keyterms: ['Kubernetes'] },
      config: CONFIG,
      fetchImpl: impl,
    });
    expect(result.text).toBe('hello');
    expect(calls).toHaveLength(1);
    expect(calls[0]?.init.method).toBe('POST');
  });

  it('retries a transient server error and then succeeds', async () => {
    const { impl, count } = stubFetch([
      { status: 503, text: 'unavailable' },
      { body: { results: { channels: [{ alternatives: [{ transcript: 'recovered' }] }] } } },
    ]);
    const result = await transcribe({
      audio: AUDIO,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
      fetchImpl: impl,
      sleep: async () => {},
    });
    expect(result.text).toBe('recovered');
    expect(count()).toBe(2);
  });

  it('honours Retry-After to size the backoff', async () => {
    const sleeps: number[] = [];
    const { impl } = stubFetch([
      { status: 429, text: 'slow down', headers: { 'retry-after': '3' } },
      { body: { results: { channels: [{ alternatives: [{ transcript: 'ok' }] }] } } },
    ]);
    await transcribe({
      audio: AUDIO,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
      fetchImpl: impl,
      sleep: async (ms) => { sleeps.push(ms); },
    });
    expect(sleeps).toEqual([3000]);
  });

  it('caps a large Retry-After so the user is not left waiting', async () => {
    const sleeps: number[] = [];
    const { impl } = stubFetch([
      { status: 429, text: 'slow down', headers: { 'retry-after': '9999' } },
      { body: { results: { channels: [{ alternatives: [{ transcript: 'ok' }] }] } } },
    ]);
    await transcribe({
      audio: AUDIO,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
      fetchImpl: impl,
      sleep: async (ms) => { sleeps.push(ms); },
    });
    expect(sleeps[0]).toBeLessThanOrEqual(8000);
  });

  it('does not retry a rejected API key', async () => {
    const { impl, count } = stubFetch([{ status: 401, text: 'bad key' }]);
    await expect(transcribe({
      audio: AUDIO,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
      fetchImpl: impl,
      sleep: async () => {},
    })).rejects.toThrow(/rejected/);
    expect(count()).toBe(1);
  });

  it('gives up after the attempt limit on persistent transient failures', async () => {
    const { impl, count } = stubFetch([{ status: 503, text: 'down' }]);
    await expect(transcribe({
      audio: AUDIO,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
      fetchImpl: impl,
      maxAttempts: 3,
      sleep: async () => {},
    })).rejects.toThrow(ProviderError);
    expect(count()).toBe(3);
  });

  it('maps an aborted request to a cancellation error', async () => {
    const controller = new AbortController();
    controller.abort();
    const { impl, count } = stubFetch([{ body: {} }]);
    await expect(transcribe({
      audio: AUDIO,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
      fetchImpl: impl,
      signal: controller.signal,
    })).rejects.toMatchObject({ kind: 'cancelled' });
    expect(count()).toBe(0);
  });

  it('maps a timeout to a timedOut error with the deadline in the message', async () => {
    const impl = (async () => {
      const timeout = new Error('The operation was aborted due to timeout');
      timeout.name = 'TimeoutError';
      throw timeout;
    }) as unknown as typeof fetch;
    await expect(transcribe({
      audio: AUDIO,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
      fetchImpl: impl,
      maxAttempts: 1,
    })).rejects.toMatchObject({ kind: 'timedOut' });
  });

  it('maps a network failure to a transport error', async () => {
    const impl = vi.fn(async () => { throw new Error('getaddrinfo ENOTFOUND'); }) as unknown as typeof fetch;
    await expect(transcribe({
      audio: AUDIO,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
      fetchImpl: impl,
      maxAttempts: 1,
    })).rejects.toMatchObject({ kind: 'transport' });
  });

  it('maps an unparseable body to a malformedResponse error', async () => {
    const { impl } = stubFetch([{ text: 'not json at all' }]);
    await expect(transcribe({
      audio: AUDIO,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
      fetchImpl: impl,
      maxAttempts: 1,
    })).rejects.toMatchObject({ kind: 'malformedResponse' });
  });

  it('sends the audio as the request body', async () => {
    const { impl, calls } = stubFetch([{ body: {} }]);
    const audio = new Uint8Array([1, 2, 3, 4]);
    await transcribe({
      audio,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
      fetchImpl: impl,
    });
    expect(new Uint8Array(calls[0]?.init.body as Uint8Array)).toEqual(audio);
  });
});
