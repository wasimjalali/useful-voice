import Foundation

/// What the saved voice model id resolves to, free of provider instances so the decision is testable without networks or models.
public enum VoicePlan: Equatable, Sendable {
    /// Deepgram with this API model (`nova-3`, `nova-3-medical`).
    case deepgram(apiModel: String)
    case elevenLabs(apiModel: String)
    /// Gemini listening to the recording (audio in, transcript out).
    case gemini(apiModel: String)
    case whisper(WhisperModel)
    case parakeet(ParakeetVersion)
    /// A cloud model whose key isn't saved.
    case needsKey(KeyProvider)
    case needsWhisperDownload(WhisperModel)
    case whisperInvalid(WhisperModel, reason: String)
}

public enum VoiceModelSelector {
    /// The rule that matters: no silent fallback between providers. A missing key or model is an actionable error, never a quiet
    /// request to a different provider.
    public static func resolve(
        voiceModelID: String,
        keyAvailable: (KeyProvider) -> Bool,
        whisperAvailability: (WhisperModel) -> LocalModelAvailability
    ) -> VoicePlan {
        let entry = ModelCatalog.voiceModel(id: voiceModelID) ?? ModelCatalog.voice[0]
        if let whisper = ModelCatalog.whisperModel(forVoiceID: entry.id) {
            switch whisperAvailability(whisper) {
            case .usable: return .whisper(whisper)
            case .missing: return .needsWhisperDownload(whisper)
            case .invalid(let reason): return .whisperInvalid(whisper, reason: reason)
            }
        }
        if let version = ParakeetVersion(catalogID: entry.id) {
            return .parakeet(version)
        }
        guard let key = entry.keyProvider else {
            return .deepgram(apiModel: "nova-3")
        }
        guard keyAvailable(key) else { return .needsKey(key) }
        switch key {
        case .elevenLabs: return .elevenLabs(apiModel: entry.apiModel)
        case .gemini: return .gemini(apiModel: entry.apiModel)
        default: return .deepgram(apiModel: entry.apiModel)
        }
    }

    public static func keyMessage(for provider: KeyProvider) -> String {
        "Add your \(provider.displayName) key in Settings."
    }

    public static func unavailableMessage(for plan: VoicePlan) -> String? {
        switch plan {
        case .deepgram, .elevenLabs, .gemini, .whisper, .parakeet:
            return nil
        case .needsKey(let provider):
            return keyMessage(for: provider)
        case .needsWhisperDownload(let model):
            return "\(model.displayName) is not downloaded. Download it in Settings to use local transcription."
        case .whisperInvalid(let model, let reason):
            return "\(model.displayName) failed validation (\(reason)). Download it again in Settings."
        }
    }
}

/// Refuses a language Parakeet can't transcribe before any audio is processed, using
/// the one rule in `ParakeetVersion.languageProblem`.
public struct ParakeetLanguageGuard: TranscriptionProvider {
    public let version: ParakeetVersion
    private let inner: TranscriptionProvider

    public var name: String { inner.name }
    public var modelName: String? { inner.modelName }

    public init(version: ParakeetVersion, inner: TranscriptionProvider) {
        self.version = version
        self.inner = inner
    }

    public func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        if let message = version.languageProblem(for: hint.languagePin) {
            throw ProviderError.notConfigured(message)
        }
        return try await inner.transcribe(audio: audio, hint: hint)
    }
}
