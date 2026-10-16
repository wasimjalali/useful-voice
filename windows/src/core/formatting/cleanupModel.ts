/**
 * The seam between the cleanup pipeline and whatever runs the local model. Mirrors
 * `Sources/UsefulVoiceCore/CleanupModel/CleanupModel.swift`.
 *
 * `clean` resolves to null on any failure: the model is not loaded and could not be, it
 * timed out, it threw, or it had nothing to say. The caller then keeps the rules-only text.
 * `deadline` is an absolute instant on the `performance.now()` clock, not a budget, so time
 * spent waiting in a queue (a model still loading, say) counts against it. An
 * implementation must stop by the deadline where it can, and the pipeline stops waiting at
 * the deadline either way.
 */
export interface CleanupModel {
  clean(text: string, controlLine: string, deadline: number): Promise<string | null>;
}

/**
 * The one blocking call under `LocalCleanupModel`: load weights, run a rendered prompt, free
 * them. The Windows app implements it with node-llama-cpp in a child process
 * (`src/main/cleanupModel/llamaGenerator.ts`); tests use a fake. Calls are serialised by
 * `LocalCleanupModel`, so an implementation needs no locking.
 */
export interface CleanupTextGenerator {
  load(modelPath: string): Promise<void>;
  /** Runs the prompt to the end of the model's turn. Rejects when the deadline passes. */
  generate(prompt: string, deadline: number): Promise<string>;
  unload(): Promise<void>;
}
