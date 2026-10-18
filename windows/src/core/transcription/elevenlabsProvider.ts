/**
 * ElevenLabs Scribe v2 pre-recorded transcription.
 *
 * Raw HTTP, free of Electron, so the form building and error classification are unit-tested
 * against a stubbed fetch. https://elevenlabs.io/docs/api-reference/speech-to-text/convert
 */

import {
  ProviderError,
  deadlineForAudioBytes,
  describeErrorBody,
  parseRetryAfter,
  type Transcript,
  type TranscriptionHint,
} from './deepgramProvider.js';

export const ELEVENLABS_ENDPOINT = 'https://api.elevenlabs.io/v1/speech-to-text';
export const ELEVENLABS_MODELS_ENDPOINT = 'https://api.elevenlabs.io/v1/models';

const PROVIDER = 'ElevenLabs';
export const MAX_KEYTERMS = 50;
const MAX_KEYTERM_LENGTH = 49;
const MAX_KEYTERM_WORDS = 5;
const FORBIDDEN_IN_KEYTERM = /[<>{}[\]\\]/;

/** Keyterms Scribe accepts: at most 50, each under 50 characters and five words, none with markup characters. */
export function selectKeyterms(terms: readonly string[]): string[] {
  const chosen: string[] = [];
  for (const raw of terms) {
    const term = raw.trim();
    if (term.length === 0 || term.length > MAX_KEYTERM_LENGTH) continue;
    if (term.split(/\s+/).length > MAX_KEYTERM_WORDS) continue;
    if (FORBIDDEN_IN_KEYTERM.test(term)) continue;
    if (chosen.includes(term)) continue;
    chosen.push(term);
    if (chosen.length === MAX_KEYTERMS) break;
  }
  return chosen;
}

/** A few ISO 639-3 codes Scribe answers with, mapped to the 639-1 codes the app stores. */
const ISO3_TO_ISO1: Record<string, string> = {
  eng: 'en', deu: 'de', fra: 'fr', spa: 'es', ita: 'it', por: 'pt', nld: 'nl', pol: 'pl', rus: 'ru', ukr: 'uk',
  tur: 'tr', ara: 'ar', hin: 'hi', jpn: 'ja', kor: 'ko', zho: 'zh', cmn: 'zh', swe: 'sv', dan: 'da', nor: 'no',
  fin: 'fi', ces: 'cs', ell: 'el', heb: 'he', hun: 'hu', ind: 'id', ron: 'ro', bul: 'bg', hrv: 'hr', slk: 'sk',
  slv: 'sl', cat: 'ca', fas: 'fa', vie: 'vi', tha: 'th', lit: 'lt', lav: 'lv', est: 'et', msa: 'ms', ben: 'bn',
};

export function normaliseDetectedLanguage(code: unknown): string | null {
  if (typeof code !== 'string') return null;
  const lower = code.trim().toLowerCase().replace(/[^a-z-]/g, '');
  if (lower.length === 0) return null;
  return ISO3_TO_ISO1[lower] ?? lower;
}

export interface ScribeConfig {
  apiKey: string;
  /** The catalog's apiModel. Defaults to `scribe_v2`. */
  model?: string;
  /** Overrides the endpoint; tests. */
  endpoint?: string;
}

export interface ScribeRequest {
  url: string;
  headers: Record<string, string>;
  form: FormData;
  deadlineSeconds: number;
}

/** The pin as Scribe wants it (ISO 639-1), or null for auto. */
function languageCodeFor(pin: string): string | null {
  if (pin === 'auto' || pin === 'multi') return null;
  // Regional tags (zh-TW, de-CH) collapse to the base language Scribe knows.
  return pin.split('-')[0] ?? null;
}

export function buildRequest(audio: Uint8Array, hint: TranscriptionHint, config: ScribeConfig): ScribeRequest {
  const form = new FormData();
  form.append('model_id', config.model ?? 'scribe_v2');
  form.append('file', new Blob([new Uint8Array(audio)], { type: 'audio/wav' }), 'dictation.wav');
  const language = languageCodeFor(hint.language);
  if (language) form.append('language_code', language);
  form.append('tag_audio_events', 'false');
  for (const term of selectKeyterms(hint.keyterms)) form.append('keyterms', term);
  return {
    url: config.endpoint ?? ELEVENLABS_ENDPOINT,
    headers: { 'xi-api-key': config.apiKey },
    form,
    deadlineSeconds: deadlineForAudioBytes(audio.byteLength),
  };
}

export function parseResponse(payload: unknown): Transcript {
  if (typeof payload !== 'object' || payload === null) {
    throw new ProviderError('malformedResponse', 'ElevenLabs returned an unexpected response.', { provider: PROVIDER });
  }
  const body = payload as { text?: unknown; language_code?: unknown; audio_duration_secs?: unknown };
  const duration = typeof body.audio_duration_secs === 'number' && Number.isFinite(body.audio_duration_secs) ? body.audio_duration_secs : null;
  return {
    text: typeof body.text === 'string' ? body.text.trim() : '',
    durationSeconds: duration,
    detectedLanguage: normaliseDetectedLanguage(body.language_code),
  };
}

/** `detail.status` of an ElevenLabs error body ("quota_exceeded", "invalid_api_key"), or null. */
function detailStatus(body: string): string | null {
  try {
    const status = (JSON.parse(body) as { detail?: { status?: unknown } }).detail?.status;
    return typeof status === 'string' ? status : null;
  } catch {
    return null;
  }
}

export function classifyHttpError(status: number, body: string, apiKey?: string): ProviderError {
  const detail = describeErrorBody(body, apiKey);
  const suffix = detail.length > 0 ? `: ${detail}` : '';
  const options = { status, provider: PROVIDER };
  if (status === 401 || status === 403) {
    if (detailStatus(body) === 'quota_exceeded') {
      return new ProviderError('outOfCredits', 'Your ElevenLabs account is out of credits.', options);
    }
    return new ProviderError(
      'unauthorized',
      'ElevenLabs rejected your API key. Check the key and its speech-to-text permission.',
      options,
    );
  }
  if (status === 402) {
    return new ProviderError('outOfCredits', 'Your ElevenLabs account is out of credits.', options);
  }
  if (status === 429) return new ProviderError('rateLimited', `ElevenLabs rate limit reached${suffix}`, options);
  if (status >= 500) return new ProviderError('serverError', `ElevenLabs is having trouble (HTTP ${status})${suffix}`, options);
  if (status === 408) return new ProviderError('transport', `ElevenLabs could not read the whole upload (HTTP 408)${suffix}`, options);
  return new ProviderError('badRequest', `Transcription failed (HTTP ${status})${suffix}`, options);
}

export interface TranscribeOptions {
  audio: Uint8Array;
  hint: TranscriptionHint;
  config: ScribeConfig;
  fetchImpl?: typeof fetch;
  signal?: AbortSignal;
  maxAttempts?: number;
  sleep?: (ms: number) => Promise<void>;
}

const MAX_ATTEMPTS = 3;

/** Transcribe a WAV with Scribe. Transient failures retry with backoff, like Deepgram's. */
export async function transcribe(options: TranscribeOptions): Promise<Transcript> {
  const doFetch = options.fetchImpl ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const maxAttempts = Math.max(1, options.maxAttempts ?? MAX_ATTEMPTS);

  let lastError: ProviderError | undefined;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    if (options.signal?.aborted) throw new ProviderError('cancelled', 'Transcription was cancelled.', { provider: PROVIDER });
    // A fresh form each time: a body that was sent once cannot be sent again.
    const request = buildRequest(options.audio, options.hint, options.config);
    try {
      return await attemptOnce(request, doFetch, options.signal, options.config.apiKey);
    } catch (error) {
      const providerError =
        error instanceof ProviderError
          ? error
          : new ProviderError('transport', error instanceof Error ? error.message : String(error), { provider: PROVIDER });
      lastError = providerError;
      if (!providerError.isTransient || attempt === maxAttempts) throw providerError;
      const delaySeconds = Math.min(providerError.retryAfterSeconds ?? 0.5 * 3 ** (attempt - 1), 8);
      await sleep(delaySeconds * 1000);
    }
  }
  throw lastError ?? new ProviderError('transport', 'Transcription failed.', { provider: PROVIDER });
}

async function attemptOnce(
  request: ScribeRequest,
  doFetch: typeof fetch,
  signal: AbortSignal | undefined,
  apiKey: string,
): Promise<Transcript> {
  const timeoutSignal = AbortSignal.timeout(request.deadlineSeconds * 1000);
  const combined = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal;

  let response: Response;
  try {
    response = await doFetch(request.url, { method: 'POST', headers: request.headers, body: request.form, signal: combined });
  } catch (error) {
    if (signal?.aborted) throw new ProviderError('cancelled', 'Transcription was cancelled.', { provider: PROVIDER });
    if (timeoutSignal.aborted) {
      throw new ProviderError('timedOut', `Transcription timed out after ${request.deadlineSeconds}s.`, { provider: PROVIDER });
    }
    const reason = error instanceof Error ? error.message : String(error);
    throw new ProviderError('transport', `Could not reach ElevenLabs: ${reason.split(apiKey).join('[redacted]')}`, { provider: PROVIDER });
  }

  if (!response.ok) {
    const body = await response.text().catch(() => '');
    const error = classifyHttpError(response.status, body, apiKey);
    if (error.kind === 'rateLimited') {
      const retryAfter = parseRetryAfter(response.headers.get('retry-after'));
      throw new ProviderError('rateLimited', error.message, {
        status: response.status,
        provider: PROVIDER,
        ...(retryAfter !== undefined ? { retryAfterSeconds: retryAfter } : {}),
      });
    }
    throw error;
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw new ProviderError('malformedResponse', 'ElevenLabs returned invalid JSON.', { provider: PROVIDER });
  }
  return parseResponse(payload);
}
