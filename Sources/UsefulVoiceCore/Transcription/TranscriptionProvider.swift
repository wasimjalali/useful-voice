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
    case badResponse
    case notConfigured(String)
    case timedOut
    case transport(URLError)
}

public protocol TranscriptionProvider: Sendable {
    var name: String { get }
    func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript
}
