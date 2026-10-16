import Foundation
import UsefulVoiceCore
import UsefulVoiceLlama

/// llama.cpp behind `CleanupTextGenerator`, for the hidden S1-mini cleanup. Lives in the app
/// target because it is the only place that links `UsefulVoiceLlama`: the Core target stays
/// free of the second ggml.
///
/// The CPU runs the model: llama.cpp can only stop a running decode on the CPU, which is what
/// makes the deadline strict, and for a 0.6B model the CPU was faster than Metal in the
/// measurements (see the PR). Pass `gpuLayers: -1` to try Metal.
public final class LlamaCleanupGenerator: CleanupTextGenerator, @unchecked Sendable {
    private let gpuLayers: Int32
    private var runtime: LlamaRuntime?

    public init(gpuLayers: Int32 = 0) {
        self.gpuLayers = gpuLayers
    }

    public func load(modelAt url: URL) throws {
        runtime = try LlamaRuntime(modelPath: url.path, gpuLayers: gpuLayers)
    }

    public func generate(prompt: String, deadline: ContinuousClock.Instant) throws -> String {
        guard let runtime else { throw LlamaRuntime.RuntimeError.modelLoadFailed("not loaded") }
        return try runtime.complete(prompt: prompt, deadline: deadline).text
    }

    public func unload() {
        runtime = nil
    }
}

/// The few lines the dictation flow needs once it is wired in (phase 2):
///
///     let cleanup = HiddenCleanupModel.shared          // nil unless the flag is on
///     Task { await cleanup?.begin() }                    // dictation starts
///     ... later, at the cleanup marker ...
///     let result = await CleanupPipeline.run(raw: text, language: lang, category: cat,
///         style: style, gates: .current(), model: cleanup)
///     Task { await cleanup?.end() }                      // dictation ends or is cancelled
public enum HiddenCleanupModel {
    /// Nil while the hidden flag is off, so a normal launch builds nothing and loads nothing.
    public static let shared: LocalCleanupModel? = {
        guard CleanupModelFlag.isOn else { return nil }
        let store = LocalModelStore()
        return LocalCleanupModel(
            modelURL: store.fileURL(for: S1MiniModel.model), generator: LlamaCleanupGenerator())
    }()
}
