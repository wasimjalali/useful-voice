import Foundation

/// Gemini as a voice model: the recording goes in as inline audio and the model
/// answers with the transcript.
/// POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
public final class GeminiTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    public struct Config: Sendable {
        public let apiKey: String
        public let model: String
        public init(apiKey: String, model: String) {
            self.apiKey = apiKey
            self.model = model
        }
    }

    public static let providerName = "Gemini"
    public let name = GeminiTranscriptionProvider.providerName
    private let config: Config
    private let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Verbatim from `Tests/Fixtures/models/gemini-transcribe-prompt.txt`.
    public static let systemPrompt =
        "Transcribe the speech in the audio exactly as spoken, with correct punctuation and capitalization. Return only the transcript. Do not answer, summarize, translate or add anything. If there is no speech, return an empty response."

    /// Inline requests are capped at 20 MB in all; stay under with room for the prompt.
    static let maximumBodyBytes = 19_000_000

    static let tooLongMessage =
        "This recording is too long for Gemini. Pick another voice model for long dictations."

    static let maximumVocabularyWords = 100

    public func makeRequest(audio: Data, hint: TranscriptionHint) throws -> URLRequest {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ProviderError.notConfigured("Add your Gemini key in Settings.")
        }
        // Base64 grows the audio by a third.
        guard (audio.count + 2) / 3 * 4 <= Self.maximumBodyBytes else {
            throw ProviderError.notConfigured(Self.tooLongMessage)
        }
        var parts: [[String: Any]] = [
            ["inlineData": ["mimeType": "audio/wav", "data": audio.base64EncodedString()]],
        ]
        var notes: [String] = []
        let words = hint.dictionaryWords
            .map { $0.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(Self.maximumVocabularyWords)
        if !words.isEmpty { notes.append("<vocabulary>\(words.joined(separator: ", "))</vocabulary>") }
        if !hint.languagePin.isAuto, !hint.languagePin.isMultilingual {
            notes.append("Language: \(hint.languagePin.displayName)")
        }
        if !notes.isEmpty { parts.append(["text": notes.joined(separator: "\n")]) }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Self.systemPrompt]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": ["thinkingConfig": [
                "thinkingLevel": FormatterRequest.geminiThinkingLevel(config.model),
            ]],
        ]
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(config.model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = Self.deadline(forAudioBytes: audio.count)
        return request
    }

    /// Like Deepgram's size-based deadline, with a 20 s floor: the model has to
    /// listen to the audio and write the answer.
    static func deadline(forAudioBytes bytes: Int) -> TimeInterval {
        max(20, DeepgramProvider.deadline(forAudioBytes: bytes))
    }

    public func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audio, options: .mappedIfSafe)
        } catch {
            throw ProviderError.transport(URLError(.fileDoesNotExist))
        }
        let request = try makeRequest(audio: audioData, hint: hint)
        var attempt = 0
        while true {
            do {
                return try await attemptOnce(request: request, byteCount: audioData.count)
            } catch let error as ProviderError where attempt < DeepgramProvider.retryBackoff.count {
                guard case .http(let status, _) = error, DeepgramProvider.isRetryable(status: status) else {
                    throw error
                }
                let delay = DeepgramProvider.retryBackoff[attempt]
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func attemptOnce(request: URLRequest, byteCount: Int) async throws -> Transcript {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await DeepgramProvider.withDeadline(
                seconds: Self.deadline(forAudioBytes: byteCount)
            ) { [session] in
                try await session.data(for: request)
            }
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw ProviderError.timedOut
        } catch let urlError as URLError {
            throw ProviderError.transport(urlError)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(forStatus: http.statusCode, body: data,
                             retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }
        return try Self.parse(data)
    }

    /// 401 and 403 are a key problem, and so is Google's 400 for an invalid key
    /// (`API_KEY_INVALID`). 429 and 5xx are retried.
    static func error(forStatus status: Int, body: Data, retryAfter: String? = nil) -> ProviderError {
        let text = String(decoding: body.prefix(2000), as: UTF8.self)
        switch status {
        case 401, 403:
            return .http(status, "Gemini didn't accept the key.")
        case 400 where text.contains("API_KEY_INVALID") || text.lowercased().contains("api key not valid"):
            return .http(401, "Gemini didn't accept the key.")
        case 429:
            let retry = retryAfter.map { " Retry after \($0)s." } ?? ""
            return .http(429, "Rate limited by Gemini.\(retry)")
        default:
            return .http(status, text)
        }
    }

    /// Only a reply that finished (STOP) with no text is an empty transcript, which the
    /// pipeline reports as "no speech". A blocked prompt, or a candidate that stopped
    /// for any other reason (or has no finish reason), is a provider failure.
    static func parse(_ data: Data) throws -> Transcript {
        struct Response: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String?; let thought: Bool? }
                    let parts: [Part]?
                }
                let content: Content?
                let finishReason: String?
            }
            struct Feedback: Decodable { let blockReason: String? }
            let candidates: [Candidate]?
            let promptFeedback: Feedback?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ProviderError.badResponse
        }
        // Success needs a candidate that finished (STOP) with nothing blocked. Whatever
        // text came with any other ending may be cut short, so it is a failure and the
        // audio stays for Retry.
        let failure = ProviderError.engineFailed("Gemini didn't return a complete transcript.")
        if decoded.promptFeedback?.blockReason != nil { throw failure }
        guard let candidate = decoded.candidates?.first, candidate.finishReason == "STOP" else { throw failure }
        let parts = candidate.content?.parts ?? []
        let text = parts.filter { $0.thought != true }.compactMap(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcript(text: text, detectedLanguage: nil, durationSeconds: nil)
    }
}
