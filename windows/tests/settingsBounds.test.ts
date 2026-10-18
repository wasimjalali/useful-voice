import { describe, expect, it } from 'vitest';
import { DEFAULT_SETTINGS } from '../src/core/models.js';
import {
  MAX_DICTIONARY_BIAS_BUDGET,
  MAX_RECORDING_SECONDS,
  MAX_RECORDINGS_TO_KEEP,
  MAX_SILENCE_TIMEOUT_SECONDS,
  MIN_RECORDING_SECONDS,
  MIN_SILENCE_TIMEOUT_SECONDS,
  normaliseSettings,
} from '../src/core/settings/settingsBounds.js';

/**
 * These bounds were previously unreachable by the test suite: they lived inside
 * the Electron-backed settings store, which cannot be imported outside an
 * Electron process. The values decide how long the user may speak before the app
 * discards the recording, so they are worth asserting directly.
 */
describe('normaliseSettings', () => {
  const withSettings = (patch: Partial<typeof DEFAULT_SETTINGS>) =>
    normaliseSettings({ ...DEFAULT_SETTINGS, ...patch });

  it('leaves defaults untouched', () => {
    expect(normaliseSettings(DEFAULT_SETTINGS)).toEqual(DEFAULT_SETTINGS);
  });

  /**
   * Deepgram: "Requests exceeding 10 minutes (Nova/Base/Enhanced) … return a 504:
   * Gateway Timeout." A 15-minute recording was therefore a coin flip on failing
   * after the user had already spoken for a quarter of an hour.
   */
  it('clamps a 15-minute recording down to the documented limit', () => {
    expect(withSettings({ maxRecordingSeconds: 900 }).maxRecordingSeconds).toBe(600);
    expect(MAX_RECORDING_SECONDS).toBe(600);
  });

  it('clamps the recording length at both ends', () => {
    expect(withSettings({ maxRecordingSeconds: 1 }).maxRecordingSeconds).toBe(MIN_RECORDING_SECONDS);
    expect(withSettings({ maxRecordingSeconds: 5 }).maxRecordingSeconds).toBe(30);
    expect(withSettings({ maxRecordingSeconds: 10_000 }).maxRecordingSeconds).toBe(600);
  });

  it('clamps the silence timeout at both ends', () => {
    expect(withSettings({ silenceTimeoutSeconds: 0 }).silenceTimeoutSeconds).toBe(
      MIN_SILENCE_TIMEOUT_SECONDS,
    );
    expect(withSettings({ silenceTimeoutSeconds: 9_999 }).silenceTimeoutSeconds).toBe(
      MAX_SILENCE_TIMEOUT_SECONDS,
    );
  });

  it('keeps zero recordings to keep valid', () => {
    // 0 means "keep none", which is a legitimate privacy choice.
    expect(withSettings({ recordingsToKeep: 0 }).recordingsToKeep).toBe(0);
    expect(withSettings({ recordingsToKeep: -5 }).recordingsToKeep).toBe(0);
    expect(withSettings({ recordingsToKeep: 1e6 }).recordingsToKeep).toBe(MAX_RECORDINGS_TO_KEEP);
  });

  it('bounds the dictionary bias budget to the keyterm selection ceiling', () => {
    expect(withSettings({ dictionaryBiasBudget: 500 }).dictionaryBiasBudget).toBe(
      MAX_DICTIONARY_BIAS_BUDGET,
    );
    expect(withSettings({ dictionaryBiasBudget: -1 }).dictionaryBiasBudget).toBe(0);
  });

  it('rounds fractional values rather than passing them through', () => {
    expect(withSettings({ maxRecordingSeconds: 300.7 }).maxRecordingSeconds).toBe(301);
    expect(withSettings({ recordingsToKeep: 4.4 }).recordingsToKeep).toBe(4);
  });

  it('falls back to the lower bound for values that are not finite', () => {
    // A NaN reaching the recorder would disable the auto-stop entirely.
    expect(withSettings({ maxRecordingSeconds: Number.NaN }).maxRecordingSeconds).toBe(
      MIN_RECORDING_SECONDS,
    );
    expect(withSettings({ silenceTimeoutSeconds: Number.POSITIVE_INFINITY }).silenceTimeoutSeconds).toBe(
      MIN_SILENCE_TIMEOUT_SECONDS,
    );
  });

  it('preserves the fields it does not police', () => {
    const result = withSettings({
      languagePin: 'de',
      formattingEnabled: false,
      spokenPunctuationEnabled: true,
      hotkey: { accelerator: 'F8', pushToTalk: true },
    });
    expect(result.languagePin).toBe('de');
    expect(result.formattingEnabled).toBe(false);
    expect(result.spokenPunctuationEnabled).toBe(true);
    expect(result.hotkey).toEqual({ accelerator: 'F8', pushToTalk: true });
  });

  it('returns a new object rather than mutating its input', () => {
    const input = { ...DEFAULT_SETTINGS, maxRecordingSeconds: 900 };
    const result = normaliseSettings(input);
    expect(result).not.toBe(input);
    expect(input.maxRecordingSeconds).toBe(900);
  });

  /**
   * Spoken punctuation is opt-in: it changes what the words mean, so it must not
   * arrive switched on for existing users after an upgrade.
   */
  it('defaults spoken punctuation to off', () => {
    expect(DEFAULT_SETTINGS.spokenPunctuationEnabled).toBe(false);
  });

  it('forces push-to-talk off on the language hotkey', () => {
    // The picker is a discrete action, so push-to-talk is meaningless. A shared
    // settings shape should not let a stale true leak in and make the hotkey
    // behave as hold-to-show.
    const result = normaliseSettings({
      ...DEFAULT_SETTINGS,
      languageSwitchHotkey: { accelerator: 'Control+Alt+L', pushToTalk: true },
    });
    expect(result.languageSwitchHotkey).toEqual({
      accelerator: 'Control+Alt+L',
      pushToTalk: false,
    });
  });

  it('leaves the language hotkey unset when it is absent', () => {
    const { languageSwitchHotkey: _omitted, ...withoutHotkey } = DEFAULT_SETTINGS;
    const result = normaliseSettings(withoutHotkey as typeof DEFAULT_SETTINGS);
    expect(result.languageSwitchHotkey).toBeUndefined();
  });

  it('tolerates a non-string accelerator', () => {
    // The value comes from a JSON file a user can edit, so it may not be a string.
    const result = normaliseSettings({
      ...DEFAULT_SETTINGS,
      languageSwitchHotkey: { accelerator: 42 as unknown as string, pushToTalk: false },
    });
    expect(result.languageSwitchHotkey?.accelerator).toBe('42');
  });
});
