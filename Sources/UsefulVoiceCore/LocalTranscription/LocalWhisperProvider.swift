import Foundation

/// `TranscriptionProvider` backed by a local engine (whisper.cpp today, MLX
/// later behind the same `LocalSpeechEngine` seam).
///
/// Everything runs on-device: no API key, no network, no audio leaving the Mac.
/// The provider validates the model file before every dictation — a deleted or
/// half-overwritten model fails with an actionable error rather than an engine
/// crash — and lazily (re)loads the context when the active model file changes,
/// so switching models mid-session is clean.
public final class LocalWhisperProvider: TranscriptionProvider, @unchecked Sendable {
    public let name = "Whisper (local)"

    private let engine: any LocalSpeechEngine
    private let store: LocalModelStore
    private let model: WhisperModel

    /// Fires with each new segment's text as decoding produces it. Set by the
    /// app layer to show partial results while a dictation is still processing;
    /// the C callback already hops off the engine, this hop reaches the HUD.
    public var onPartialResult: (@Sendable (String) -> Void)?

    public init(model: WhisperModel,
                engine: any LocalSpeechEngine,
                store: LocalModelStore = LocalModelStore()) {
        self.model = model
        self.engine = engine
        self.store = store
    }

    /// The model's whisper language code for a pin, or nil for auto-detect.
    ///
    /// whisper's codes are ISO-639 base subtags, so a pinned regional variant
    /// maps to its base (`de-CH` → `de`, `zh-TW` → `zh`). `zh-HK` is the one
    /// real remap: Cantonese is `yue` in whisper, not `zh`. Modes (`auto`,
    /// `multi`) detect — whisper has no code-switching mode, and detection is
    /// the honest behaviour for both.
    public static func whisperLanguageCode(for pin: LanguagePin) -> String? {
        if pin.isAuto || pin.isMultilingual { return nil }
        let raw = pin.rawValue
        if raw == "zh-HK" { return "yue" }
        let base = raw.components(separatedBy: "-").first ?? raw
        return base.isEmpty ? nil : base.lowercased()
    }

    /// Dictionary bias as a whisper initial prompt.
    ///
    /// whisper takes free-text `initial_prompt` rather than Deepgram's repeated
    /// `keyterm` parameters, and uses at most 224 tokens of it — so the list is
    /// joined and capped well under that budget, keeping whole words.
    static func initialPrompt(from dictionaryWords: [String]) -> String? {
        let budget = 700
        var prompt = ""
        for word in dictionaryWords {
            let candidate = prompt.isEmpty ? word : prompt + " " + word
            if candidate.count > budget { break }
            prompt = candidate
        }
        return prompt.isEmpty ? nil : prompt
    }

    public func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        // Validate the file on every dictation: a model deleted (or replaced by
        // a still-downloading file) since the last call must fail here with a
        // clear message, not inside whisper_init as an opaque abort.
        let modelURL = store.fileURL(for: model)
        switch store.availability(of: model) {
        case .usable:
            break
        case .missing:
            throw ProviderError.notConfigured(
                "\(model.displayName) is not downloaded. Download it in Settings to use local transcription.")
        case .invalid(let reason):
            throw ProviderError.notConfigured(
                "\(model.displayName) failed validation (\(reason)). Download it again in Settings.")
        }

        let samples: [Float]
        do {
            samples = try WavReader.readFloatSamples(from: audio)
        } catch let error as WavReadError {
            throw ProviderError.engineFailed("could not read the recording (\(error))")
        } catch {
            throw ProviderError.engineFailed("could not read the recording")
        }

        // Load/reload only when the file on disk is not the loaded context —
        // the common case (same model, next dictation) costs nothing.
        if await engine.loadedModelURL != modelURL {
            do {
                try await engine.load(modelURL: modelURL)
            } catch let error as LocalEngineError {
                throw ProviderError.engineFailed(Self.describe(error))
            } catch {
                throw ProviderError.engineFailed("could not load the model")
            }
        }

        let options = LocalTranscriptionOptions(
            language: Self.whisperLanguageCode(for: hint.languagePin),
            initialPrompt: Self.initialPrompt(from: hint.dictionaryWords))
        do {
            let result = try await engine.transcribe(
                samples: samples, options: options, onSegment: onPartialResult)
            return Transcript(
                text: result.text,
                detectedLanguage: result.detectedLanguage,
                durationSeconds: result.durationSeconds)
        } catch let error as LocalEngineError {
            throw ProviderError.engineFailed(Self.describe(error))
        } catch {
            throw ProviderError.engineFailed("local transcription failed")
        }
    }

    private static func describe(_ error: LocalEngineError) -> String {
        switch error {
        case .modelLoadFailed(let detail): return "model load failed: \(detail)"
        case .notLoaded: return "no model is loaded"
        case .transcriptionFailed(let status): return "engine returned status \(status)"
        }
    }
}
