import Foundation
import whisper

/// whisper.cpp implementation of `LocalSpeechEngine`, via the official
/// XCFramework (Metal backend included upstream, enabled through `use_gpu`).
///
/// An actor because every whisper entry point mutates shared context state and
/// is documented "not thread safe for same context" — actor isolation is the
/// serialization the protocol requires, and `whisper_full`'s blocking work runs
/// on the cooperative pool rather than any UI thread.
public actor WhisperCppEngine: LocalSpeechEngine {
    public let engineName = "whisper.cpp"

    public private(set) var loadedModelURL: URL?
    private var context: OpaquePointer?

    public init() {}

    /// The decoding params are configured for dictation, not translation:
    /// transcribe in the spoken language, timestamps on (harmless, and the
    /// segment callbacks that drive partial results are keyed to them),
    /// context carry-over on so mid-dictation phrasing stays consistent.
    private static func makeParams(
        language: String?,
        initialPrompt: String?,
        onSegment: (@Sendable (String) -> Void)?
    ) -> (whisper_full_params, SegmentBox?) {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.single_segment = false
        params.no_timestamps = false
        params.tdrz_enable = false
        // Suppress whisper's tendency to emit non-speech tokens ("[BLANK_AUDIO]",
        // music notes) on quiet passages.
        params.suppress_nst = true

        let box: SegmentBox?
        if let onSegment {
            box = SegmentBox(handler: onSegment)
            params.new_segment_callback = whisperSegmentCallback
            params.new_segment_callback_user_data =
                Unmanaged.passUnretained(box!).toOpaque()
        } else {
            box = nil
        }
        return (params, box)
    }

    /// Ensures `modelURL` is the loaded context, loading or reloading as needed.
    private func ensureLoaded(modelURL: URL) async throws {
        if loadedModelURL == modelURL, context != nil { return }
        try await load(modelURL: modelURL)
    }

    /// Works around a ggml-metal teardown bug in this XCFramework: Metal
    /// residency sets keep freed buffers registered for a keep-alive window
    /// (180 s), and `ggml_metal_device_free` asserts the set is empty during
    /// static destruction at process exit — so quitting the app (or the test
    /// runner) within 3 minutes of a transcription aborts with SIGABRT.
    /// Disabling residency sets avoids the assert entirely; the buffers take
    /// the normal decommit path instead. Set without overwrite so a user's
    /// explicit environment still wins.
    private static func prepareEnvironment() {
        setenv("GGML_METAL_NO_RESIDENCY", "1", 0)
    }

    public func load(modelURL: URL) async throws {
        // Free first: holding two large contexts at once on a small-memory Mac
        // is exactly the thrash the bigger model must avoid.
        let previous = context
        context = nil
        loadedModelURL = nil
        if let previous { whisper_free(previous) }

        Self.prepareEnvironment()

        var contextParams = whisper_context_default_params()
        contextParams.use_gpu = true       // Metal
        contextParams.flash_attn = true

        guard let ctx = modelURL.path.withCString({ path in
            whisper_init_from_file_with_params(path, contextParams)
        }) else {
            throw LocalEngineError.modelLoadFailed(
                "could not load \(modelURL.lastPathComponent)")
        }
        context = ctx
        loadedModelURL = modelURL
    }

    public func unload() async {
        if let context { whisper_free(context) }
        context = nil
        loadedModelURL = nil
    }

    /// Loads the model when needed and transcribes. `whisper_full` blocks until
    /// decoding finishes; the actor keeps that off the caller's thread.
    public func transcribe(
        samples: [Float],
        options: LocalTranscriptionOptions,
        onSegment: (@Sendable (String) -> Void)?
    ) async throws -> LocalTranscriptionResult {
        guard let context, loadedModelURL != nil else {
            throw LocalEngineError.notLoaded
        }
        guard !samples.isEmpty else {
            return LocalTranscriptionResult(text: "", detectedLanguage: nil,
                                          durationSeconds: 0)
        }

        var (params, box) = Self.makeParams(
            language: options.language,
            initialPrompt: options.initialPrompt,
            onSegment: onSegment)
        // The box is retained by this scope for the duration of the C call.
        defer { _ = box }

        let languageCode = options.language ?? "auto"
        let promptText = options.initialPrompt ?? ""
        let status: Int32 = languageCode.withCString { lang in
            params.language = lang
            params.detect_language = options.language == nil
            return promptText.withCString { prompt in
                params.initial_prompt = promptText.isEmpty ? nil : prompt
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress,
                                 Int32(buffer.count))
                }
            }
        }
        guard status == 0 else {
            throw LocalEngineError.transcriptionFailed(Int(status))
        }

        let segmentCount = Int(whisper_full_n_segments(context))
        var parts: [String] = []
        parts.reserveCapacity(segmentCount)
        for i in 0..<segmentCount {
            if let text = whisper_full_get_segment_text(context, Int32(i)) {
                parts.append(String(cString: text))
            }
        }
        let joined = parts.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Meaningful only when detection ran; for a pinned language the pin is
        // already known to the caller.
        var detected: String? = nil
        if options.language == nil {
            let langID = whisper_full_lang_id(context)
            if let str = whisper_lang_str(langID) {
                detected = String(cString: str)
            }
        }

        return LocalTranscriptionResult(
            text: joined,
            detectedLanguage: detected,
            durationSeconds: Double(samples.count) / Double(WavReader.requiredSampleRate))
    }
}

/// Retains the Swift-side segment handler so it can ride through C's `void *`.
private final class SegmentBox {
    let handler: @Sendable (String) -> Void
    init(handler: @escaping @Sendable (String) -> Void) { self.handler = handler }
}

/// C entry point for `new_segment_callback`. Reads the newly completed segments
/// off the context and forwards them to the Swift handler.
private let whisperSegmentCallback: whisper_new_segment_callback = {
    ctx, _, nNew, userData in
    guard let ctx, let userData else { return }
    let box = Unmanaged<SegmentBox>.fromOpaque(userData).takeUnretainedValue()
    let total = Int(whisper_full_n_segments(ctx))
    let first = max(0, total - Int(nNew))
    guard first < total else { return }
    var text = ""
    for i in first..<total {
        if let segment = whisper_full_get_segment_text(ctx, Int32(i)) {
            text += String(cString: segment)
        }
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { box.handler(trimmed) }
}
