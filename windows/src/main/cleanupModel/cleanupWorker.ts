/**
 * The child process that holds S1-mini in memory. `llamaGenerator.ts` forks it and talks to
 * it over the IPC channel; killing it is how the weights are given back to the system, so
 * "unload after 60 s idle" really frees the memory and a stuck run can never hang the app.
 *
 * It runs as plain Node (`ELECTRON_RUN_AS_NODE`), not inside Electron's main process, so a
 * native crash in llama.cpp takes down this process and nothing else.
 *
 * Runtime: node-llama-cpp (MIT), CPU only (`gpu: false`) and prebuilt binaries only
 * (`build: 'never'`). Prompt: the raw template from the S1-mini model card with the think
 * block already closed. The template parts are tokenised with special tokens and the
 * dictation without, and there is no chat-template layer to get wrong. Decoding: greedy (`temperature: 0`). Output: no `maxTokens`, it runs to the
 * model's own end-of-turn token.
 *
 * Messages in: `{type:'load', path, prefix}`, `{type:'generate', id, head, user, tail}`,
 * `{type:'abort', id}`, `{type:'probe'}` (start the runtime without a model, for the packaged
 * app's self-test), `{type:'dispose'}`. Messages out: `{type:'ready'}`, `{type:'loaded', loadMs}`,
 * `{type:'result', id, text, ms}`, `{type:'probed', gpu, systemInfo}`, `{type:'error', id?, message}`.
 */
import type { Llama, LlamaCompletion, LlamaContext, LlamaContextSequence, LlamaModel, Token } from 'node-llama-cpp';

/** Enough for about 900 spoken words in and out; far more than the 1.5 s deadline allows. */
export const WORKER_CONTEXT_SIZE = 2048;

/** Tokens of headroom for the answer's end-of-turn token and tokenizer rounding. */
const CONTEXT_HEADROOM = 32;

type Incoming =
  | { type: 'load'; path: string; prefix: string }
  | { type: 'generate'; id: number; head: string; user: string; tail: string }
  | { type: 'probe' }
  | { type: 'abort'; id: number }
  | { type: 'dispose' };

let llama: Llama | null = null;
let model: LlamaModel | null = null;
let context: LlamaContext | null = null;
let sequence: LlamaContextSequence | null = null;
let completion: LlamaCompletion | null = null;
let prefixLength = 0;
let busy = false;
const aborts = new Map<number, AbortController>();

function send(message: Record<string, unknown>): void {
  process.send?.(message);
}

function fail(error: unknown, id?: number): void {
  send({ type: 'error', id, message: error instanceof Error ? error.message : String(error) });
}

async function load(modelPath: string, promptPrefix: string): Promise<void> {
  const started = performance.now();
  const lib = await import('node-llama-cpp');
  llama = await lib.getLlama({ gpu: false, build: 'never', logLevel: lib.LlamaLogLevel.error });
  model = await llama.loadModel({ modelPath });
  context = await model.createContext({ contextSize: WORKER_CONTEXT_SIZE, flashAttention: false });
  sequence = context.getSequence();
  completion = new lib.LlamaCompletion({ contextSequence: sequence });
  // Run the fixed start of every prompt once now, while the person is still talking. That
  // pages the weights in and keeps the system prompt in the context, so the first real
  // request only has the control line and the transcript left to read.
  await sequence.evaluateWithoutGeneratingNewTokens(model.tokenize(promptPrefix, true));
  prefixLength = sequence.nextTokenIndex;
  send({ type: 'loaded', loadMs: Math.round(performance.now() - started) });
}

/** Empties the context after a request so every request starts from the same state. */
async function resetSequence(): Promise<void> {
  if (sequence && sequence.nextTokenIndex > prefixLength) {
    await sequence.eraseContextTokenRanges([{ start: prefixLength, end: sequence.nextTokenIndex }]);
  }
}

async function generate(id: number, head: string, user: string, tail: string): Promise<void> {
  if (!model || !completion) throw new Error('the model is not loaded');
  if (busy) throw new Error('a request is already running');
  busy = true;
  const controller = new AbortController();
  aborts.set(id, controller);
  const started = performance.now();
  let text: string;
  try {
    // The template parts may hold special tokens; the dictation never may, so a dictation
    // that says "<|im_end|>" is read as those characters, not as the end of a turn.
    const tokens: Token[] = [...model.tokenize(head, true), ...model.tokenize(user, false), ...model.tokenize(tail, true)];
    if (tokens.length * 2 + CONTEXT_HEADROOM > WORKER_CONTEXT_SIZE) {
      throw new Error(`the text is too long for the context (${tokens.length} tokens)`);
    }
    text = await completion.generateCompletion(tokens, { temperature: 0, signal: controller.signal });
  } catch (error) {
    await finishRequest(id);
    throw error;
  }
  // Answer only once the context is back to the shared prefix, so the next request can't
  // arrive while this one is still tidying up.
  await finishRequest(id);
  send({ type: 'result', id, text, ms: Math.round(performance.now() - started) });
}

async function finishRequest(id: number): Promise<void> {
  aborts.delete(id);
  await resetSequence().catch(() => undefined);
  busy = false;
}

/** Starts the runtime without a model: proves the binaries load. */
async function probe(): Promise<void> {
  const lib = await import('node-llama-cpp');
  const instance = await lib.getLlama({ gpu: false, build: 'never', logLevel: lib.LlamaLogLevel.error });
  send({ type: 'probed', gpu: instance.gpu, systemInfo: instance.systemInfo });
  await instance.dispose();
}

async function dispose(): Promise<void> {
  for (const controller of aborts.values()) controller.abort();
  await context?.dispose().catch(() => undefined);
  await model?.dispose().catch(() => undefined);
  await llama?.dispose().catch(() => undefined);
  completion = null;
  sequence = null;
  context = null;
  model = null;
  llama = null;
}

process.on('message', (message: Incoming) => {
  switch (message.type) {
    case 'load':
      load(message.path, message.prefix).catch((error: unknown) => fail(error));
      break;
    case 'generate':
      generate(message.id, message.head, message.user, message.tail).catch((error: unknown) => fail(error, message.id));
      break;
    case 'probe':
      probe().catch((error: unknown) => fail(error));
      break;
    case 'abort':
      aborts.get(message.id)?.abort(new Error('deadline'));
      break;
    case 'dispose':
      dispose().finally(() => process.exit(0));
      break;
  }
});

// The parent is gone: nobody can ask for text any more, so free the memory by leaving.
process.on('disconnect', () => process.exit(0));
send({ type: 'ready' });
