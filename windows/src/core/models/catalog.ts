/**
 * The model catalog the Windows app offers. Hard-coded here and checked against
 * `Tests/Fixtures/models/catalog.json` (tests/modelCatalog.test.ts), the file macOS checks too,
 * so the two platforms cannot drift. Speed and accuracy are relative 1-5 ratings, not benchmarks.
 * Pure data: no Electron, Node or DOM import.
 */

export type ModelProvider = 'deepgram' | 'elevenlabs' | 'nvidia' | 'gemini' | 'anthropic';

/** Providers that need an API key. */
export type KeyProvider = 'deepgram' | 'elevenlabs' | 'gemini' | 'anthropic';

export interface CatalogModel {
  /** `<provider>:<model>`, the value saved in settings. */
  id: string;
  name: string;
  provider: ModelProvider;
  /** The model string the provider's API takes. */
  apiModel: string;
  kind: 'cloud' | 'local';
  badge: 'EN' | 'NEW' | null;
  speed: number;
  accuracy: number;
}

export const VOICE_MODELS: readonly CatalogModel[] = [
  { id: 'deepgram:nova-3', name: 'Nova-3', provider: 'deepgram', apiModel: 'nova-3', kind: 'cloud', badge: null, speed: 5, accuracy: 4 },
  { id: 'deepgram:nova-3-medical', name: 'Nova-3 Medical', provider: 'deepgram', apiModel: 'nova-3-medical', kind: 'cloud', badge: 'EN', speed: 5, accuracy: 4 },
  { id: 'elevenlabs:scribe_v2', name: 'Scribe v2', provider: 'elevenlabs', apiModel: 'scribe_v2', kind: 'cloud', badge: null, speed: 3, accuracy: 5 },
  { id: 'gemini-audio:gemini-3.8-flash', name: 'Gemini 3.8 Flash', provider: 'gemini', apiModel: 'gemini-3.8-flash', kind: 'cloud', badge: 'NEW', speed: 3, accuracy: 5 },
  { id: 'parakeet:v2', name: 'Parakeet', provider: 'nvidia', apiModel: 'parakeet-tdt-0.6b-v2', kind: 'local', badge: 'EN', speed: 5, accuracy: 4 },
  { id: 'parakeet:v3', name: 'Parakeet Multilingual', provider: 'nvidia', apiModel: 'parakeet-tdt-0.6b-v3', kind: 'local', badge: null, speed: 5, accuracy: 4 },
];

export const LANGUAGE_MODELS: readonly CatalogModel[] = [
  { id: 'gemini:gemini-3.8-flash', name: 'Gemini 3.8 Flash', provider: 'gemini', apiModel: 'gemini-3.8-flash', kind: 'cloud', badge: 'NEW', speed: 4, accuracy: 5 },
  { id: 'anthropic:claude-haiku-5-5', name: 'Claude Haiku 5.5', provider: 'anthropic', apiModel: 'claude-haiku-5-5', kind: 'cloud', badge: 'NEW', speed: 4, accuracy: 5 },
  { id: 'anthropic:claude-sonnet-5-5', name: 'Claude Sonnet 5.5', provider: 'anthropic', apiModel: 'claude-sonnet-5-5', kind: 'cloud', badge: 'NEW', speed: 3, accuracy: 5 },
];

export const DEFAULT_VOICE_MODEL_ID = 'deepgram:nova-3';

export const KEY_PROVIDERS: readonly KeyProvider[] = ['deepgram', 'elevenlabs', 'gemini', 'anthropic'];

export interface KeyProviderInfo {
  /** The name people know it by. */
  name: string;
  /** Where to create a key. */
  keyUrl: string;
}

export const KEY_PROVIDER_INFO: Record<KeyProvider, KeyProviderInfo> = {
  deepgram: { name: 'Deepgram', keyUrl: 'https://console.deepgram.com/' },
  elevenlabs: { name: 'ElevenLabs', keyUrl: 'https://elevenlabs.io/app/settings/api-keys' },
  gemini: { name: 'Gemini', keyUrl: 'https://aistudio.google.com/apikey' },
  anthropic: { name: 'Anthropic', keyUrl: 'https://console.anthropic.com/settings/keys' },
};

export function isKeyProvider(value: unknown): value is KeyProvider {
  return typeof value === 'string' && (KEY_PROVIDERS as readonly string[]).includes(value);
}

export function voiceModelById(id: unknown): CatalogModel | undefined {
  return typeof id === 'string' ? VOICE_MODELS.find((model) => model.id === id) : undefined;
}

export function languageModelById(id: unknown): CatalogModel | undefined {
  return typeof id === 'string' ? LANGUAGE_MODELS.find((model) => model.id === id) : undefined;
}

/** A stored voice model id the catalog still offers, else the default. */
export function normaliseVoiceModelId(value: unknown): string {
  return voiceModelById(value)?.id ?? DEFAULT_VOICE_MODEL_ID;
}

/** A stored formatter id the catalog still offers, else null (off). */
export function normaliseFormatterId(value: unknown): string | null {
  return languageModelById(value)?.id ?? null;
}

/** The key a model needs, or null for a local one. */
export function keyProviderOf(model: CatalogModel): KeyProvider | null {
  return isKeyProvider(model.provider) ? model.provider : null;
}
