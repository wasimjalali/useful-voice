/**
 * Deepgram Nova-3 pre-recorded transcription.
 *
 * Kept free of Electron so the request construction and error classification can
 * be unit-tested against a stubbed fetch.
 * https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded
 */

import {
  DETECTION_CODES,
  supportsSpokenPunctuation as supportsSpokenPunctuationCode,
} from './languages.js';

export interface DeepgramConfig {
  apiKey: string;
  smartFormat: boolean;
  /**
   * Convert spoken punctuation commands ("period", "new line") into the
   * characters themselves, via Deepgram's Dictation feature.
   *
   * Off by default and never implied by `smartFormat`: it changes what the words
   * mean rather than how they are formatted. English only.
   * https://developers.deepgram.com/docs/dictation
   */
  spokenPunctuation?: boolean;
  /** Overrides the default endpoint; used by tests. */
  endpoint?: string;
}

export interface TranscriptionHint {
  language: string;
  /** At most a few hundred entries; always bounded by the keyterm budget. */
  keyterms: string[];
}

export interface Transcript {
  text: string;
  /** Provider-reported duration, when present. */
  durationSeconds: number | null;
  detectedLanguage: string | null;
}

export type ProviderErrorKind =
  | 'unauthorized'
  | 'badRequest'
  /**
   * The Deepgram project is out of credits (HTTP 402).
   *
   * Separate from `badRequest` because it is the one failure the user can fix in
   * a minute and the docs give it its own code, `ASR_PAYMENT_REQUIRED`: "Project
   * does not have enough credits for an ASR request and does not have an overage
   * agreement." Reported as a generic 400 it sends the user hunting for a problem
   * with their audio instead of topping up.
   */
  | 'outOfCredits'
  | 'rateLimited'
  | 'serverError'
  | 'timedOut'
  | 'transport'
  | 'cancelled'
  | 'malformedResponse';

export class ProviderError extends Error {
  readonly kind: ProviderErrorKind;
  readonly status?: number;
  /** Seconds to wait, from `Retry-After`, when the server supplied it. */
  readonly retryAfterSeconds?: number;

  constructor(
    kind: ProviderErrorKind,
    message: string,
    options: { status?: number; retryAfterSeconds?: number } = {},
  ) {
    super(message);
    this.name = 'ProviderError';
    this.kind = kind;
    this.status = options.status;
    this.retryAfterSeconds = options.retryAfterSeconds;
  }

  /**
   * Whether retrying the same request could plausibly succeed.
   *
   * A wrong API key or malformed audio will fail identically forever, so retrying
   * only makes the user wait longer for the same error.
   */
  get isTransient(): boolean {
    return (
      this.kind === 'rateLimited' ||
      this.kind === 'serverError' ||
      this.kind === 'timedOut' ||
      this.kind === 'transport'
    );
  }
}

export const DEFAULT_ENDPOINT = 'https://api.deepgram.com/v1/listen';

/**
 * The languages this app offers, used to restrict auto-detection.
 *
 * Sending the bare boolean `detect_language=true` would let Deepgram pick any
 * language it supports; restricting the list keeps detection inside languages
 * Nova-3 handles natively, so the documented model fallback cannot take the
 * request off Nova-3 and silently drop `keyterm` support.
 * https://developers.deepgram.com/docs/language-detection
 */
export const AUTO_DETECT_LANGUAGES = DETECTION_CODES;

/**
 * Whether spoken punctuation applies to a language.
 *
 * Deepgram documents Dictation as "English (all available regions)" only, so it
 * is suppressed for German rather than sent and ignored.
 */
export function supportsSpokenPunctuation(language: string): boolean {
  // Modes cannot promise English-only dictation: auto has not identified a
  // language yet, and code-switching may include non-English.
  if (language === 'auto' || language === 'multi') return false;
  return supportsSpokenPunctuationCode(language);
}

/**
 * Deadline components.
 *
 * A fixed total deadline cannot work for this app: recording is capped at 10
 * minutes, which at 16 kHz mono 16-bit is 19.2 MB. Delivering that inside a
 * fixed 15 seconds needs ~10 Mbps of sustained uplink, and the same window also
 * has to cover the TLS handshake and the server decoding a 10-minute file. The
 * result was that the advertised long-dictation feature could never succeed, and
 * the retry re-uploaded the same payload to time out again.
 */
export const MINIMUM_DEADLINE_SECONDS = 15;
/**
 * Hard ceiling on one attempt.
 *
 * Sized so that even the worst case this app can produce — a 10-minute dictation
 * (19.2 MB at 16 kHz mono 16-bit) uploading at the pessimistic assumed rate, plus
 * the processing allowance — is covered rather than cut off. A lower ceiling would
 * reintroduce exactly the bug this replaced: the advertised long-dictation
 * feature failing because the deadline assumed a fast connection.
 *
 * That worst case needs 19.2 MB / 100 kB/s + 12 s = **204 s**, so the ceiling must
 * exceed 204. It was 195, which is below the requirement its own comment states:
 * the ceiling silently cancelled the very recording it was written to protect.
 */
export const MAXIMUM_DEADLINE_SECONDS = 210;
/**
 * Upload throughput floor, in bytes per second, assumed when sizing the deadline.
 * ~100 KB/s is a pessimistic mobile/congested figure, so the deadline is generous
 * on any real connection.
 */
export const ASSUMED_UPLOAD_BYTES_PER_SECOND = 100_000;
/** Extra time for the server to decode the audio once it has all arrived. */
export const PROCESSING_ALLOWANCE_SECONDS = 12;

/**
 * Wall-clock deadline for one attempt at a given payload size.
 *
 * Rounded up to whole seconds because it is passed to `AbortSignal.timeout`,
 * which is millisecond-precision but read in logs as a human figure.
 */
export function deadlineForAudioBytes(bytes: number): number {
  const uploadSeconds = Math.max(0, bytes) / ASSUMED_UPLOAD_BYTES_PER_SECOND;
  const total = uploadSeconds + PROCESSING_ALLOWANCE_SECONDS;
  return Math.min(
    MAXIMUM_DEADLINE_SECONDS,
    Math.max(MINIMUM_DEADLINE_SECONDS, Math.ceil(total)),
  );
}

export interface BuildRequestOptions {
  audioBytes: number;
  hint: TranscriptionHint;
  config: DeepgramConfig;
}

export interface BuiltRequest {
  url: string;
  headers: Record<string, string>;
  deadlineSeconds: number;
}

/** Build the Deepgram request (URL, headers, deadline). */
export function buildRequest({ audioBytes, hint, config }: BuildRequestOptions): BuiltRequest {
  const endpoint = config.endpoint ?? DEFAULT_ENDPOINT;
  const params = new URLSearchParams();
  params.set('model', 'nova-3');

  // Language handling.
  //
  // Auto used to send `language=multi`, on the belief that `multi` was the
  // auto-detect mode. It is not: `multi` is Multilingual Code-Switching, for
  // audio where the speaker switches languages mid-sentence. A user dictating in
  // one language with the pin on auto was transcribed in the wrong mode, which is
  // the most likely cause of punctuation and capitalisation looking off.
  // Detection is the documented mechanism, and it can be restricted.
  // https://developers.deepgram.com/docs/language-detection
  if (hint.language === 'auto') {
    // Restricted to the languages this app offers. Every code is native to
    // Nova-3, which matters: an unsupported detected language makes Deepgram
    // fall back to a lower model, and that would drop `keyterm` — the whole
    // dictionary feature, which is Nova-3 only.
    for (const language of AUTO_DETECT_LANGUAGES) {
      params.append('detect_language', language)
    }
  } else {
    params.set('language', hint.language);
  }

  params.set('smart_format', config.smartFormat ? 'true' : 'false');
  if (config.smartFormat) {
    // Smart Format only *guarantees* punctuation and paragraphs; numerals are
    // documented as available "for select languages" on non-English models.
    params.set('numerals', 'true');
  }
  if (config.spokenPunctuation && supportsSpokenPunctuation(hint.language)) {
    // The docs are explicit that punctuation must also be enabled:
    // "Be sure to add `dictation=true&punctuate=true`".
    params.set('dictation', 'true');
    params.set('punctuate', 'true');
  }
  // Usage attribution, so requests from this app are identifiable in Deepgram's
  // usage reporting.
  params.set('tag', 'useful-voice');

  // `keyterm` is Nova-3 only and repeats once per term. The list must already be
  // inside the token ceiling; this filter is a second line of defence so a
  // malformed entry can never reach the request line.
  for (const keyterm of hint.keyterms) {
    if (keyterm.trim().length > 0) params.append('keyterm', keyterm.trim());
  }

  return {
    url: `${endpoint}?${params.toString()}`,
    headers: {
      Authorization: `Token ${config.apiKey}`,
      'Content-Type': 'audio/wav',
    },
    deadlineSeconds: deadlineForAudioBytes(audioBytes),
  };
}

interface DeepgramAlternative {
  transcript?: string;
}

interface DeepgramChannel {
  alternatives?: DeepgramAlternative[];
  detected_language?: string;
}

interface DeepgramResponse {
  results?: {
    channels?: DeepgramChannel[];
    duration?: number;
  };
  metadata?: { duration?: number };
}

/** Extract the transcript from a Deepgram pre-recorded response. */
export function parseResponse(payload: unknown): Transcript {
  if (typeof payload !== 'object' || payload === null) {
    throw new ProviderError('malformedResponse', 'The transcription service returned an unexpected response.');
  }
  const body = payload as DeepgramResponse;
  const channel = body.results?.channels?.[0];
  const text = channel?.alternatives?.[0]?.transcript ?? '';
  const duration =
    body.results?.duration ??
    body.metadata?.duration ??
    null;
  return {
    text: typeof text === 'string' ? text.trim() : '',
    durationSeconds: typeof duration === 'number' && Number.isFinite(duration) ? duration : null,
    detectedLanguage: channel?.detected_language ?? null,
  };
}

/**
 * Pull Deepgram's `request_id` out of an error body, when present.
 *
 * Worth keeping because it is the one thing support asks for — "contact support
 * with the request ID and details about how the audio was uploaded" — and it is
 * otherwise lost with the response. Parsed leniently, so a non-JSON body or a
 * missing field yields null instead of masking the real error with a parse
 * failure.
 */
export function extractRequestId(body: string): string | null {
  if (!body) return null;
  let payload: unknown;
  try {
    payload = JSON.parse(body);
  } catch {
    return null;
  }
  if (typeof payload !== 'object' || payload === null) return null;
  const record = payload as Record<string, unknown>;
  const direct = record.request_id;
  if (typeof direct === 'string' && direct.length > 0) return direct;
  const metadata = record.metadata;
  if (typeof metadata === 'object' && metadata !== null) {
    const nested = (metadata as Record<string, unknown>).request_id;
    if (typeof nested === 'string' && nested.length > 0) return nested;
  }
  return null;
}

/**
 * Short, safe description of an error body.
 *
 * Response bodies can be large and can echo the request; only a bounded prefix is
 * kept, and the API key is redacted if it ever appears.
 */
export function describeErrorBody(body: string, apiKey?: string): string {
  let text = body.slice(0, 300).replace(/\s+/g, ' ').trim();
  if (apiKey && apiKey.length > 0) {
    text = text.split(apiKey).join('[redacted]');
  }
  return text;
}

/**
 * Classify a non-2xx response.
 *
 * Transient failures (429, 5xx) are separated from permanent ones (401, 400) so
 * the caller can retry only what can actually succeed.
 */
export function classifyHttpError(status: number, body: string, apiKey?: string): ProviderError {
  const detail = describeErrorBody(body, apiKey);
  const suffix = detail.length > 0 ? `: ${detail}` : '';
  // The docs tell users to quote the request id to support, so it is carried into
  // every message rather than being dropped with the response body.
  const reference = extractRequestId(body);
  const ref = reference ? ` (reference ${reference})` : '';
  if (status === 402) {
    return new ProviderError(
      'outOfCredits',
      `Your Deepgram account is out of credits (HTTP 402)${suffix}${ref}`,
      { status },
    );
  }
  if (status === 401 || status === 403) {
    return new ProviderError('unauthorized', `The Deepgram API key was rejected${suffix}${ref}`, { status });
  }
  if (status === 429) {
    return new ProviderError('rateLimited', `Deepgram rate limit reached${suffix}${ref}`, { status });
  }
  if (status >= 500) {
    return new ProviderError('serverError', `Deepgram is having trouble (HTTP ${status})${suffix}${ref}`, { status });
  }
  // 408 and 422 are documented as *retryable in substance*: "Deepgram was unable
  // to process the request because the audio data was incomplete or interrupted.
  // This typically occurs when the connection is closed before the full audio
  // payload is received, or when upload speed is too slow and the upload times
  // out." Classifying them as permanent refused to retry exactly the failures a
  // retry fixes.
  if (status === 408 || status === 422) {
    return new ProviderError(
      'transport',
      `Deepgram could not read the whole upload (HTTP ${status})${suffix}${ref}`,
      { status },
    );
  }
  return new ProviderError('badRequest', `Transcription failed (HTTP ${status})${suffix}${ref}`, { status });
}

/** Parse a `Retry-After` header, which may be seconds or an HTTP date. */
export function parseRetryAfter(value: string | null, now: Date = new Date()): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value.trim());
  if (Number.isFinite(seconds) && seconds >= 0) return Math.min(seconds, 60);
  const date = Date.parse(value);
  if (Number.isNaN(date)) return undefined;
  return Math.min(Math.max(0, (date - now.getTime()) / 1000), 60);
}

export interface TranscribeOptions {
  audio: Uint8Array;
  hint: TranscriptionHint;
  config: DeepgramConfig;
  /** Injected for tests. */
  fetchImpl?: typeof fetch;
  /** Abort signal from the caller (user pressed Escape). */
  signal?: AbortSignal;
  /** Attempts for transient failures. 1 disables retrying. */
  maxAttempts?: number;
  /** Injected for tests, so the suite never really sleeps. */
  sleep?: (ms: number) => Promise<void>;
}

export const MAX_ATTEMPTS = 3;

/**
 * Transcribe a WAV buffer.
 *
 * Retries transient failures with exponential backoff and honours `Retry-After`.
 * A single momentary network blip used to fail the user's dictation outright and
 * demand a manual retry.
 */
export async function transcribe(options: TranscribeOptions): Promise<Transcript> {
  const { audio, hint, config } = options;
  const doFetch = options.fetchImpl ?? fetch;
  const sleep = options.sleep ?? defaultSleep;
  const maxAttempts = Math.max(1, options.maxAttempts ?? MAX_ATTEMPTS);

  const request = buildRequest({ audioBytes: audio.byteLength, hint, config });

  let lastError: ProviderError | undefined;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    if (options.signal?.aborted) {
      throw new ProviderError('cancelled', 'Transcription was cancelled.');
    }
    try {
      return await attemptOnce(request, audio, doFetch, options.signal);
    } catch (error) {
      const providerError = toProviderError(error);
      lastError = providerError;
      if (!providerError.isTransient || attempt === maxAttempts) throw providerError;
      // Cap the server's own guidance so a large Retry-After cannot stall the
      // user's dictation for minutes.
      const delaySeconds = Math.min(providerError.retryAfterSeconds ?? 0.5 * 3 ** (attempt - 1), 8);
      await sleep(delaySeconds * 1000);
    }
  }
  throw lastError ?? new ProviderError('transport', 'Transcription failed.');
}

async function attemptOnce(
  request: BuiltRequest,
  audio: Uint8Array,
  doFetch: typeof fetch,
  signal: AbortSignal | undefined,
): Promise<Transcript> {
  const timeoutSignal = AbortSignal.timeout(request.deadlineSeconds * 1000);
  const combined = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal;

  let response: Response;
  try {
    response = await doFetch(request.url, {
      method: 'POST',
      headers: request.headers,
      // A copy, because fetch in Node rejects a SharedArrayBuffer-backed view and
      // some runtimes mutate the buffer.
      body: new Uint8Array(audio),
      signal: combined,
    });
  } catch (error) {
    if (signal?.aborted) {
      throw new ProviderError('cancelled', 'Transcription was cancelled.');
    }
    if (isAbortError(error)) {
      throw new ProviderError(
        'timedOut',
        `Transcription timed out after ${request.deadlineSeconds}s.`,
      );
    }
    throw new ProviderError(
      'transport',
      `Could not reach Deepgram: ${error instanceof Error ? error.message : String(error)}`,
    );
  }

  if (!response.ok) {
    const body = await safeText(response);
    const error = classifyHttpError(response.status, body);
    if (error.kind === 'rateLimited') {
      const retryAfter = parseRetryAfter(response.headers.get('retry-after'));
      throw new ProviderError('rateLimited', error.message, {
        status: response.status,
        ...(retryAfter !== undefined ? { retryAfterSeconds: retryAfter } : {}),
      });
    }
    throw error;
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw new ProviderError('malformedResponse', 'The transcription service returned invalid JSON.');
  }
  return parseResponse(payload);
}

function isAbortError(error: unknown): boolean {
  if (error instanceof DOMException && error.name === 'TimeoutError') return true;
  if (error instanceof Error) {
    return error.name === 'AbortError' || error.name === 'TimeoutError';
  }
  return false;
}

function toProviderError(error: unknown): ProviderError {
  if (error instanceof ProviderError) return error;
  return new ProviderError(
    'transport',
    error instanceof Error ? error.message : String(error),
  );
}

async function safeText(response: Response): Promise<string> {
  try {
    return await response.text();
  } catch {
    return '';
  }
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
