import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  DEFAULT_VOICE_MODEL_ID,
  KEY_PROVIDER_INFO,
  LANGUAGE_MODELS,
  VOICE_MODELS,
  keyProviderOf,
  languageModelById,
  normaliseFormatterId,
  normaliseVoiceModelId,
  voiceModelById,
} from '../src/core/models/catalog.js';
import { DEFAULT_SETTINGS } from '../src/core/models.js';
import { normaliseSettings } from '../src/core/settings/settingsBounds.js';
import { FORMATTER_SYSTEM_PROMPT } from '../src/core/formatting/formatterPrompt.js';
import { GEMINI_TRANSCRIBE_PROMPT } from '../src/core/transcription/geminiTranscribeProvider.js';

// The catalog and the prompts are shared with macOS through fixtures. These tests are what keeps
// the two platforms from drifting, and what makes a stored model id safe to read back.

const fixtures = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'Tests', 'Fixtures', 'models');
const catalog = JSON.parse(readFileSync(path.join(fixtures, 'catalog.json'), 'utf8')) as {
  voice: Array<Record<string, unknown> & { platforms: string[] }>;
  language: Array<Record<string, unknown> & { platforms: string[] }>;
  defaults: { voice: string; language: string | null };
};

const forWindows = (entries: typeof catalog.voice) =>
  entries
    .filter((entry) => entry.platforms.includes('windows'))
    .map(({ platforms: _platforms, ...rest }) => rest);

describe('catalog against the shared fixture', () => {
  it('offers exactly the fixture voice models for Windows, in order', () => {
    expect(VOICE_MODELS.map((model) => ({ ...model }))).toEqual(forWindows(catalog.voice));
  });

  it('offers exactly the fixture AI formatting models, in order', () => {
    expect(LANGUAGE_MODELS.map((model) => ({ ...model }))).toEqual(forWindows(catalog.language));
  });

  it('defaults to the fixture default and AI formatting off', () => {
    expect(DEFAULT_VOICE_MODEL_ID).toBe(catalog.defaults.voice);
    expect(catalog.defaults.language).toBeNull();
    expect(DEFAULT_SETTINGS.voiceModelId).toBe(catalog.defaults.voice);
    expect(DEFAULT_SETTINGS.formatterId).toBeNull();
  });

  it('keeps Windows free of models it cannot run', () => {
    expect(VOICE_MODELS.some((model) => model.id.startsWith('whisper:'))).toBe(false);
  });

  it('gives every id once, with ratings from 1 to 5', () => {
    const ids = [...VOICE_MODELS, ...LANGUAGE_MODELS].map((model) => model.id);
    expect(new Set(ids).size).toBe(ids.length);
    for (const model of [...VOICE_MODELS, ...LANGUAGE_MODELS]) {
      expect(model.speed).toBeGreaterThanOrEqual(1);
      expect(model.speed).toBeLessThanOrEqual(5);
      expect(model.accuracy).toBeGreaterThanOrEqual(1);
      expect(model.accuracy).toBeLessThanOrEqual(5);
    }
  });

  it('knows which key each model needs', () => {
    expect(keyProviderOf(voiceModelById('elevenlabs:scribe_v2')!)).toBe('elevenlabs');
    expect(keyProviderOf(voiceModelById('gemini-audio:gemini-3.8-flash')!)).toBe('gemini');
    expect(keyProviderOf(voiceModelById('parakeet:v3')!)).toBeNull();
    expect(keyProviderOf(languageModelById('anthropic:claude-haiku-5-5')!)).toBe('anthropic');
    expect(Object.keys(KEY_PROVIDER_INFO).sort()).toEqual(['anthropic', 'deepgram', 'elevenlabs', 'gemini']);
  });
});

describe('prompts against the shared fixtures', () => {
  it('embeds the AI formatter prompt word for word', () => {
    const fixture = readFileSync(path.join(fixtures, 'formatter-system-prompt.txt'), 'utf8');
    expect(FORMATTER_SYSTEM_PROMPT).toBe(fixture.replace(/\n$/, ''));
  });

  it('embeds the Gemini transcription prompt word for word', () => {
    const fixture = readFileSync(path.join(fixtures, 'gemini-transcribe-prompt.txt'), 'utf8');
    expect(GEMINI_TRANSCRIBE_PROMPT).toBe(fixture.replace(/\n$/, ''));
  });
});

describe('stored model ids', () => {
  it('fall back to the default voice model for anything the catalog does not offer', () => {
    for (const bad of [undefined, null, 42, '', 'whisper:large-v3', 'deepgram:nova-2', 'gemini:gemini-3.8-flash']) {
      expect(normaliseVoiceModelId(bad), String(bad)).toBe(DEFAULT_VOICE_MODEL_ID);
    }
    expect(normaliseVoiceModelId('parakeet:v2')).toBe('parakeet:v2');
  });

  it('fall back to Off for a formatter the catalog does not offer', () => {
    for (const bad of [undefined, null, 7, '', 'anthropic:claude-haiku-4-5', 'deepgram:nova-3']) {
      expect(normaliseFormatterId(bad), String(bad)).toBeNull();
    }
    expect(normaliseFormatterId('anthropic:claude-sonnet-5-5')).toBe('anthropic:claude-sonnet-5-5');
  });

  it('migrate a settings file from before models existed to Nova-3 with formatting off', () => {
    const old = { ...DEFAULT_SETTINGS } as Record<string, unknown>;
    delete old.voiceModelId;
    delete old.formatterId;
    const merged = normaliseSettings({ ...DEFAULT_SETTINGS, ...old } as typeof DEFAULT_SETTINGS);
    expect(merged.voiceModelId).toBe('deepgram:nova-3');
    expect(merged.formatterId).toBeNull();
  });

  it('correct a stale id on update', () => {
    const next = normaliseSettings({ ...DEFAULT_SETTINGS, voiceModelId: 'whisper:large-v3', formatterId: 'x:y' });
    expect(next.voiceModelId).toBe('deepgram:nova-3');
    expect(next.formatterId).toBeNull();
  });
});
