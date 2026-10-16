import Foundation
import UsefulVoiceCore
import UsefulVoiceLlama

/// llama.cpp behind `CleanupTextGenerator`, for the hidden S1-mini cleanup. Lives in the app
/// target because it is the only place that links `UsefulVoiceLlama`: the Core target stays
/// free of the second ggml.
///
/// The CPU runs the model: llama.cpp can only stop a running decode on the CPU, which is what
/// makes the deadline strict, and for a 0.6B model the CPU was faster than Metal in the
/// measurements (see the PR). Pass `placement: .metal` to try Metal.
public final class LlamaCleanupGenerator: CleanupTextGenerator, @unchecked Sendable {
    private let placement: LlamaRuntime.Placement
    private var runtime: LlamaRuntime?

    public init(placement: LlamaRuntime.Placement = .cpuOnly) {
        self.placement = placement
    }

    public func load(modelAt url: URL) throws {
        runtime = try LlamaRuntime(modelPath: url.path, placement: placement)
    }

    public func generate(prompt: CleanupPrompt, deadline: ContinuousClock.Instant) throws -> String {
        guard let runtime else { throw LlamaRuntime.RuntimeError.modelLoadFailed("not loaded") }
        let segments = prompt.segments.map { LlamaRuntime.PromptSegment(text: $0.text, parseSpecial: $0.parseSpecial) }
        return try runtime.complete(segments: segments, deadline: deadline).text
    }

    public func unload() {
        runtime = nil
    }
}

/// The hidden cleanup model the dictation controller is given. Nil while the hidden
/// `UV_CLEANUP_MODEL` flag is off, so a normal launch builds nothing and loads nothing. The
/// controller preloads it at the press, the pipeline runs it at the cleanup step, and it
/// unloads itself after `CleanupModelPolicy.defaultIdleUnload`. Nothing runs at quit: the
/// process exit frees the weights.
public enum HiddenCleanupModel {
    public static let shared: LocalCleanupModel? = {
        guard CleanupModelFlag.isOn else { return nil }
        let store = LocalModelStore()
        return LocalCleanupModel(
            modelURL: store.fileURL(for: S1MiniModel.model), generator: LlamaCleanupGenerator())
    }()

    private static let downloader = ModelDownloader(store: LocalModelStore())

    /// With the hidden flag on, on a Mac with enough memory, fetches the pinned weights once
    /// through the existing downloader (resumable, SHA-256 checked before it installs). With the
    /// flag off, or the weights already there, it does nothing. Returns at once.
    public static func downloadIfNeeded() {
        guard shared != nil,
              CleanupModelPolicy.memoryAllowsModel(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory),
              LocalModelStore().availability(of: S1MiniModel.model) != .usable else { return }
        downloader.start(model: S1MiniModel.model)
    }
}
