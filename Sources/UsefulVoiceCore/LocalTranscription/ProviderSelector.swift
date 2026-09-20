import Foundation

/// Which transcription engine the user picked in Settings.
public enum TranscriptionEngineChoice: String, CaseIterable, Sendable {
    case deepgram
    case whisperLocal

    public var displayName: String {
        switch self {
        case .deepgram: return "Deepgram (cloud)"
        case .whisperLocal: return "Whisper (local)"
        }
    }
}

/// What the provider-selection logic decided, in terms the app layer maps to a
/// real provider or an actionable error. Kept free of provider instances so the
/// whole decision is unit-testable without networks or models.
public enum ProviderPlan: Equatable, Sendable {
    /// Deepgram is the engine and a key is present — build `DeepgramProvider`.
    case deepgram
    /// Local is the engine and the model file validates — build
    /// `LocalWhisperProvider` for the contained model.
    case local(WhisperModel)
    /// Deepgram selected but no key: the existing key flow applies.
    case needsDeepgramKey
    /// Local selected but the model is not downloaded yet.
    case needsModelDownload(WhisperModel)
    /// Local selected and the model file is on disk but failed validation.
    case modelInvalid(WhisperModel, reason: String)
}

/// Decides which transcription path a dictation takes.
///
/// The one rule that matters: **local never silently falls back to cloud**.
/// A user who chose "Whisper (local)" chose that no audio leaves the Mac, so a
/// missing or broken model produces an actionable error — never a quiet
/// Deepgram request billed to their key.
public enum ProviderSelector {
    public static func resolve(
        engine: TranscriptionEngineChoice,
        deepgramKeyAvailable: Bool,
        localModel: WhisperModel,
        localModelAvailability: LocalModelAvailability
    ) -> ProviderPlan {
        switch engine {
        case .deepgram:
            return deepgramKeyAvailable ? .deepgram : .needsDeepgramKey
        case .whisperLocal:
            switch localModelAvailability {
            case .usable:
                return .local(localModel)
            case .missing:
                return .needsModelDownload(localModel)
            case .invalid(let reason):
                return .modelInvalid(localModel, reason: reason)
            }
        }
    }

    /// The error a dictation should surface when the plan is not usable.
    /// Maps `needsX`/`modelInvalid` to the message an `UnavailableProvider`
    /// throws so the failure is specific rather than "no provider configured".
    public static func unavailableMessage(for plan: ProviderPlan) -> String? {
        switch plan {
        case .deepgram, .local:
            return nil
        case .needsDeepgramKey:
            return "Enter your Deepgram API key in Settings."
        case .needsModelDownload(let model):
            return "\(model.displayName) is not downloaded. Download it in Settings to use local transcription."
        case .modelInvalid(let model, let reason):
            return "\(model.displayName) failed validation (\(reason)). Download it again in Settings."
        }
    }
}

/// A provider that always fails with a specific, actionable message.
///
/// Used when selection resolved to a `needsX` state: the dictation pipeline
/// expects a provider list, and an entry that throws `notConfigured` produces
/// the right user-facing error through the normal failure path — no special
/// casing in `DictationController`.
public struct UnavailableProvider: TranscriptionProvider {
    public let name: String
    private let message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }

    public func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        throw ProviderError.notConfigured(message)
    }
}
