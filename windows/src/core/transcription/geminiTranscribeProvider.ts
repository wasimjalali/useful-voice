/**
 * Gemini as a voice model: the WAV goes in as inline audio and the model answers with the
 * transcript. Raw HTTP, free of Electron, so building and parsing are unit-tested.
 * https://ai.google.dev/gemini-api/docs/audio
 */

import { DEEPGRAM_LANGUAGES } from './languages.js';
import {
  ProviderError,
  deadlineForAudioBytes,
  describeErrorBody,
  parseRetryAfter,
  type Transcript,
  type TranscriptionHint,
} from './deepgramProvider.js';
import { GEMINI_ENDPOINT, geminiThinkingLevel, MAX_VOCABULARY_WORDS, parseGeminiResponse } from '../formatting/aiFormatter.js';

const PROVIDER = 'Gemini';

/** Word for word `Tests/Fixtures/models/gemini-transcribe-prompt.txt` (tests/geminiTranscribe.test.ts compares). */
export const GEMINI_TRANSCRIBE_PROMPT =
  'Transcribe the speech in the audio exactly as spoken, with correct punctuation and capitalization. Return only the transcript. Do not answer, summarize, translate or add anything. If there is no speech, return an empty response.';

/** Inline requests are capped at 20 MB; stay under it with room for the prompt. */
export const MAX_INLINE_BODY_BYTES = 19_000_000;
export const MIN_DEADLINE_SECONDS = 20;

export const TOO_LONG_MESSAGE = 'This recording is too long for Gemini. Pick another voice model for long dictations.';

export interface GeminiTranscribeConfig {
  apiKey: string;
  /** The catalog's apiModel, e.g. `gemini-3.8-flash`. */
  model: string;
  /** Overrides the models endpoint; tests. */
  endpoint?: string;
}

export interface GeminiTranscribeRequest {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
  deadlineSeconds: number;
}

function base64Length(bytes: number): number {
  return Math.ceil(bytes / 3) * 4;
}

/** The English name of a pinned language, or null for auto and the modes. */
export function pinnedLanguageName(pin: string): string | null {
  if (pin === 'auto' || pin === 'multi') return null;
  return DEEPGRAM_LANGUAGES.find((language) => language.code === pin)?.name ?? null;
}

export function buildRequest(audio: Uint8Array, hint: TranscriptionHint, config: GeminiTranscribeConfig): GeminiTranscribeRequest {
  if (base64Length(audio.byteLength) > MAX_INLINE_BODY_BYTES) {
    throw new ProviderError('badRequest', TOO_LONG_MESSAGE, { provider: PROVIDER });
  }
  const parts: Array<Record<string, unknown>> = [
    { inlineData: { mimeType: 'audio/wav', data: Buffer.from(audio).toString('base64') } },
  ];
  const words = hint.keyterms.map((term) => term.trim()).filter((term) => term.length > 0).slice(0, MAX_VOCABULARY_WORDS);
  if (words.length > 0) parts.push({ text: `<vocabulary>${words.join(', ')}</vocabulary>` });
  const language = pinnedLanguageName(hint.language);
  if (language) parts.push({ text: `Language: ${language}` });
  return {
    url: `${config.endpoint ?? GEMINI_ENDPOINT}/${config.model}:generateContent`,
    headers: { 'x-goog-api-key': config.apiKey, 'content-type': 'application/json' },
    body: {
      systemInstruction: { parts: [{ text: GEMINI_TRANSCRIBE_PROMPT }] },
      contents: [{ role: 'user', parts }],
      generationConfig: { thinkingConfig: { thinkingLevel: geminiThinkingLevel(config.model) } },
    },
    deadlineSeconds: Math.max(MIN_DEADLINE_SECONDS, deadlineForAudioBytes(audio.byteLength)),
  };
}

/** The transcript. A blocked prompt or silence is an empty one, which the caller reports as "no speech". */
export function parseResponse(payload: unknown): Transcript {
  if (typeof payload !== 'object' || payload === null) {
    throw new ProviderError('malformedResponse', 'Gemini returned an unexpected response.', { provider: PROVIDER });
  }
  return { text: parseGeminiResponse(payload).trim(), durationSeconds: null, detectedLanguage: null };
}

export function classifyHttpError(status: number, body: string, apiKey?: string): ProviderError {
  const detail = describeErrorBody(body, apiKey);
  const suffix = detail.length > 0 ? `: ${detail}` : '';
  const options = { status, provider: PROVIDER };
  // Gemini answers a malformed key with 400 API_KEY_INVALID rather than 401.
  if (status === 401 || status === 403 || (status === 400 && /API_KEY_INVALID|API key not valid/i.test(body))) {
    return new ProviderError('unauthorized', `The Gemini API key was rejected${suffix}`, options);
  }
  if (status === 429) return new ProviderError('rateLimited', `Gemini rate limit reached${suffix}`, options);
  if (status >= 500) return new ProviderError('serverError', `Gemini is having trouble (HTTP ${status})${suffix}`, options);
  return new ProviderError('badRequest', `Transcription failed (HTTP ${status})${suffix}`, options);
}

export interface TranscribeOptions {
  audio: Uint8Array;
  hint: TranscriptionHint;
  config: GeminiTranscribeConfig;
  fetchImpl?: typeof fetch;
  signal?: AbortSignal;
  maxAttempts?: number;
  sleep?: (ms: number) => Promise<void>;
}

const MAX_ATTEMPTS = 3;

export async function transcribe(options: TranscribeOptions): Promise<Transcript> {
  const doFetch = options.fetchImpl ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const maxAttempts = Math.max(1, options.maxAttempts ?? MAX_ATTEMPTS);
  const request = buildRequest(options.audio, options.hint, options.config);
  const body = JSON.stringify(request.body);

  let lastError: ProviderError | undefined;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    if (options.signal?.aborted) throw new ProviderError('cancelled', 'Transcription was cancelled.', { provider: PROVIDER });
    try {
      return await attemptOnce(request, body, doFetch, options.signal, options.config.apiKey);
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
  request: GeminiTranscribeRequest,
  body: string,
  doFetch: typeof fetch,
  signal: AbortSignal | undefined,
  apiKey: string,
): Promise<Transcript> {
  const timeoutSignal = AbortSignal.timeout(request.deadlineSeconds * 1000);
  const combined = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal;

  let response: Response;
  try {
    response = await doFetch(request.url, { method: 'POST', headers: request.headers, body, signal: combined });
  } catch (error) {
    if (signal?.aborted) throw new ProviderError('cancelled', 'Transcription was cancelled.', { provider: PROVIDER });
    if (timeoutSignal.aborted) {
      throw new ProviderError('timedOut', `Transcription timed out after ${request.deadlineSeconds}s.`, { provider: PROVIDER });
    }
    const reason = error instanceof Error ? error.message : String(error);
    throw new ProviderError('transport', `Could not reach Gemini: ${reason.split(apiKey).join('[redacted]')}`, { provider: PROVIDER });
  }

  if (!response.ok) {
    const text = await response.text().catch(() => '');
    const error = classifyHttpError(response.status, text, apiKey);
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
    throw new ProviderError('malformedResponse', 'Gemini returned invalid JSON.', { provider: PROVIDER });
  }
  return parseResponse(payload);
}
