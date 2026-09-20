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

    /// The detected code safe to store in history or log: trimmed, stripped to
    /// BCP-47 tag characters (ASCII letters and hyphen), capped at 35
    /// characters, and `nil` when nothing usable remains.
    ///
    /// A malformed `detected_language` must not forge a history row or a log
    /// line — a newline or escape sequence in the raw value could inject a
    /// fake record or diagnostic entry — so this deliberately strips
    /// everything outside the tag alphabet rather than preserving the exact
    /// bytes. The same rule is applied everywhere the value is persisted,
    /// matching the Windows port's sanitizer.
    public var sanitizedDetectedLanguage: String? {
        detectedLanguage.flatMap { raw in
            let tagCharacters = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .unicodeScalars
                .filter { scalar in
                    scalar.value == 45                        // '-'
                        || (65...90).contains(scalar.value)   // A-Z
                        || (97...122).contains(scalar.value)  // a-z
                }
                .prefix(35)
            let sanitized = String(String.UnicodeScalarView(tagCharacters))
            return sanitized.isEmpty ? nil : sanitized
        }
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
