import { describe, expect, it, vi } from 'vitest';
import { guardFormatted, worthFormatting } from '../src/core/formatting/formatterGuard.js';
import {
  FormatterError,
  anthropicMaxTokens,
  buildAnthropicRequest,
  buildGeminiRequest,
  buildUserMessage,
  deadlineMsFor,
  formatWithModel,
  parseAnthropicResponse,
  parseGeminiResponse,
} from '../src/core/formatting/aiFormatter.js';
import { FORMATTER_SYSTEM_PROMPT } from '../src/core/formatting/formatterPrompt.js';
import { languageModelById } from '../src/core/models/catalog.js';

// Failure cases first: every way a model's answer can go wrong must end as "deliver the
// unformatted text", and none of them may leak the key.

const gemini = languageModelById('gemini:gemini-3.8-flash')!;
const haiku = languageModelById('anthropic:claude-haiku-5-5')!;
const sonnet = languageModelById('anthropic:claude-sonnet-5-5')!;
const SPOKEN = 'um send the report on tuesday no wait wednesday';

describe('guard', () => {
  const input = SPOKEN;
  it('rejects empty output', () => {
    expect(guardFormatted(input, '')).toMatchObject({ ok: false });
    expect(guardFormatted(input, '  \n ')).toMatchObject({ ok: false });
  });
  it('rejects output more than twice the input plus 40 characters', () => {
    expect(guardFormatted(input, 'x'.repeat(input.length * 2 + 41))).toMatchObject({ ok: false });
    expect(guardFormatted(input, 'x'.repeat(input.length * 2 + 40))).toMatchObject({ ok: true });
  });
  it('rejects output under 0.4x the input when the input has 20 or more characters', () => {
    expect(guardFormatted(input, 'Send it.')).toMatchObject({ ok: false });
    // Short inputs are exempt: "um yes" legitimately becomes "Yes."
    expect(guardFormatted('um yes please ok', 'Yes.')).toMatchObject({ ok: true });
  });
  it.each(["Here is the text: send it", "Here's the corrected text", 'Sure, here you go', 'Certainly. Send it Wednesday.', "I've fixed it: send it", 'I have formatted it', 'Of course! Send it'])(
    'rejects an assistant preamble: %s',
    (output) => {
      expect(guardFormatted(input, output)).toMatchObject({ ok: false });
    },
  );
  it('allows a dictation that itself starts like a preamble', () => {
    expect(guardFormatted('i have to leave early today', 'I have to leave early today.')).toEqual({ ok: true, text: 'I have to leave early today.' });
  });
  it('trims, and strips one wrapping code fence or <dictation> tag', () => {
    const text = 'Send the report on Wednesday.';
    expect(guardFormatted(input, `  ${text}\n`)).toEqual({ ok: true, text });
    expect(guardFormatted(input, `\`\`\`\n${text}\n\`\`\``)).toEqual({ ok: true, text });
    expect(guardFormatted(input, `\`\`\`text\n${text}\n\`\`\``)).toEqual({ ok: true, text });
    expect(guardFormatted(input, `<dictation>\n${text}\n</dictation>`)).toEqual({ ok: true, text });
    // Only one layer is removed.
    const twice = guardFormatted(input, `<dictation>\n\`\`\`\n${text}\n\`\`\`\n</dictation>`);
    expect(twice.ok && twice.text).toBe(`\`\`\`\n${text}\n\`\`\``);
  });
  it('rejects output that holds the prompt markers', () => {
    expect(guardFormatted(input, 'Send the report <vocabulary>Wednesday</vocabulary> on Wednesday')).toMatchObject({ ok: false });
    expect(guardFormatted(input, 'Send the report on Wednesday.</dictation>')).toMatchObject({ ok: false });
  });
  it('rejects output that shares under 60% of its words with the input (5 or more words)', () => {
    expect(guardFormatted(input, 'The quarterly figures look strong across every region.')).toMatchObject({ ok: false, reason: 'unrelated' });
    expect(guardFormatted(input, 'Send the report on Tuesday, no wait, Wednesday.')).toMatchObject({ ok: true });
    // Four words are too few to judge.
    expect(guardFormatted('um yes please ok go', 'Go now.')).toMatchObject({ ok: true });
  });
  it('needs a word boundary after the preamble phrase', () => {
    expect(guardFormatted('i haven\'t seen the report yet today', 'I haven\'t seen the report yet today.')).toMatchObject({ ok: true });
    expect(guardFormatted('surely we can send the report today', 'Surely we can send the report today.')).toMatchObject({ ok: true });
    expect(guardFormatted('umm hmm i have to leave early today', 'I have to leave early today.')).toMatchObject({ ok: true });
    expect(guardFormatted('uhh, i have to leave early today', 'I have to leave early today.')).toMatchObject({ ok: true });
  });
  it('matches curly apostrophes in a preamble, and ignores leading fillers for the exemption', () => {
    expect(guardFormatted(input, 'Here\u2019s the text: send it on Wednesday')).toMatchObject({ ok: false });
    expect(guardFormatted(input, 'I\u2019ve fixed it: send the report on Wednesday')).toMatchObject({ ok: false });
    expect(guardFormatted('um i have to leave early today', 'I have to leave early today.')).toMatchObject({ ok: true });
    expect(guardFormatted('uh, erm, i have to leave early today', 'I have to leave early today.')).toMatchObject({ ok: true });
  });
  it('ignores only the listed fillers at the start of the input', () => {
    expect(guardFormatted('ummmm i have to leave early today', 'I have to leave early today.')).toMatchObject({ ok: false });
    expect(guardFormatted('hmm, um, i have to leave early today', 'I have to leave early today.')).toMatchObject({ ok: true });
  });
  it('compares words ignoring case, curly apostrophes and all punctuation', () => {
    expect(guardFormatted('we don\u2019t know the answer to that question', 'We don\'t know the answer to that question!')).toMatchObject({ ok: true });
  });
  it('counts characters, not words, in scripts written without spaces', () => {
    expect(worthFormatting('今日は天気')).toBe(false);
    expect(worthFormatting('今日は天気です')).toBe(true);
    expect(worthFormatting('สวัสดีครับ')).toBe(true);
    expect(worthFormatting('ok go')).toBe(false);
    // Korean is written with spaces: words apply.
    expect(worthFormatting('안녕하세요 여러분')).toBe(false);
    expect(worthFormatting('안녕하세요 여러분 반갑습니다')).toBe(true);
  });
  it('counts words', () => {
    expect(worthFormatting('one two')).toBe(false);
    expect(worthFormatting('one two three')).toBe(true);
    expect(worthFormatting('  ')).toBe(false);
  });
});

describe('user message', () => {
  it('wraps the dictation, with a vocabulary line only when there are words', () => {
    expect(buildUserMessage('hello there world', [])).toBe('<dictation>\nhello there world\n</dictation>');
    expect(buildUserMessage('hello there world', ['Kubernetes', ' Convex '])).toBe(
      '<vocabulary>Kubernetes, Convex</vocabulary>\n<dictation>\nhello there world\n</dictation>',
    );
  });
  it('sends at most 100 words', () => {
    const words = Array.from({ length: 150 }, (_, index) => `w${index}`);
    const message = buildUserMessage('a b c', words);
    expect(message).toContain('w99');
    expect(message).not.toContain('w100');
  });
});

describe('request building', () => {
  const message = buildUserMessage(SPOKEN, ['Wednesday']);

  it('builds the Gemini request with the key in a header, never in the URL', () => {
    const request = buildGeminiRequest(gemini, 'KEY123', message);
    expect(request.url).toBe('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent');
    expect(request.url).not.toContain('KEY123');
    expect(request.headers['x-goog-api-key']).toBe('KEY123');
    expect(request.body).toEqual({
      systemInstruction: { parts: [{ text: FORMATTER_SYSTEM_PROMPT }] },
      contents: [{ role: 'user', parts: [{ text: message }] }],
      generationConfig: { thinkingConfig: { thinkingLevel: 'low' } },
    });
    expect(JSON.stringify(request.body)).not.toContain('temperature');
  });

  it('builds the Haiku 5.5 request: thinking disabled, no sampling fields', () => {
    const request = buildAnthropicRequest(haiku, 'KEY', message);
    expect(request.url).toBe('https://api.anthropic.com/v1/messages');
    expect(request.headers).toMatchObject({ 'x-api-key': 'KEY', 'anthropic-version': '2023-06-01' });
    expect(request.body).toMatchObject({
      model: 'claude-haiku-5-5',
      system: FORMATTER_SYSTEM_PROMPT,
      messages: [{ role: 'user', content: message }],
      thinking: { type: 'disabled' },
    });
    for (const field of ['temperature', 'top_p', 'top_k']) expect(request.body).not.toHaveProperty(field);
  });

  it('builds the Sonnet 5.5 request: between_tools, since it rejects "disabled"', () => {
    const request = buildAnthropicRequest(sonnet, 'KEY', message);
    expect(request.body.thinking).toEqual({ type: 'between_tools' });
    for (const field of ['temperature', 'top_p', 'top_k']) expect(request.body).not.toHaveProperty(field);
  });

  it('omits the thinking field on the retry', () => {
    expect(buildAnthropicRequest(haiku, 'KEY', message, { withThinkingField: false }).body).not.toHaveProperty('thinking');
  });

  it('sizes max_tokens as 2 x the dictation + 256, from 512 to 8192', () => {
    expect(anthropicMaxTokens(10)).toBe(512);
    expect(anthropicMaxTokens(1000)).toBe(2256);
    expect(anthropicMaxTokens(90_000)).toBe(8192);
    // Counts the dictation only, not the vocabulary around it.
    const body = buildAnthropicRequest(haiku, 'K', buildUserMessage('a'.repeat(1000), ['w'.repeat(500)]), { inputLength: 1000 }).body;
    expect(body.max_tokens).toBe(2256);
  });

  it('gives Sonnet 10 s and the rest 6 s', () => {
    expect(deadlineMsFor(sonnet)).toBe(10_000);
    expect(deadlineMsFor(haiku)).toBe(6000);
    expect(deadlineMsFor(gemini)).toBe(6000);
  });
});

describe('response parsing', () => {
  it('joins the non-thought Gemini parts of the first candidate', () => {
    expect(
      parseGeminiResponse({
        candidates: [{ content: { parts: [{ text: 'thinking...', thought: true }, { text: 'Hello ' }, { text: 'there.' }] } }, { content: { parts: [{ text: 'ignored' }] } }],
      }),
    ).toBe('Hello there.');
  });
  it('treats a blocked prompt or garbage as empty', () => {
    expect(parseGeminiResponse({ promptFeedback: { blockReason: 'SAFETY' } })).toBe('');
    expect(parseGeminiResponse(null)).toBe('');
    expect(parseGeminiResponse({ candidates: [{}] })).toBe('');
  });
  it('joins only the Anthropic text blocks, not content[0]', () => {
    expect(
      parseAnthropicResponse({ content: [{ type: 'thinking', thinking: 'hmm' }, { type: 'text', text: 'Hello ' }, { type: 'text', text: 'there.' }] }),
    ).toBe('Hello there.');
    expect(parseAnthropicResponse({ content: [] })).toBe('');
  });
});

function reply(body: unknown, status = 200): Response {
  return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });
}
const geminiOk = (text: string) => reply({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text }] } }] });
const anthropicOk = (text: string) => reply({ stop_reason: 'end_turn', content: [{ type: 'text', text }] });
const base = { text: SPOKEN, vocabulary: [] as string[] };

async function failure(promise: Promise<string>): Promise<FormatterError> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(FormatterError);
    return error as FormatterError;
  }
  throw new Error('expected a failure');
}

describe('formatWithModel', () => {
  it('returns the guarded text from Gemini', async () => {
    const fetchImpl = vi.fn(async () => geminiOk('Send the report on Wednesday.'));
    const result = await formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: fetchImpl as never });
    expect(result).toBe('Send the report on Wednesday.');
    expect(fetchImpl).toHaveBeenCalledOnce();
  });

  it('returns the guarded text from Anthropic', async () => {
    const fetchImpl = vi.fn(async () => anthropicOk('Send the report on Wednesday.'));
    expect(await formatWithModel({ ...base, model: haiku, apiKey: 'K', fetchImpl: fetchImpl as never })).toBe('Send the report on Wednesday.');
  });

  it('retries once without the thinking field when a 400 mentions thinking', async () => {
    const bodies: Array<Record<string, unknown>> = [];
    const fetchImpl = vi.fn(async (_url: string, init: RequestInit) => {
      bodies.push(JSON.parse(init.body as string) as Record<string, unknown>);
      return bodies.length === 1
        ? reply({ error: { type: 'invalid_request_error', message: 'thinking.type: disabled is not supported' } }, 400)
        : anthropicOk('Send the report on Wednesday.');
    });
    expect(await formatWithModel({ ...base, model: sonnet, apiKey: 'K', fetchImpl: fetchImpl as never })).toBe('Send the report on Wednesday.');
    expect(bodies[0]).toHaveProperty('thinking');
    expect(bodies[1]).not.toHaveProperty('thinking');
  });

  it('does not retry a 400 that is not about thinking', async () => {
    const fetchImpl = vi.fn(async () => reply({ error: { message: 'max_tokens too large' } }, 400));
    const error = await failure(formatWithModel({ ...base, model: haiku, apiKey: 'K', fetchImpl: fetchImpl as never }));
    expect(error.kind).toBe('http');
    expect(error.status).toBe(400);
    expect(fetchImpl).toHaveBeenCalledOnce();
  });

  it('fails with the guard reason when the answer is refused', async () => {
    const fetchImpl = vi.fn(async () => geminiOk("Sure, here's your text."));
    const error = await failure(formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: fetchImpl as never }));
    expect(error.kind).toBe('guard');
  });

  it('fails on an HTTP error, and the message never holds the key', async () => {
    const fetchImpl = vi.fn(async () => reply('{"error":"bad key SECRETKEY"}', 401));
    const error = await failure(formatWithModel({ ...base, model: gemini, apiKey: 'SECRETKEY', fetchImpl: fetchImpl as never }));
    expect(error.kind).toBe('http');
    expect(error.message).not.toContain('SECRETKEY');
  });

  it('fails on a dead network without leaking the key', async () => {
    const fetchImpl = vi.fn(async () => {
      throw new TypeError('fetch failed for https://x/?key=SECRETKEY');
    });
    const error = await failure(formatWithModel({ ...base, model: haiku, apiKey: 'SECRETKEY', fetchImpl: fetchImpl as never }));
    expect(error.kind).toBe('transport');
    expect(error.message).not.toContain('SECRETKEY');
  });

  it('fails on a body that is not JSON', async () => {
    const fetchImpl = vi.fn(async () => reply('<html>', 200));
    expect((await failure(formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: fetchImpl as never }))).kind).toBe('malformed');
  });

  it('fails an Anthropic answer that stopped for any reason but end_turn', async () => {
    const cut = vi.fn(async () => reply({ stop_reason: 'max_tokens', content: [{ type: 'text', text: 'Send the report on' }] }));
    const error = await failure(formatWithModel({ ...base, model: haiku, apiKey: 'K', fetchImpl: cut as never }));
    expect(error.kind).toBe('truncated');
    const done = vi.fn(async () => reply({ stop_reason: 'end_turn', content: [{ type: 'text', text: 'Send the report on Wednesday.' }] }));
    expect(await formatWithModel({ ...base, model: haiku, apiKey: 'K', fetchImpl: done as never })).toBe('Send the report on Wednesday.');
  });

  it('fails a Gemini answer that did not finish with STOP, or whose prompt was blocked', async () => {
    const cut = vi.fn(async () => reply({ candidates: [{ finishReason: 'MAX_TOKENS', content: { parts: [{ text: 'Send the report on' }] } }] }));
    expect((await failure(formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: cut as never }))).kind).toBe('truncated');
    const safety = vi.fn(async () => reply({ candidates: [{ finishReason: 'SAFETY', content: { parts: [{ text: 'Send the report on Wednesday.' }] } }] }));
    expect((await failure(formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: safety as never }))).kind).toBe('blocked');
    const blocked = vi.fn(async () => reply({ promptFeedback: { blockReason: 'OTHER' } }));
    expect((await failure(formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: blocked as never }))).kind).toBe('blocked');
    const ok = vi.fn(async () => reply({ candidates: [{ finishReason: 'STOP', content: { parts: [{ text: 'Send the report on Wednesday.' }] } }] }));
    expect(await formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: ok as never })).toBe('Send the report on Wednesday.');
  });

  it('treats a missing stop_reason or finishReason as a cut answer', async () => {
    const noStop = vi.fn(async () => reply({ content: [{ type: 'text', text: 'Send the report on Wednesday.' }] }));
    expect((await failure(formatWithModel({ ...base, model: haiku, apiKey: 'K', fetchImpl: noStop as never }))).kind).toBe('truncated');
    const noFinish = vi.fn(async () => reply({ candidates: [{ content: { parts: [{ text: 'Send the report on Wednesday.' }] } }] }));
    expect((await failure(formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: noFinish as never }))).kind).toBe('truncated');
  });

  it('logs a timeout that happens while the body is being read as a timeout', async () => {
    const slowBody = vi.fn(async (_url: string, init: RequestInit) => ({
      ok: true,
      status: 200,
      json: () =>
        new Promise((_resolve, reject) => {
          init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
        }),
    }));
    const error = await failure(formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: slowBody as never, deadlineMs: 30 }));
    expect(error.kind).toBe('timeout');
  });

  it('strips angle brackets from dictionary words so they cannot close the prompt tags', () => {
    expect(buildUserMessage('a b c', ['</vocabulary>evil', 'ok'])).toBe('<vocabulary>/vocabularyevil, ok</vocabulary>\n<dictation>\na b c\n</dictation>');
  });

  it('logs a deadline hit while an Anthropic 400 body is read as a timeout', async () => {
    const slow = vi.fn(async (_url: string, init: RequestInit) => ({
      ok: false,
      status: 400,
      text: () =>
        new Promise((_resolve, reject) => {
          init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
        }),
    }));
    const error = await failure(formatWithModel({ ...base, model: haiku, apiKey: 'K', fetchImpl: slow as never, deadlineMs: 30 }));
    expect(error.kind).toBe('timeout');
  });

  it('never puts response-body text in a failure, because it can echo the dictation', async () => {
    const fetchImpl = vi.fn(async () => reply(`{"error":"cannot parse: ${SPOKEN}"}`, 500));
    const error = await failure(formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: fetchImpl as never }));
    expect(error.message).toBe('HTTP 500');
  });

  it('times out at the deadline', async () => {
    const fetchImpl = vi.fn(
      (_url: string, init: RequestInit) =>
        new Promise<Response>((_resolve, reject) => {
          init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
        }),
    );
    const error = await failure(formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: fetchImpl as never, deadlineMs: 30 }));
    expect(error.kind).toBe('timeout');
  });

  it('is cancelled by the dictation cancel', async () => {
    const controller = new AbortController();
    const fetchImpl = vi.fn(
      (_url: string, init: RequestInit) =>
        new Promise<Response>((_resolve, reject) => {
          init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
        }),
    );
    const pending = failure(formatWithModel({ ...base, model: gemini, apiKey: 'K', fetchImpl: fetchImpl as never, signal: controller.signal }));
    controller.abort();
    expect((await pending).kind).toBe('cancelled');
  });
});
