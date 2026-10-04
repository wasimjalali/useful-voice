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
    private var idleTask: Task<Void, Never>?
    private let idleUnloadAfter: Duration

    public init(idleUnloadAfter: Duration = .seconds(10 * 60)) {
        self.idleUnloadAfter = idleUnloadAfter
    }

    /// A released engine must not leak the context's Metal buffers.
    deinit {
        if let context { whisper_free(context) }
    }

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

    /// Loads `modelURL` into a fresh context, freeing any previous one first.
    /// Synchronous on purpose: `transcribe` calls it with no suspension point
    /// before decoding.
    private func load(modelURL: URL) throws {
        // Free first: holding two large contexts at once on a small-memory Mac
        // is exactly the thrash the bigger model must avoid.
        let previous = context
        context = nil
        loadedModelURL = nil
        if let previous { whisper_free(previous) }

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
        idleTask?.cancel()
        idleTask = nil
        if let context { whisper_free(context) }
        context = nil
        loadedModelURL = nil
    }

    /// Frees the context 10 minutes after the last transcription, so a model
    /// that is no longer in use does not hold gigabytes for the rest of the
    /// session. A later `transcribe` cancels the pending unload (and the next
    /// one reloads on demand). Actor isolation means this can never run while
    /// `whisper_full` is decoding.
    private func scheduleIdleUnload() {
        idleTask?.cancel()
        let delay = idleUnloadAfter
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.unloadIfIdle()
        }
    }

    /// Runs on the actor after the idle sleep. A `transcribe` that started
    /// after the sleep ended has already cancelled this task, so the check
    /// keeps its context.
    private func unloadIfIdle() async {
        guard !Task.isCancelled else { return }
        await unload()
    }

    /// Loads the model when needed and transcribes. `whisper_full` blocks until
    /// decoding finishes; the actor keeps that off the caller's thread. There is
    /// no `await` between the load and the decode, so nothing can unload the
    /// context in between.
    public func transcribe(
        modelURL: URL,
        samples: [Float],
        options: LocalTranscriptionOptions,
        onSegment: (@Sendable (String) -> Void)?
    ) async throws -> LocalTranscriptionResult {
        idleTask?.cancel()
        idleTask = nil
        defer { scheduleIdleUnload() }

        if loadedModelURL != modelURL || context == nil {
            try load(modelURL: modelURL)
        }
        guard let context else {
            throw LocalEngineError.modelLoadFailed(
                "could not load \(modelURL.lastPathComponent)")
        }
        guard !samples.isEmpty else {
            return LocalTranscriptionResult(text: "", detectedLanguage: nil,
                                          durationSeconds: 0)
        }

        let (baseParams, box) = Self.makeParams(
            language: options.language,
            initialPrompt: options.initialPrompt,
            onSegment: onSegment)
        var params = baseParams

        let languageCode = options.language ?? "auto"
        let promptText = options.initialPrompt ?? ""
        // `detect_language` stays false: in whisper.cpp it means "detect the
        // language and stop", which returns zero segments. Passing "auto" as
        // the language already detects first and then transcribes.
        params.detect_language = false
        // The box must outlive the C call: the callback reads it through a raw
        // pointer, so extend its lifetime explicitly.
        let status: Int32 = withExtendedLifetime(box) {
            languageCode.withCString { lang in
                params.language = lang
                return promptText.withCString { prompt in
                    params.initial_prompt = promptText.isEmpty ? nil : prompt
                    return samples.withUnsafeBufferPointer { buffer in
                        whisper_full(context, params, buffer.baseAddress,
                                     Int32(buffer.count))
                    }
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
