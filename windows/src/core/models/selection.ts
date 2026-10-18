import {
  KEY_PROVIDER_INFO,
  keyProviderOf,
  voiceModelById,
  DEFAULT_VOICE_MODEL_ID,
  type CatalogModel,
  type KeyProvider,
} from './catalog.js';
import type { ParakeetState } from './parakeet.js';
import { parakeetVersionFromCatalogId, type ParakeetVersion } from './parakeet.js';

/** Which providers have a key saved (presence only). */
export type KeyPresence = Record<KeyProvider, boolean>;

export type ParakeetStates = Record<ParakeetVersion, ParakeetState>;

/** What the window needs to say about the chosen voice model: its name and whether a key is missing. */
export interface VoiceStatus {
  model: CatalogModel;
  /** The provider's name when its key is missing, else null. */
  missingKeyOf: string | null;
}

export function voiceStatus(voiceModelId: string, keys: KeyPresence): VoiceStatus {
  const model = voiceModelById(voiceModelId) ?? (voiceModelById(DEFAULT_VOICE_MODEL_ID) as CatalogModel);
  const provider = keyProviderOf(model);
  return { model, missingKeyOf: provider && !keys[provider] ? KEY_PROVIDER_INFO[provider].name : null };
}

/** What choosing a row does. */
export type PickAction =
  /** Save it as the choice. */
  | 'select'
  /** A cloud model without its key: take the person to the key row. */
  | 'addKey'
  /** A local model that isn't on this PC: start the download and switch when it is ready. */
  | 'download'
  /** It is already downloading; the switch happens when it's ready. */
  | 'wait';

export function pickAction(model: CatalogModel, keys: KeyPresence, parakeet: ParakeetStates | null): PickAction {
  const provider = keyProviderOf(model);
  if (provider) return keys[provider] ? 'select' : 'addKey';
  const version = parakeetVersionFromCatalogId(model.id);
  if (!version) return 'select';
  if (!parakeet) return 'download';
  const state = parakeet[version];
  if (state.status === 'ready') return 'select';
  return state.status === 'downloading' ? 'wait' : 'download';
}
