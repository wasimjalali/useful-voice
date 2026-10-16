import Foundation

/// The seam between the cleanup pipeline and whatever runs the local model.
///
/// `clean` returns nil on any failure: the model is not loaded and could not be, it timed
/// out, it threw, or it had nothing to say. The caller then keeps the rules-only text.
/// `deadline` is an absolute instant, not a budget, so time spent waiting in a queue (a
/// model still loading, say) counts against it. An implementation must stop by the deadline
/// where it can, and the pipeline stops waiting at the deadline either way.
/// `windows/src/core/formatting/cleanupModel.ts` mirrors this file.
public protocol CleanupModel: Sendable {
    func clean(_ text: String, controlLine: String, deadline: ContinuousClock.Instant) async -> String?
}

/// The one blocking call under `LocalCleanupModel`: load weights, run a rendered prompt, free
/// them. The macOS app implements it with llama.cpp (`LlamaCleanupGenerator`); tests use a
/// fake. Calls are serialised by `LocalCleanupModel`, so an implementation needs no locking.
public protocol CleanupTextGenerator: AnyObject, Sendable {
    func load(modelAt url: URL) throws
    /// Runs the prompt to the end of the model's turn. Throws when the deadline passes.
    func generate(prompt: String, deadline: ContinuousClock.Instant) throws -> String
    func unload()
}
