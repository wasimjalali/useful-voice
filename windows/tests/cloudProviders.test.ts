import { describe, expect, it, vi } from 'vitest';
import { buildRequest as buildDeepgram, transcribe as transcribeDeepgram, ProviderError, MEDICAL_ENGLISH_ONLY_MESSAGE } from '../src/core/transcription/deepgramProvider.js';
import {
  buildRequest as buildScribe,
  classifyHttpError as classifyScribe,
  normaliseDetectedLanguage,
  parseResponse as parseScribe,
  selectKeyterms,
  transcribe as transcribeScribe,
} from '../src/core/transcription/elevenlabsProvider.js';
import {
  GEMINI_TRANSCRIBE_PROMPT,
  MAX_INLINE_BODY_BYTES,
  TOO_LONG_MESSAGE,
  buildRequest as buildGeminiVoice,
  parseResponse as parseGeminiVoice,
  transcribe as transcribeGeminiVoice,
} from '../src/core/transcription/geminiTranscribeProvider.js';
import { checkProviderKey, keyCheckRequest } from '../src/core/models/providerKeyCheck.js';
import { setSecretSource } from '../src/core/redaction.js';
import { describeErrorBody } from '../src/core/transcription/deepgramProvider.js';
import { parakeetLanguageProblem } from '../src/core/transcription/parakeetLanguages.js';

const audio = new Uint8Array(64_000).fill(7);
const noSleep = async (): Promise<void> => undefined;
const json = (body: unknown, status = 200, headers: Record<string, string> = {}): Response =>
  new Response(JSON.stringify(body), { status, headers });

async function reason(promise: Promise<unknown>): Promise<ProviderError> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(ProviderError);
    return error as ProviderError;
  }
  throw new Error('expected a failure');
}

describe('Deepgram Nova-3 Medical', () => {
  const config = { apiKey: 'k', smartFormat: true, model: 'nova-3-medical' };
  const params = (language: string) => new URL(buildDeepgram({ audioBytes: 1000, hint: { language, keyterms: ['metformin'] }, config }).url).searchParams;

  it('refuses a pinned non-English language before any upload, with the exact message', async () => {
    for (const language of ['de', 'multi', 'ja', 'zh-TW']) {
      expect(() => buildDeepgram({ audioBytes: 1, hint: { language, keyterms: [] }, config }), language).toThrow(MEDICAL_ENGLISH_ONLY_MESSAGE);
    }
    expect(MEDICAL_ENGLISH_ONLY_MESSAGE).toBe(
      'Nova-3 Medical only speaks English. Pick another voice model or switch the language to English.',
    );
    const fetchImpl = vi.fn();
    await reason(transcribeDeepgram({ audio, hint: { language: 'de', keyterms: [] }, config, fetchImpl: fetchImpl as never }));
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it('sends language=en for English and for Auto, never detect_language', () => {
    for (const pin of ['en', 'en-GB', 'auto']) {
      const query = params(pin);
      expect(query.get('model'), pin).toBe('nova-3-medical');
      expect(query.get('language'), pin).toBe('en');
      expect(query.has('detect_language'), pin).toBe(false);
    }
  });

  it('keeps keyterms and leaves Nova-3 alone', () => {
    expect(params('en').getAll('keyterm')).toEqual(['metformin']);
    const nova = new URL(buildDeepgram({ audioBytes: 1, hint: { language: 'de', keyterms: [] }, config: { apiKey: 'k', smartFormat: true } }).url).searchParams;
    expect(nova.get('model')).toBe('nova-3');
    expect(nova.get('language')).toBe('de');
  });
});

describe('ElevenLabs Scribe v2', () => {
  const hint = { language: 'de', keyterms: ['Kubernetes', 'Convex'] };

  it('posts multipart with the model, the WAV, the language and no audio tags', async () => {
    let seen: { url: string; headers: Record<string, string>; form: FormData } | null = null;
    const fetchImpl = vi.fn(async (url: string, init: RequestInit) => {
      seen = { url, headers: init.headers as Record<string, string>, form: init.body as FormData };
      return json({ text: ' Hallo Welt. ', language_code: 'deu', audio_duration_secs: 2.5 });
    });
    const transcript = await transcribeScribe({ audio, hint, config: { apiKey: 'KEY' }, fetchImpl: fetchImpl as never });
    expect(seen!.url).toBe('https://api.elevenlabs.io/v1/speech-to-text');
    expect(seen!.headers).toEqual({ 'xi-api-key': 'KEY' });
    expect(seen!.form.get('model_id')).toBe('scribe_v2');
    expect(seen!.form.get('language_code')).toBe('de');
    expect(seen!.form.get('tag_audio_events')).toBe('false');
    expect(seen!.form.getAll('keyterms')).toEqual(['Kubernetes', 'Convex']);
    const file = seen!.form.get('file') as File;
    expect(file.size).toBe(audio.byteLength);
    expect(file.type).toBe('audio/wav');
    expect(transcript).toEqual({ text: 'Hallo Welt.', durationSeconds: 2.5, detectedLanguage: 'de' });
  });

  it('omits language_code for Auto and Multi', () => {
    expect(buildScribe(audio, { language: 'auto', keyterms: [] }, { apiKey: 'k' }).form.has('language_code')).toBe(false);
    expect(buildScribe(audio, { language: 'multi', keyterms: [] }, { apiKey: 'k' }).form.has('language_code')).toBe(false);
    expect(buildScribe(audio, { language: 'zh-TW', keyterms: [] }, { apiKey: 'k' }).form.get('language_code')).toBe('zh');
  });

  it('keeps at most 50 keyterms, each under 50 characters and five words, without markup characters', () => {
    const many = Array.from({ length: 80 }, (_, index) => `term${index}`);
    expect(selectKeyterms(many)).toHaveLength(50);
    expect(selectKeyterms(['x'.repeat(50), 'x'.repeat(49)])).toEqual(['x'.repeat(49)]);
    expect(selectKeyterms(['one two three four five', 'one two three four five six'])).toEqual(['one two three four five']);
    expect(selectKeyterms(['<b>', 'a{b}', 'back\\slash', 'fine', 'fine', '  '])).toEqual(['fine']);
  });

  it('maps ISO 639-3 answers to the codes the app stores', () => {
    expect(normaliseDetectedLanguage('eng')).toBe('en');
    expect(normaliseDetectedLanguage('fra')).toBe('fr');
    expect(normaliseDetectedLanguage('en')).toBe('en');
    expect(normaliseDetectedLanguage('')).toBeNull();
    expect(normaliseDetectedLanguage(7)).toBeNull();
  });

  it('classifies failures: 401 and 403 key, 429 rate limited, 5xx server', () => {
    expect(classifyScribe(401, '').kind).toBe('unauthorized');
    expect(classifyScribe(403, '').kind).toBe('unauthorized');
    expect(classifyScribe(429, '').kind).toBe('rateLimited');
    expect(classifyScribe(503, '').kind).toBe('serverError');
    expect(classifyScribe(422, 'bad').kind).toBe('badRequest');
    expect(classifyScribe(401, '').provider).toBe('ElevenLabs');
    expect(classifyScribe(401, 'echo SECRET', 'SECRET').message).not.toContain('SECRET');
  });

  it('retries a 429 honoring Retry-After and a 5xx, then succeeds', async () => {
    const answers = [json({}, 429, { 'retry-after': '2' }), json({}, 502), json({ text: 'ok then', language_code: 'eng' })];
    const fetchImpl = vi.fn(async () => answers.shift() as Response);
    const sleeps: number[] = [];
    const transcript = await transcribeScribe({ audio, hint, config: { apiKey: 'k' }, fetchImpl: fetchImpl as never, sleep: async (ms) => void sleeps.push(ms) });
    expect(transcript.text).toBe('ok then');
    expect(fetchImpl).toHaveBeenCalledTimes(3);
    expect(sleeps[0]).toBe(2000);
  });

  it('does not retry a rejected key', async () => {
    const fetchImpl = vi.fn(async () => json({ detail: 'nope' }, 401));
    const error = await reason(transcribeScribe({ audio, hint, config: { apiKey: 'k' }, fetchImpl: fetchImpl as never, sleep: noSleep }));
    expect(error.kind).toBe('unauthorized');
    expect(fetchImpl).toHaveBeenCalledOnce();
  });

  it('is cancelled by the signal and reports a dead network without the key', async () => {
    const controller = new AbortController();
    controller.abort();
    expect((await reason(transcribeScribe({ audio, hint, config: { apiKey: 'k' }, signal: controller.signal }))).kind).toBe('cancelled');
    const dead = vi.fn(async () => {
      throw new TypeError('fetch failed SECRETKEY');
    });
    const error = await reason(transcribeScribe({ audio, hint, config: { apiKey: 'SECRETKEY' }, fetchImpl: dead as never, sleep: noSleep, maxAttempts: 1 }));
    expect(error.kind).toBe('transport');
    expect(error.message).not.toContain('SECRETKEY');
  });

  it('rejects a body with no JSON object', () => {
    expect(() => parseScribe(null)).toThrow(ProviderError);
    expect(parseScribe({}).text).toBe('');
  });
});

describe('Gemini as a voice model', () => {
  const config = { apiKey: 'KEY', model: 'gemini-3.8-flash' };

  it('sends inline WAV audio with the transcription prompt, the key in a header and low thinking', () => {
    const request = buildGeminiVoice(audio, { language: 'auto', keyterms: [] }, config);
    expect(request.url).toBe('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent');
    expect(request.url).not.toContain('KEY');
    expect(request.headers['x-goog-api-key']).toBe('KEY');
    const body = request.body as { systemInstruction: unknown; contents: Array<{ role: string; parts: Array<Record<string, unknown>> }>; generationConfig: unknown };
    expect(body.systemInstruction).toEqual({ parts: [{ text: GEMINI_TRANSCRIBE_PROMPT }] });
    expect(body.contents).toHaveLength(1);
    expect(body.contents[0]?.role).toBe('user');
    expect(body.contents[0]?.parts).toEqual([{ inlineData: { mimeType: 'audio/wav', data: Buffer.from(audio).toString('base64') } }]);
    expect(body.generationConfig).toEqual({ thinkingConfig: { thinkingLevel: 'low' } });
    expect(JSON.stringify(body)).not.toContain('temperature');
  });

  it('adds a vocabulary part only when the dictionary has words, and a language part only when pinned', () => {
    const parts = (language: string, keyterms: string[]) =>
      ((buildGeminiVoice(audio, { language, keyterms }, config).body.contents as Array<{ parts: unknown[] }>)[0] as { parts: unknown[] }).parts.slice(1);
    expect(parts('auto', [])).toEqual([]);
    expect(parts('auto', ['Kubernetes', 'Convex'])).toEqual([{ text: '<vocabulary>Kubernetes, Convex</vocabulary>' }]);
    expect(parts('de', [])).toEqual([{ text: 'Language: German' }]);
    expect(parts('de', ['a'])).toEqual([{ text: '<vocabulary>a</vocabulary>' }, { text: 'Language: German' }]);
    expect(parts('multi', [])).toEqual([]);
    const many = Array.from({ length: 150 }, (_, index) => `w${index}`);
    expect(JSON.stringify(parts('auto', many))).toContain('w99');
    expect(JSON.stringify(parts('auto', many))).not.toContain('w100');
  });

  it('fails fast, before any request, when the base64 body would pass 19 MB', async () => {
    const huge = new Uint8Array(Math.ceil((MAX_INLINE_BODY_BYTES / 4) * 3) + 10);
    expect(() => buildGeminiVoice(huge, { language: 'auto', keyterms: [] }, config)).toThrow(TOO_LONG_MESSAGE);
    expect(TOO_LONG_MESSAGE).toBe('This recording is too long for Gemini. Pick another voice model for long dictations.');
    const fetchImpl = vi.fn();
    await reason(transcribeGeminiVoice({ audio: huge, hint: { language: 'auto', keyterms: [] }, config, fetchImpl: fetchImpl as never }));
    expect(fetchImpl).not.toHaveBeenCalled();
    // A ten-minute dictation (19.2 MB of WAV) is over the cap; a few minutes are under it.
    expect(() => buildGeminiVoice(new Uint8Array(3_000_000), { language: 'auto', keyterms: [] }, config)).not.toThrow();
  });

  it('uses a deadline of at least 20 seconds', () => {
    expect(buildGeminiVoice(audio, { language: 'auto', keyterms: [] }, config).deadlineSeconds).toBeGreaterThanOrEqual(20);
  });

  it('reads the joined non-thought text, and treats silence as an empty transcript', () => {
    expect(parseGeminiVoice({ candidates: [{ content: { parts: [{ text: 'hmm', thought: true }, { text: ' Hello ' }, { text: 'world.' }] } }] }).text).toBe('Hello world.');
    expect(parseGeminiVoice({ candidates: [] }).text).toBe('');
    expect(() => parseGeminiVoice({ promptFeedback: { blockReason: 'OTHER' } })).toThrow("Gemini didn't return a transcript");
    expect(() => parseGeminiVoice('x')).toThrow(ProviderError);
  });

  it('fails a blocked prompt or a cut-off answer with no text, so the audio is kept for Retry; STOP with no text is silence', async () => {
    const answer = (body: unknown) => vi.fn(async () => json(body));
    const hint = { language: 'auto', keyterms: [] };
    for (const body of [{ promptFeedback: { blockReason: 'OTHER' } }, { candidates: [{ finishReason: 'SAFETY' }] }, { candidates: [{ finishReason: 'MAX_TOKENS' }] }]) {
      const error = await reason(transcribeGeminiVoice({ audio, hint, config, fetchImpl: answer(body) as never, sleep: noSleep }));
      expect(error.kind).toBe('malformedResponse');
      expect(error.message).toContain("Gemini didn't return a transcript");
    }
    const silence = await transcribeGeminiVoice({ audio, hint, config, fetchImpl: answer({ candidates: [{ finishReason: 'STOP', content: { parts: [] } }] }) as never });
    expect(silence.text).toBe('');
  });

  it('treats 400 invalid key, 401 and 403 as a key problem, never leaking it', async () => {
    for (const [status, body] of [[400, '{"error":{"message":"API key not valid. SECRET","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}'], [401, '{}'], [403, '{}']] as const) {
      const fetchImpl = vi.fn(async () => new Response(body, { status }));
      const error = await reason(transcribeGeminiVoice({ audio, hint: { language: 'auto', keyterms: [] }, config: { ...config, apiKey: 'SECRET' }, fetchImpl: fetchImpl as never, sleep: noSleep }));
      expect(error.kind, String(status)).toBe('unauthorized');
      expect(error.message).not.toContain('SECRET');
      expect(error.provider).toBe('Gemini');
      expect(fetchImpl).toHaveBeenCalledOnce();
    }
  });

  it('keeps a plain 400 as a bad request, retries 429 and 5xx', async () => {
    const bad = vi.fn(async () => new Response('{"error":{"message":"bad audio"}}', { status: 400 }));
    expect((await reason(transcribeGeminiVoice({ audio, hint: { language: 'auto', keyterms: [] }, config, fetchImpl: bad as never }))).kind).toBe('badRequest');
    const answers = [new Response('{}', { status: 429 }), new Response('{}', { status: 500 }), json({ candidates: [{ content: { parts: [{ text: 'fine' }] } }] })];
    const retried = vi.fn(async () => answers.shift() as Response);
    const transcript = await transcribeGeminiVoice({ audio, hint: { language: 'auto', keyterms: [] }, config, fetchImpl: retried as never, sleep: noSleep });
    expect(transcript.text).toBe('fine');
    expect(retried).toHaveBeenCalledTimes(3);
  });
});

describe('error bodies', () => {
  it('redact before they truncate, so a key cut by the limit is still hidden', () => {
    const key = 'abcdefghijklmnopqrstuvwxyz0123456789ABCD';
    const body = `${'x '.repeat(145)}${key} trailing`;
    const text = describeErrorBody(body, key);
    expect(text).not.toContain('abcdefghij');
    expect(text.length).toBeLessThanOrEqual(300);
  });
  it('redact every stored key, and key-shaped strings that were never stored', () => {
    setSecretSource(() => ['stored-eleven-key', 'stored-gemini-key']);
    try {
      const text = describeErrorBody('bad stored-eleven-key and stored-gemini-key and sk-ant-api03-abcdefghij and AIzaSyA1234567890abcdefgh');
      expect(text).not.toMatch(/stored-|sk-ant|AIza/);
    } finally {
      setSecretSource(() => []);
    }
  });
});

describe('key checks for the GET providers', () => {
  it('builds a cheap authenticated GET per provider, with the key in a header only', () => {
    expect(keyCheckRequest('elevenlabs', 'K')).toEqual({ url: 'https://api.elevenlabs.io/v1/models', headers: { 'xi-api-key': 'K' } });
    expect(keyCheckRequest('anthropic', 'K')).toEqual({
      url: 'https://api.anthropic.com/v1/models',
      headers: { 'x-api-key': 'K', 'anthropic-version': '2023-06-01' },
    });
    const gemini = keyCheckRequest('gemini', 'K');
    expect(gemini.url).toBe('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash');
    expect(gemini.headers).toEqual({ 'x-goog-api-key': 'K' });
  });

  it('answers with fixed text by outcome', async () => {
    const answer = (status: number) => checkProviderKey('anthropic', 'K', (async () => new Response('echo K', { status })) as never);
    expect(await answer(200)).toEqual({ ok: true, message: 'The key works.' });
    expect(await answer(401)).toEqual({ ok: false, kind: 'rejected', message: 'Anthropic rejected the key.' });
    expect((await answer(500)).kind).toBe('failed');
    const gemini = await checkProviderKey('gemini', 'K', (async () => new Response('{}', { status: 400 })) as never);
    expect(gemini.kind).toBe('rejected');
    const dead = await checkProviderKey('elevenlabs', 'K', (async () => {
      throw new TypeError('fetch failed K');
    }) as never);
    expect(dead).toEqual({ ok: false, kind: 'network', message: 'Could not reach ElevenLabs.' });
  });
});

describe('Parakeet language pins', () => {
  it('lets v2 speak English only', () => {
    for (const pin of ['auto', 'multi', 'en', 'en-GB']) expect(parakeetLanguageProblem('v2', pin), pin).toBeNull();
    expect(parakeetLanguageProblem('v2', 'de')).toMatch(/only speaks English/);
  });
  it('lets v3 speak its 25 European languages and no others', () => {
    for (const pin of ['de', 'fr', 'uk', 'bg', 'mt', 'de-CH']) expect(parakeetLanguageProblem('v3', pin), pin).toBeNull();
    expect(parakeetLanguageProblem('v3', 'ja')).toBe("Parakeet Multilingual doesn't cover Japanese. Pick another voice model or another language.");
    expect(parakeetLanguageProblem('v3', 'ar')).toMatch(/Arabic/);
  });
});
