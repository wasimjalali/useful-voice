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

/// A rendered prompt in parts, so a runtime can tokenize the template's control tokens as
/// such and the person's words as plain text.
public struct CleanupPrompt: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var text: String
        /// True for the template's own control tokens, false for the person's words.
        public var parseSpecial: Bool

        public init(text: String, parseSpecial: Bool) {
            self.text = text
            self.parseSpecial = parseSpecial
        }
    }

    public var segments: [Segment]

    public init(segments: [Segment]) { self.segments = segments }

    /// The whole prompt as one string (what a runtime without the split would be given).
    public var text: String { segments.map(\.text).joined() }
}

/// The one blocking call under `LocalCleanupModel`: load weights, run a rendered prompt, free
/// them. The macOS app implements it with llama.cpp (`LlamaCleanupGenerator`); tests use a
/// fake. Calls are serialised by `LocalCleanupModel`, so an implementation needs no locking.
public protocol CleanupTextGenerator: AnyObject, Sendable {
    func load(modelAt url: URL) throws
    /// Runs the prompt to the end of the model's turn. Throws when the deadline passes.
    func generate(prompt: CleanupPrompt, deadline: ContinuousClock.Instant) throws -> String
    func unload()
    /// Asks a load or a run that is in progress on another thread to stop at once, at quit.
    /// Called from any thread; the call returns without waiting. Nothing to stop by default.
    func requestStop()
}

extension CleanupTextGenerator {
    public func requestStop() {}
}
