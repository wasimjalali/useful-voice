import Foundation

/// Which transcription engine family a voice model belongs to. Kept for the code that
/// only needs to tell on-device Whisper apart, and for the old saved setting.
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
