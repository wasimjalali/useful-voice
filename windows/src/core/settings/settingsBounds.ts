/**
 * Bounds and normalisation for user-editable settings.
 *
 * Extracted from the Electron-backed settings store so it can be unit-tested:
 * the store imports `electron`, which cannot load outside an Electron process,
 * so every clamp in it was previously unreachable by the test suite. A wrong
 * bound here is not cosmetic — `maxRecordingSeconds` decides how long the user
 * can speak before the app throws the recording away, and the recorder's
 * behaviour at each end of these ranges is worth being able to test directly.
 */

import { type AppSettings } from '../models.js';

/**
 * Longest recording the user may choose.
 *
 * 600 s, not the 900 s the UI used to offer: Deepgram documents that "Requests
 * exceeding 10 minutes (Nova/Base/Enhanced) … return a 504: Gateway Timeout", so
 * a 15-minute option was a coin flip on failing *after* the user had spoken for a
 * quarter of an hour.
 * https://developers.deepgram.com/docs/pre-recorded-audio
 */
export const MAX_RECORDING_SECONDS = 600;
export const MIN_RECORDING_SECONDS = 30;
export const MIN_SILENCE_TIMEOUT_SECONDS = 15;
export const MAX_SILENCE_TIMEOUT_SECONDS = 120;
export const MAX_RECORDINGS_TO_KEEP = 200;
/** Matches the keyterm selection ceiling, so the two cannot disagree. */
export const MAX_DICTIONARY_BIAS_BUDGET = 100;

function clamp(value: number, low: number, high: number): number {
  if (!Number.isFinite(value)) return low;
  return Math.min(high, Math.max(low, value));
}

/**
 * Bring a settings object inside the supported ranges.
 *
 * Pure: returns a new object, so it can be asserted on without touching disk.
 * Applied on both load and update, so a value written by an older build is
 * corrected on the next launch rather than silently honoured.
 */
export function normaliseSettings(settings: AppSettings): AppSettings {
  return {
    ...settings,
    silenceTimeoutSeconds: clamp(
      Math.round(settings.silenceTimeoutSeconds),
      MIN_SILENCE_TIMEOUT_SECONDS,
      MAX_SILENCE_TIMEOUT_SECONDS,
    ),
    maxRecordingSeconds: clamp(
      Math.round(settings.maxRecordingSeconds),
      MIN_RECORDING_SECONDS,
      MAX_RECORDING_SECONDS,
    ),
    recordingsToKeep: clamp(Math.round(settings.recordingsToKeep), 0, MAX_RECORDINGS_TO_KEEP),
    dictionaryBiasBudget: clamp(
      Math.round(settings.dictionaryBiasBudget),
      0,
      MAX_DICTIONARY_BIAS_BUDGET,
    ),
  };
}
