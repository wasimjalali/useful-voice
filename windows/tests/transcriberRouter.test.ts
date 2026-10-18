import { describe, expect, it, vi } from 'vitest';
import { createTranscriber, currentVoiceModel, missingKeyMessage, voiceCredential } from '../src/main/transcriberRouter.js';
import { ProviderError, type Transcript } from '../src/core/transcription/deepgramProvider.js';
import type { KeyProvider } from '../src/core/models/catalog.js';

// The provider chosen for the voice model is the one that runs, and a model that can't run
// says why. Nothing falls back to another provider.

const request = { audio: new Uint8Array(64_000), language: 'auto', keyterms: ['Convex'], smartFormat: true, spokenPunctuation: false };
const ok = (body: unknown): Response => new Response(JSON.stringify(body), { status: 200 });

function setup(modelId: string, keys: Partial<Record<KeyProvider, string>> = {}) {
  const urls: string[] = [];
  const fetchImpl = vi.fn(async (url: string) => {
    urls.push(url);
    if (url.includes('deepgram')) return ok({ results: { channels: [{ alternatives: [{ transcript: 'from deepgram' }] }] } });
    if (url.includes('elevenlabs')) return ok({ text: 'from scribe', language_code: 'eng' });
    return ok({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: 'from gemini' }] } }] });
  });
  const parakeet = { transcribe: vi.fn(async (): Promise<Transcript> => ({ text: 'from parakeet', durationSeconds: null, detectedLanguage: null })) };
  const transcriber = createTranscriber({ voiceModelId: () => modelId, key: (provider) => keys[provider] ?? null, parakeet, fetchImpl: fetchImpl as never });
  return { transcriber, urls, parakeet, fetchImpl };
}

async function failure(promise: Promise<unknown>): Promise<ProviderError> {
  try {
    await promise;
  } catch (error) {
    return error as ProviderError;
  }
  throw new Error('expected a failure');
}

describe('a model whose key is missing', () => {
  it.each([
    ['deepgram:nova-3', 'Deepgram'],
    ['deepgram:nova-3-medical', 'Deepgram'],
    ['elevenlabs:scribe_v2', 'ElevenLabs'],
    ['gemini-audio:gemini-3.8-flash', 'Gemini'],
  ])('%s says "Add your %s key in Settings." and sends nothing', async (modelId, name) => {
    const ctx = setup(modelId);
    const error = await failure(ctx.transcriber.transcribe(request));
    expect(error.kind).toBe('notConfigured');
    expect(error.message).toBe(`Add your ${name} key in Settings.`);
    expect(ctx.fetchImpl).not.toHaveBeenCalled();
    expect(ctx.parakeet.transcribe).not.toHaveBeenCalled();
    expect(missingKeyMessage(currentVoiceModel(modelId))).toBe(error.message);
  });

  it('does not use another provider\'s key', async () => {
    const ctx = setup('elevenlabs:scribe_v2', { deepgram: 'dg', gemini: 'gm' });
    expect((await failure(ctx.transcriber.transcribe(request))).kind).toBe('notConfigured');
    expect(ctx.fetchImpl).not.toHaveBeenCalled();
  });
});

describe('provider selection', () => {
  it.each([
    ['deepgram:nova-3', 'deepgram', 'from deepgram'],
    ['elevenlabs:scribe_v2', 'elevenlabs', 'from scribe'],
    ['gemini-audio:gemini-3.8-flash', 'generativelanguage', 'from gemini'],
  ])('%s calls only its own host', async (modelId, host, text) => {
    const ctx = setup(modelId, { deepgram: 'a', elevenlabs: 'b', gemini: 'c' });
    expect((await ctx.transcriber.transcribe(request)).text).toBe(text);
    expect(ctx.urls).toHaveLength(1);
    expect(ctx.urls[0]).toContain(host);
  });

  it('sends the Deepgram model string from the catalog', async () => {
    const ctx = setup('deepgram:nova-3-medical', { deepgram: 'a' });
    await ctx.transcriber.transcribe({ ...request, language: 'en' });
    expect(new URL(ctx.urls[0] as string).searchParams.get('model')).toBe('nova-3-medical');
  });

  it('runs Parakeet locally with the version and the language pin, no key and no network', async () => {
    const ctx = setup('parakeet:v3');
    const controller = new AbortController();
    expect((await ctx.transcriber.transcribe({ ...request, language: 'de' }, controller.signal)).text).toBe('from parakeet');
    expect(ctx.parakeet.transcribe).toHaveBeenCalledWith(request.audio, 'v3', controller.signal, 'de');
    expect(ctx.fetchImpl).not.toHaveBeenCalled();
  });

  it('refuses a language Parakeet does not speak before running it', async () => {
    const v2 = setup('parakeet:v2');
    const error = await failure(v2.transcriber.transcribe({ ...request, language: 'de' }));
    expect(error.message).toMatch(/only speaks English/);
    expect(v2.parakeet.transcribe).not.toHaveBeenCalled();
    const v3 = setup('parakeet:v3');
    expect((await failure(v3.transcriber.transcribe({ ...request, language: 'ja' }))).message).toMatch(/Japanese/);
  });

  it('passes a Parakeet "not downloaded" error through untouched', async () => {
    const ctx = setup('parakeet:v2');
    ctx.parakeet.transcribe.mockRejectedValueOnce(new ProviderError('notConfigured', 'Parakeet is not downloaded. Download it in Settings to use it.'));
    expect((await failure(ctx.transcriber.transcribe(request))).message).toBe('Parakeet is not downloaded. Download it in Settings to use it.');
  });

  it('treats a stale model id as the default, Nova-3', () => {
    expect(currentVoiceModel('whisper:large-v3').id).toBe('deepgram:nova-3');
  });
});

describe('the credential check before a dictation', () => {
  it('needs the key for a cloud model and nothing for a local one', () => {
    const keys: Partial<Record<KeyProvider, string>> = { gemini: 'g' };
    const key = (provider: KeyProvider): string | null => keys[provider] ?? null;
    expect(voiceCredential(currentVoiceModel('gemini-audio:gemini-3.8-flash'), key)).toBe('g');
    expect(voiceCredential(currentVoiceModel('elevenlabs:scribe_v2'), key)).toBeNull();
    expect(voiceCredential(currentVoiceModel('parakeet:v2'), key)).toBe('local');
  });
});
