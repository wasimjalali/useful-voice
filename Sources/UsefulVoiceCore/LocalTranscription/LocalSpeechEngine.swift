import Foundation

/// Options for one local transcription call.
public struct LocalTranscriptionOptions: Sendable {
    /// A whisper language code ("en", "fa", "de", …) or nil for auto-detect.
    public var language: String?
    /// Dictionary terms joined as an initial prompt, biasing spelling toward
    /// the user's vocabulary — the local analogue of Deepgram keyterms.
    public var initialPrompt: String?

    public init(language: String?, initialPrompt: String?) {
        self.language = language
        self.initialPrompt = initialPrompt
    }
}

/// What a local engine produced for one utterance.
public struct LocalTranscriptionResult: Sendable {
    public var text: String
    /// Whisper's detected language code, when detection ran.
    public var detectedLanguage: String?
    /// Audio duration in seconds, as measured from the sample count.
    public var durationSeconds: Double?

    public init(text: String, detectedLanguage: String?, durationSeconds: Double?) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.durationSeconds = durationSeconds
    }
}

public enum LocalEngineError: Error, Equatable {
    /// The model file could not be loaded into a context.
    case modelLoadFailed(String)
    /// whisper_full returned a non-zero status.
    case transcriptionFailed(Int)
}

/// A local (on-device) speech-to-text engine. Nothing the engine sees leaves
/// the machine — no network, no key, no telemetry.
///
/// The protocol is deliberately engine-agnostic: `LocalWhisperProvider` talks
/// to this surface, so a second engine (Apple MLX) slots in behind it without
/// touching the provider or the dictation pipeline.
///
/// Conforming engines must serialize their own work: one loaded model context
/// at a time, one transcription in flight.
public protocol LocalSpeechEngine: Sendable {
    /// Short name for history/diagnostics, e.g. "whisper.cpp".
    var engineName: String { get }

    /// The model file currently loaded, if any.
    var loadedModelURL: URL? { get async }

    /// Releases the model context and its memory.
    func unload() async

    /// Transcribes 16 kHz mono float PCM with the model at `modelURL`.
    ///
    /// Loading is part of this one call, not a separate step: the engine loads
    /// (or swaps to) `modelURL` when it is not the current context, then
    /// decodes with no suspension point in between, so a concurrent `unload`
    /// can never land between the load and the decode. A different URL than
    /// `loadedModelURL` frees the old context first, so switching models
    /// mid-session releases the previous weights before allocating new ones.
    ///
    /// `onSegment` fires with each new text segment as it is decoded, so the UI
    /// can show partial results while a long dictation is still processing.
    func transcribe(
        modelURL: URL,
        samples: [Float],
        options: LocalTranscriptionOptions,
        onSegment: (@Sendable (String) -> Void)?
    ) async throws -> LocalTranscriptionResult
}
