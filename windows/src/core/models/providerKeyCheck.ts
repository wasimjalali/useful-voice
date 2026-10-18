import { ANTHROPIC_ENDPOINT, ANTHROPIC_VERSION, GEMINI_ENDPOINT } from '../formatting/aiFormatter.js';
import { ELEVENLABS_MODELS_ENDPOINT } from '../transcription/elevenlabsProvider.js';
import { KEY_PROVIDER_INFO, LANGUAGE_MODELS, type KeyProvider } from './catalog.js';

/**
 * A cheap authenticated call that tells whether a key works, for the three providers whose
 * check is a plain GET (Deepgram's is a silent clip, run by the main process).
 *
 * The messages are fixed text by outcome, never the server's own: an error body can echo the key.
 */
export interface ProviderKeyCheck {
  ok: boolean;
  kind?: 'rejected' | 'network' | 'failed';
  message: string;
}

const ANTHROPIC_MODELS_URL = ANTHROPIC_ENDPOINT.replace(/\/messages$/, '/models');
const CHECK_DEADLINE_MS = 10_000;

export function keyCheckRequest(provider: Exclude<KeyProvider, 'deepgram'>, apiKey: string): { url: string; headers: Record<string, string> } {
  switch (provider) {
    case 'elevenlabs':
      return { url: ELEVENLABS_MODELS_ENDPOINT, headers: { 'xi-api-key': apiKey } };
    case 'gemini': {
      const model = LANGUAGE_MODELS.find((candidate) => candidate.provider === 'gemini');
      return { url: `${GEMINI_ENDPOINT}/${model?.apiModel ?? 'gemini-3.8-flash'}`, headers: { 'x-goog-api-key': apiKey } };
    }
    case 'anthropic':
      return { url: ANTHROPIC_MODELS_URL, headers: { 'x-api-key': apiKey, 'anthropic-version': ANTHROPIC_VERSION } };
  }
}

export async function checkProviderKey(
  provider: Exclude<KeyProvider, 'deepgram'>,
  apiKey: string,
  fetchImpl: typeof fetch = fetch,
): Promise<ProviderKeyCheck> {
  const name = KEY_PROVIDER_INFO[provider].name;
  const request = keyCheckRequest(provider, apiKey);
  let response: Response;
  try {
    response = await fetchImpl(request.url, { method: 'GET', headers: request.headers, signal: AbortSignal.timeout(CHECK_DEADLINE_MS) });
  } catch {
    return { ok: false, kind: 'network', message: `Could not reach ${name}.` };
  }
  if (response.ok) return { ok: true, message: 'The key works.' };
  if (response.status === 401 || response.status === 403) return { ok: false, kind: 'rejected', message: `${name} rejected the key.` };
  // Gemini answers a malformed key with 400 API_KEY_INVALID.
  if (response.status === 400 && provider === 'gemini') return { ok: false, kind: 'rejected', message: `${name} rejected the key.` };
  if (response.status === 429) return { ok: false, kind: 'failed', message: `${name} is busy. Try again in a moment.` };
  if (response.status >= 500) return { ok: false, kind: 'failed', message: `${name} is having trouble. Try again in a moment.` };
  return { ok: false, kind: 'failed', message: `${name} could not check the key.` };
}
