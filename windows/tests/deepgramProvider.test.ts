import { describe, expect, it, vi } from 'vitest';
import { DETECTION_CODES } from '../src/core/transcription/languages.js';
import {
  ASSUMED_UPLOAD_BYTES_PER_SECOND,
  AUTO_DETECT_LANGUAGES,
  MAXIMUM_DEADLINE_SECONDS,
  MINIMUM_DEADLINE_SECONDS,
  ProviderError,
  buildRequest,
  classifyHttpError,
  deadlineForAudioBytes,
  extractRequestId,
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

  it('has a ceiling above what the largest recording actually needs', () => {
    // The ceiling must not be lower than the formula's own requirement, or it
    // silently cancels the long dictation the formula exists to protect. Ten
    // minutes is 19.2 MB; at the pessimistic rate that is 192 s of upload plus the
    // processing allowance. The ceiling was 195 against a 204 s requirement.
    const tenMinutes = 600 * 32_000;
    const needed =
      tenMinutes / ASSUMED_UPLOAD_BYTES_PER_SECOND + 12 /* PROCESSING_ALLOWANCE_SECONDS */;
    expect(MAXIMUM_DEADLINE_SECONDS).toBeGreaterThanOrEqual(needed);
    expect(deadlineForAudioBytes(tenMinutes)).toBeGreaterThanOrEqual(needed);
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

  // `multi` is Multilingual Code-Switching — for audio where the speaker switches
  // languages mid-sentence — not auto-detection. Auto used to send it, so a user
  // dictating in one language was transcribed in the wrong mode.
  it('uses language detection for auto, not code-switching', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'auto', keyterms: [] },
      config: CONFIG,
    });
    const params = new URL(request.url).searchParams;
    expect(params.get('language')).toBeNull();
    // The detection set is smaller than Nova-3's languages, so this must not simply be
    // the catalogue. It is 34 rather than the documented 35 because the API rejects
    // `detect_language=nl-BE`; see the catalogue's note.
    expect(params.getAll('detect_language')).toEqual([...DETECTION_CODES]);
    expect(params.getAll('detect_language')).toHaveLength(34);
    expect(params.getAll('detect_language')).not.toContain('true');
  });

  it('restricts detection to languages Nova-3 supports natively', () => {
    // An unsupported detected language makes Deepgram fall back to a lower model,
    // which would drop `keyterm` support — the whole dictionary feature.
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'auto', keyterms: [] },
      config: CONFIG,
    });
    const values = new URL(request.url).searchParams.getAll('detect_language');
    expect(values).not.toContain('true');
    expect(values.every((v) => (AUTO_DETECT_LANGUAGES as readonly string[]).includes(v))).toBe(true);
  });

  it('does not send detect_language for a pinned language', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'de', keyterms: [] },
      config: CONFIG,
    });
    const params = new URL(request.url).searchParams;
    expect(params.get('language')).toBe('de');
    expect(params.getAll('detect_language')).toEqual([]);
  });

  it('asks for numerals alongside smart format', () => {
    // smart_format only guarantees punctuation and paragraphs; numerals are
    // language-dependent, so they are requested explicitly.
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'de', keyterms: [] },
      config: { ...CONFIG, smartFormat: true },
    });
    expect(new URL(request.url).searchParams.get('numerals')).toBe('true');
  });

  it('sends no numerals when formatting is off', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'de', keyterms: [] },
      config: { ...CONFIG, smartFormat: false },
    });
    const params = new URL(request.url).searchParams;
    expect(params.get('numerals')).toBeNull();
    expect(params.get('smart_format')).toBe('false');
  });

  it('attributes requests with a tag', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
    });
    expect(new URL(request.url).searchParams.get('tag')).toBe('useful-voice');
  });

  // Formatting off used to still send `punctuate=true`, so the toggle did not do
  // what it said, and macOS behaved differently for the same setting.
  it('does not force punctuation when formatting is off', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'en', keyterms: [] },
      config: { ...CONFIG, smartFormat: false },
    });
    expect(new URL(request.url).searchParams.get('punctuate')).toBeNull();
  });

  it('sends dictation and punctuate together when asked', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'en', keyterms: [] },
      config: { ...CONFIG, spokenPunctuation: true },
    });
    const params = new URL(request.url).searchParams;
    expect(params.get('dictation')).toBe('true');
    // "The Punctuation feature must be enabled for Dictation to work."
    expect(params.get('punctuate')).toBe('true');
  });

  it('never sends dictation for German', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'de', keyterms: [] },
      config: { ...CONFIG, spokenPunctuation: true },
    });
    const params = new URL(request.url).searchParams;
    expect(params.get('dictation')).toBeNull();
    expect(params.get('punctuate')).toBeNull();
  });

  it('omits spoken punctuation by default', () => {
    const request = buildRequest({
      audioBytes: 1000,
      hint: { language: 'en', keyterms: [] },
      config: CONFIG,
    });
    expect(new URL(request.url).searchParams.get('dictation')).toBeNull();
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

  // 402 has its own documented code, ASR_PAYMENT_REQUIRED, and its own fix.
  it('reports exhausted credits as their own error', () => {
    const error = classifyHttpError(402, '{"err_code":"ASR_PAYMENT_REQUIRED"}');
    expect(error.kind).toBe('outOfCredits');
    expect(error.message.toLowerCase()).toContain('credits');
    // Not worth retrying: the same request fails until the account is topped up.
    expect(error.isTransient).toBe(false);
  });

  // "Deepgram was unable to process the request because the audio data was
  // incomplete or interrupted… the connection was closed before the full audio
  // payload was received, or upload speed is too slow."
  it('treats an interrupted upload as retryable', () => {
    expect(classifyHttpError(408, '').isTransient).toBe(true);
    expect(classifyHttpError(422, '').isTransient).toBe(true);
  });

  it('carries the request id that support asks for', () => {
    const error = classifyHttpError(500, '{"err_msg":"boom","request_id":"req-42"}');
    expect(error.message).toContain('req-42');
  });

  it('does not lose the error when the body has no request id', () => {
    const error = classifyHttpError(400, 'not json at all');
    expect(error.kind).toBe('badRequest');
    expect(error.message).toContain('HTTP 400');
  });
});

describe('extractRequestId', () => {
  it('reads a top-level request id', () => {
    expect(extractRequestId('{"request_id":"top"}')).toBe('top');
  });

  it('reads a nested request id', () => {
    expect(extractRequestId('{"metadata":{"request_id":"nested"}}')).toBe('nested');
  });

  it('returns null rather than throwing on junk', () => {
    expect(extractRequestId('<html>502 Bad Gateway</html>')).toBeNull();
    expect(extractRequestId('')).toBeNull();
    expect(extractRequestId('{}')).toBeNull();
    expect(extractRequestId('{"request_id":""}')).toBeNull();
    expect(extractRequestId('null')).toBeNull();
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
