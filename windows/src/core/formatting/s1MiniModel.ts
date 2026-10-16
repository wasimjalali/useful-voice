import { S1_MINI_SYSTEM_PROMPT } from './cleanupControlLine.js';
import type { GeneratorPrompt } from './cleanupModel.js';

/**
 * S1-mini by Superwhisper (Apache 2.0 plus one term: it must always be credited as
 * "S1-mini" by "Superwhisper", with that exact capitalisation). A Qwen3-0.6B fine-tune that
 * resolves self-corrections and formats numbers, dates and emails. Mirrors
 * `Sources/UsefulVoiceCore/CleanupModel/S1MiniModel.swift`: same pins, same prompt.
 *
 * The weights are pinned to one Hugging Face revision and one SHA-256.
 */
export const S1_MINI_CREDIT = 'S1-mini by Superwhisper';

/** superwhisper/s1-mini-GGUF, the commit the model card and the eval were read at. */
export const S1_MINI_REVISION = '34add00a48a2e5d24e5a4ee5405a99620a3a240c';

export interface PinnedModelFile {
  id: string;
  fileName: string;
  url: string;
  bytes: number;
  sha256: string;
}

export const S1_MINI_MODEL: PinnedModelFile = {
  id: 's1-mini-q4_k_m',
  fileName: 's1-mini-q4_k_m.gguf',
  url: `https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/${S1_MINI_REVISION}/s1-mini-q4_k_m.gguf`,
  bytes: 484_219_808,
  sha256: '3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634',
};

/**
 * The raw prompt the model card documents for runtimes that do not apply the embedded chat
 * template. The assistant turn opens with an empty think block (two newlines inside it, two
 * after), which is what `enable_thinking: false` renders: S1-mini was trained with thinking
 * off. The system prompt is `S1_MINI_SYSTEM_PROMPT`, verbatim; the user message is the
 * control line, a newline and the transcript.
 */
export function s1MiniPrompt(controlLine: string, text: string): string {
  const { head, user, tail } = s1MiniPromptParts(controlLine, text);
  return head + user + tail;
}

/** The same prompt in the three parts a runtime tokenises differently (see `GeneratorPrompt`). */
export function s1MiniPromptParts(controlLine: string, text: string): GeneratorPrompt {
  return {
    head: s1MiniPromptPrefix(),
    user: `${controlLine}\n${text}`,
    tail: '<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n',
  };
}

/** The start every prompt shares: the system turn and the opening of the user turn. */
export function s1MiniPromptPrefix(): string {
  return `<|im_start|>system\n${S1_MINI_SYSTEM_PROMPT}<|im_end|>\n<|im_start|>user\n`;
}
