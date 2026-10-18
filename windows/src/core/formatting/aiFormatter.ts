/**
 * The AI formatter: one raw HTTP call to Gemini or Anthropic that cleans up a transcript.
 *
 * Request building, response parsing and the guard are pure; `formatWithModel` adds the fetch
 * and the deadline. It never retries a slow model (the dictation waits for it), so every
 * failure here means "deliver the unformatted text".
 */

import type { CatalogModel } from '../models/catalog.js';
import { FORMATTER_SYSTEM_PROMPT } from './formatterPrompt.js';
import { guardFormatted } from './formatterGuard.js';

export const MAX_VOCABULARY_WORDS = 100;
export const DEFAULT_DEADLINE_MS = 6000;
/** The slower models get longer. */
const DEADLINE_MS_BY_MODEL: Record<string, number> = { 'claude-sonnet-5-5': 10_000 };

export const GEMINI_ENDPOINT = 'https://generativelanguage.googleapis.com/v1beta/models';
export const ANTHROPIC_ENDPOINT = 'https://api.anthropic.com/v1/messages';
export const ANTHROPIC_VERSION = '2023-06-01';

export type FormatterFailureKind = 'noKey' | 'cancelled' | 'timeout' | 'transport' | 'http' | 'malformed' | 'guard' | 'truncated' | 'blocked';

/** Why a format attempt produced nothing. `message` never holds the key or the dictation text. */
export class FormatterError extends Error {
  constructor(
    readonly kind: FormatterFailureKind,
    message: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = 'FormatterError';
  }
}

export function deadlineMsFor(model: CatalogModel): number {
  return DEADLINE_MS_BY_MODEL[model.apiModel] ?? DEFAULT_DEADLINE_MS;
}

/** The user message: the dictionary words (at most 100) and the dictation. */
export function buildUserMessage(text: string, vocabulary: readonly string[]): string {
  const words = vocabulary.map((word) => word.trim()).filter((word) => word.length > 0).slice(0, MAX_VOCABULARY_WORDS);
  const vocab = words.length > 0 ? `<vocabulary>${words.join(', ')}</vocabulary>\n` : '';
  return `${vocab}<dictation>\n${text}\n</dictation>`;
}

export interface HttpRequestSpec {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

/** Gemini 3.8 Flash can't turn thinking off or go below `low`, so `low` it is. */
export function geminiThinkingLevel(_apiModel: string): 'low' {
  return 'low';
}

export function buildGeminiRequest(model: CatalogModel, apiKey: string, userMessage: string): HttpRequestSpec {
  return {
    url: `${GEMINI_ENDPOINT}/${model.apiModel}:generateContent`,
    headers: { 'x-goog-api-key': apiKey, 'content-type': 'application/json' },
    body: {
      systemInstruction: { parts: [{ text: FORMATTER_SYSTEM_PROMPT }] },
      contents: [{ role: 'user', parts: [{ text: userMessage }] }],
      generationConfig: { thinkingConfig: { thinkingLevel: geminiThinkingLevel(model.apiModel) } },
    },
  };
}

/** Room for the formatted text (never much longer than the input) plus a margin: 2 x length + 256, from 512 to 8192. */
export function anthropicMaxTokens(inputLength: number): number {
  return Math.min(8192, Math.max(512, 2 * inputLength + 256));
}

/**
 * No sampling parameters (the 5.x models reject non-default ones). Haiku 5.5 turns thinking off;
 * Sonnet 5.5 rejects `disabled`, and `between_tools` skips up-front thinking (no tools are sent).
 */
export function buildAnthropicRequest(
  model: CatalogModel,
  apiKey: string,
  userMessage: string,
  /** `inputLength`: the dictation's UTF-16 length (the dictation only, not the vocabulary). */
  options: { withThinkingField?: boolean; inputLength?: number } = {},
): HttpRequestSpec {
  const body: Record<string, unknown> = {
    model: model.apiModel,
    max_tokens: anthropicMaxTokens(options.inputLength ?? userMessage.length),
    system: FORMATTER_SYSTEM_PROMPT,
    messages: [{ role: 'user', content: userMessage }],
  };
  if (options.withThinkingField !== false) {
    body.thinking = { type: model.apiModel === 'claude-sonnet-5-5' ? 'between_tools' : 'disabled' };
  }
  return {
    url: ANTHROPIC_ENDPOINT,
    headers: { 'x-api-key': apiKey, 'anthropic-version': ANTHROPIC_VERSION, 'content-type': 'application/json' },
    body,
  };
}

interface GeminiResponse {
  candidates?: Array<{ content?: { parts?: Array<{ text?: unknown; thought?: unknown }> } }>;
}

/** The joined non-thought text parts of the first candidate. Empty when there are none (a blocked prompt). */
export function parseGeminiResponse(payload: unknown): string {
  const parts = (payload as GeminiResponse | null)?.candidates?.[0]?.content?.parts;
  if (!Array.isArray(parts)) return '';
  return parts
    .filter((part) => part.thought !== true && typeof part.text === 'string')
    .map((part) => part.text as string)
    .join('');
}

interface AnthropicResponse {
  content?: Array<{ type?: unknown; text?: unknown }>;
}

/** Why Anthropic stopped: `end_turn` is a finished answer, anything else (`max_tokens`) is a cut one. */
export function anthropicStopReason(payload: unknown): string | null {
  const reason = (payload as { stop_reason?: unknown } | null)?.stop_reason;
  return typeof reason === 'string' ? reason : null;
}

/** What Gemini says about the answer: blocked prompt, or the finish reason of the first candidate. */
export function geminiOutcome(payload: unknown): { blocked: boolean; finishReason: string | null } {
  const body = payload as { promptFeedback?: { blockReason?: unknown }; candidates?: Array<{ finishReason?: unknown }> } | null;
  const reason = body?.candidates?.[0]?.finishReason;
  return { blocked: typeof body?.promptFeedback?.blockReason === 'string', finishReason: typeof reason === 'string' ? reason : null };
}

/** The joined `text` blocks. */
export function parseAnthropicResponse(payload: unknown): string {
  const blocks = (payload as AnthropicResponse | null)?.content;
  if (!Array.isArray(blocks)) return '';
  return blocks
    .filter((block) => block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text as string)
    .join('');
}

export interface FormatOptions {
  model: CatalogModel;
  apiKey: string;
  text: string;
  vocabulary: readonly string[];
  /** The dictation's cancel. */
  signal?: AbortSignal;
  /** Injected for tests. */
  fetchImpl?: typeof fetch;
  /** Overrides the model's deadline; tests. */
  deadlineMs?: number;
}

/**
 * Format `text` with the model. Resolves to the guarded text, or throws a FormatterError
 * saying why the caller should fall back to the unformatted transcript.
 */
export async function formatWithModel(options: FormatOptions): Promise<string> {
  const { model, apiKey, text, signal } = options;
  const doFetch = options.fetchImpl ?? fetch;
  const userMessage = buildUserMessage(text, options.vocabulary);
  const deadlineMs = options.deadlineMs ?? deadlineMsFor(model);
  const timeout = AbortSignal.timeout(deadlineMs);
  const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;

  const send = async (spec: HttpRequestSpec): Promise<Response> => {
    try {
      return await doFetch(spec.url, {
        method: 'POST',
        headers: spec.headers,
        body: JSON.stringify(spec.body),
        signal: combined,
      });
    } catch (error) {
      if (signal?.aborted) throw new FormatterError('cancelled', 'the dictation was cancelled');
      if (timeout.aborted) throw new FormatterError('timeout', `no answer within ${deadlineMs / 1000} s`);
      // Fixed text: an error message can echo the request, which holds the dictation and the key.
      throw new FormatterError('transport', 'the request failed');
    }
  };

  let response: Response;
  if (model.provider === 'gemini') {
    response = await send(buildGeminiRequest(model, apiKey, userMessage));
  } else if (model.provider === 'anthropic') {
    response = await send(buildAnthropicRequest(model, apiKey, userMessage, { inputLength: text.length }));
    if (response.status === 400) {
      // A model that no longer takes the thinking field says so: try once without it.
      const body = await safeText(response);
      if (/thinking/i.test(body)) {
        response = await send(buildAnthropicRequest(model, apiKey, userMessage, { withThinkingField: false, inputLength: text.length }));
      } else {
        throw new FormatterError('http', 'HTTP 400', 400);
      }
    }
  } else {
    throw new FormatterError('http', `${model.provider} is not a formatter`);
  }

  if (!response.ok) {
    throw new FormatterError('http', `HTTP ${response.status}`, response.status);
  }

  let payload: unknown;
  try {
    payload = await response.json();
  } catch {
    throw new FormatterError('malformed', 'the answer was not JSON');
  }
  // A cut or refused answer is not a formatted dictation, however plausible its start.
  if (model.provider === 'gemini') {
    const outcome = geminiOutcome(payload);
    if (outcome.blocked) throw new FormatterError('blocked', 'the prompt was blocked');
    if (outcome.finishReason !== null && outcome.finishReason !== 'STOP') {
      throw new FormatterError(outcome.finishReason === 'MAX_TOKENS' ? 'truncated' : 'blocked', `finish reason ${outcome.finishReason}`);
    }
  } else {
    const stop = anthropicStopReason(payload);
    if (stop !== null && stop !== 'end_turn') {
      throw new FormatterError(stop === 'max_tokens' ? 'truncated' : 'blocked', `stop reason ${stop}`);
    }
  }
  const raw = model.provider === 'gemini' ? parseGeminiResponse(payload) : parseAnthropicResponse(payload);
  const guarded = guardFormatted(text, raw);
  if (!guarded.ok) throw new FormatterError('guard', guarded.reason);
  return guarded.text;
}

async function safeText(response: Response): Promise<string> {
  try {
    return await response.text();
  } catch {
    return '';
  }
}
