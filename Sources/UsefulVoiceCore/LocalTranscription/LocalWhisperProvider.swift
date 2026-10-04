import Foundation

/// `TranscriptionProvider` backed by a local engine (whisper.cpp today, MLX
/// later behind the same `LocalSpeechEngine` seam).
///
/// Everything runs on-device: no API key, no network, no audio leaving the Mac.
/// The provider validates the model file before every dictation — a deleted or
/// half-overwritten model fails with an actionable error rather than an engine
/// crash. The engine loads (or swaps) the context inside the same call that
/// decodes, so switching models mid-session is clean.
public final class LocalWhisperProvider: TranscriptionProvider, @unchecked Sendable {
    public static let providerName = "Whisper (local)"
    public let name = LocalWhisperProvider.providerName

    /// The model this provider transcribes with, so the app layer can tell
    /// when a settings change requires a different provider.
    public let model: WhisperModel
    private let engine: any LocalSpeechEngine
    private let store: LocalModelStore

    /// Fires with each new segment's text as decoding produces it. Fixed at
    /// init so partials can never leak into another call: the app builds one
    /// provider per dictation and passes a handler only for the live dictation
    /// (reprocess and the health probe pass nil).
    private let onPartialResult: (@Sendable (String) -> Void)?

    public init(model: WhisperModel,
                engine: any LocalSpeechEngine,
                store: LocalModelStore = LocalModelStore(),
                onPartialResult: (@Sendable (String) -> Void)? = nil) {
        self.model = model
        self.engine = engine
        self.store = store
        self.onPartialResult = onPartialResult
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
    /// `keyterm` parameters, and keeps only the LAST 224 tokens of it. So the
    /// words are chosen in priority order (the list's order) until the budget
    /// is spent, then emitted in reverse: the highest-priority words end up
    /// last, where truncation cannot reach them. Budget units are a rough
    /// proxy for tokens: ASCII costs 1, Latin letters above U+007F (accents)
    /// cost 2, CJK and Indic scalars cost 5, other non-Latin scripts cost 3.
    /// The estimate is conservative, not exact. When the list overflows the
    /// budget, the lowest-priority words are dropped, so they are not sent.
    static func initialPrompt(from dictionaryWords: [String]) -> String? {
        let budget = 700
        let separator = ", "
        func cost(_ word: String) -> Int {
            word.unicodeScalars.reduce(0) { total, scalar in
                let v = scalar.value
                switch v {
                case 0...0x7F: return total + 1
                case 0x80...0x24F: return total + 2
                case 0x0900...0x0DFF,          // Indic scripts
                     0x2E80...0x9FFF,          // CJK radicals, kana, ideographs
                     0xAC00...0xD7AF,          // Hangul
                     0xF900...0xFAFF,          // CJK compatibility ideographs
                     0x20000...0x2FA1F:        // CJK extensions
                    return total + 5
                default: return total + 3
                }
            }
        }
        var chosen: [String] = []
        var spent = 0
        for word in dictionaryWords {
            let next = spent + cost(word) + (chosen.isEmpty ? 0 : separator.count)
            if next > budget { break }
            chosen.append(word)
            spent = next
        }
        return chosen.isEmpty ? nil : chosen.reversed().joined(separator: separator) + "."
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

        let options = LocalTranscriptionOptions(
            language: Self.whisperLanguageCode(for: hint.languagePin),
            initialPrompt: Self.initialPrompt(from: hint.dictionaryWords))
        do {
            let result = try await engine.transcribe(
                modelURL: modelURL, samples: samples, options: options,
                onSegment: onPartialResult)
            return Transcript(
                text: result.text,
                detectedLanguage: result.detectedLanguage,
                durationSeconds: result.durationSeconds)
        } catch let error as LocalEngineError {
            throw ProviderError.engineFailed(describe(error))
        } catch {
            throw ProviderError.engineFailed("local transcription failed")
        }
    }

    private func describe(_ error: LocalEngineError) -> String {
        switch error {
        case .modelLoadFailed:
            let base = "\(model.displayName) could not be loaded. Delete and download it again in Settings"
            return model.id == WhisperModelCatalog.largeV3Turbo.id
                ? base + "."
                : base + ", or use Turbo on 8 GB Macs."
        case .transcriptionFailed(let status):
            return "Local transcription failed (code \(status)). Try again."
        }
    }
}
