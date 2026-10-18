import { KEY_PROVIDER_INFO, keyProviderOf, voiceModelById, DEFAULT_VOICE_MODEL_ID, type CatalogModel, type KeyProvider } from '../core/models/catalog.js';
import { parakeetVersionFromCatalogId, type ParakeetVersion } from '../core/models/parakeet.js';
import { ProviderError, transcribe as transcribeDeepgram, type Transcript } from '../core/transcription/deepgramProvider.js';
import { transcribe as transcribeScribe } from '../core/transcription/elevenlabsProvider.js';
import { transcribe as transcribeGemini } from '../core/transcription/geminiTranscribeProvider.js';
import type { TranscriberPort } from './dictationService.js';

/**
 * Picks the provider for the chosen voice model. Never falls back to another provider: a
 * model that can't run (no key, not downloaded, wrong language) says so.
 */
export interface RouterDeps {
  /** The saved voice model id. */
  voiceModelId: () => string;
  /** A provider's key, or null. */
  key: (provider: KeyProvider) => string | null;
  parakeet: { transcribe(wav: Uint8Array, version: ParakeetVersion, signal?: AbortSignal, language?: string): Promise<Transcript> };
  /** Injected for tests. */
  fetchImpl?: typeof fetch;
  /** Injected for tests, so retries never really sleep. */
  sleep?: (ms: number) => Promise<void>;
}

export function currentVoiceModel(voiceModelId: string): CatalogModel {
  return voiceModelById(voiceModelId) ?? (voiceModelById(DEFAULT_VOICE_MODEL_ID) as CatalogModel);
}

export function missingKeyMessage(model: CatalogModel): string {
  const provider = keyProviderOf(model);
  return provider ? `Add your ${KEY_PROVIDER_INFO[provider].name} key in Settings.` : 'Download the voice model in Settings.';
}

/** The key to check before a dictation, or 'local' for a model that needs none. Null means missing. */
export function voiceCredential(model: CatalogModel, key: (provider: KeyProvider) => string | null): string | null {
  const provider = keyProviderOf(model);
  return provider ? key(provider) : 'local';
}

export function createTranscriber(deps: RouterDeps): TranscriberPort {
  return {
    async transcribe(request, signal) {
      const model = currentVoiceModel(deps.voiceModelId());
      const provider = keyProviderOf(model);
      const apiKey = provider ? deps.key(provider) : null;
      if (provider && !apiKey) {
        throw new ProviderError('notConfigured', missingKeyMessage(model), { provider: KEY_PROVIDER_INFO[provider].name });
      }
      const common = { fetchImpl: deps.fetchImpl, sleep: deps.sleep, signal, maxAttempts: 3 };
      const hint = { language: request.language, keyterms: request.keyterms };

      if (model.provider === 'deepgram') {
        return transcribeDeepgram({
          audio: request.audio,
          hint,
          config: {
            apiKey: apiKey ?? '',
            model: model.apiModel,
            smartFormat: request.smartFormat,
            spokenPunctuation: request.spokenPunctuation,
          },
          ...common,
        });
      }
      if (model.provider === 'elevenlabs') {
        return transcribeScribe({ audio: request.audio, hint, config: { apiKey: apiKey ?? '', model: model.apiModel }, ...common });
      }
      if (model.provider === 'gemini') {
        return transcribeGemini({ audio: request.audio, hint, config: { apiKey: apiKey ?? '', model: model.apiModel }, ...common });
      }
      const version = parakeetVersionFromCatalogId(model.id);
      if (model.provider === 'nvidia' && version) {
        // The language rule lives with the model (`checkParakeetLanguage`, run inside `transcribe`).
        return deps.parakeet.transcribe(request.audio, version, signal, request.language);
      }
      throw new ProviderError('notConfigured', `${model.name} can't run here.`);
    },
  };
}
