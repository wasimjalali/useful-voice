import Foundation
import whisper

/// Read-only probes of the linked whisper.cpp, used to prove it can sit in one process next
/// to llama.cpp (`LlamaWhisperCoexistenceTests`). Nothing in the app calls them.
public enum WhisperRuntimeInfo {
    /// What whisper.cpp reports about its CPU and GPU features.
    public static func systemInfo() -> String {
        String(cString: whisper_print_system_info())
    }

    /// Creates and frees a context from a model file, on the CPU unless `useGPU`.
    public static func canLoad(modelAt url: URL, useGPU: Bool = false) -> Bool {
        var params = whisper_context_default_params()
        params.use_gpu = useGPU
        guard let ctx = url.path.withCString({ whisper_init_from_file_with_params($0, params) }) else {
            return false
        }
        whisper_free(ctx)
        return true
    }
}
