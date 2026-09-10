import Foundation

public struct TranscriptionHint: Sendable {
    public let languagePin: LanguagePin
    public let dictionaryWords: [String]

    public init(languagePin: LanguagePin, dictionaryWords: [String]) {
        self.languagePin = languagePin
        self.dictionaryWords = dictionaryWords
    }
}

public struct Transcript: Equatable, Sendable {
    public let text: String
    public let detectedLanguage: String?
    public let durationSeconds: Double?

    public init(text: String, detectedLanguage: String?, durationSeconds: Double?) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.durationSeconds = durationSeconds
    }
}

public enum ProviderError: Error {
    case http(Int, String)
    /// The Deepgram project is out of credits (HTTP 402).
    ///
    /// Separate from `http` because it is the one failure the user can fix in a
    /// minute and the docs give it its own error code, `ASR_PAYMENT_REQUIRED`:
    /// "Project does not have enough credits for an ASR request and does not have
    /// an overage agreement." Reporting it as a generic 400 sends the user
    /// hunting for a problem with their audio instead of topping up.
    case outOfCredits(String)
    case badResponse
    case notConfigured(String)
    case timedOut
    case transport(URLError)
}

public protocol TranscriptionProvider: Sendable {
    var name: String { get }
    func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript
}
