import Foundation

/// ElevenLabs Scribe v2 pre-recorded transcription.
/// POST https://api.elevenlabs.io/v1/speech-to-text, multipart, the WAV as `file`.
/// @unchecked Sendable: no mutable state; both stored properties are Sendable.
public final class ElevenLabsProvider: TranscriptionProvider, @unchecked Sendable {
    public struct Config: Sendable {
        public let apiKey: String
        public let model: String

        public init(apiKey: String, model: String = "scribe_v2") {
            self.apiKey = apiKey
            self.model = model
        }
    }

    public static let providerName = "ElevenLabs"
    public let name = ElevenLabsProvider.providerName
    private let config: Config
    private let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    /// The API takes up to 1000 keyterms; dictation sends at most 50, each under
    /// 50 characters and at most 5 words (the documented per-term limits).
    static let maximumKeyterms = 50

    static func isSendableKeyterm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 50 else { return false }
        guard trimmed.split(whereSeparator: { $0.isWhitespace }).count <= 5 else { return false }
        return trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "<>{}[]\\")) == nil
    }

    /// The multipart request for one recording.
    public func makeRequest(audio: Data, hint: TranscriptionHint) throws -> URLRequest {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ProviderError.notConfigured("Add your ElevenLabs key in Settings.")
        }
        let boundary = "uv-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", config.model)
        if !hint.languagePin.isAuto, !hint.languagePin.isMultilingual {
            // Regional pins (de-CH, pt-BR) go as their base language: the API takes ISO codes.
            field("language_code", String(hint.languagePin.rawValue.split(separator: "-").first ?? ""))
        }
        field("tag_audio_events", "false")
        var sent = 0
        for term in hint.dictionaryWords where Self.isSendableKeyterm(term) {
            guard sent < Self.maximumKeyterms else { break }
            field("keyterms", term.trimmingCharacters(in: .whitespacesAndNewlines))
            sent += 1
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = DeepgramProvider.deadline(forAudioBytes: audio.count)
        return request
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
                return try await attemptOnce(request: request, byteCount: audioData.count,
                                             pin: hint.languagePin)
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

    private func attemptOnce(request: URLRequest, byteCount: Int, pin: LanguagePin) async throws -> Transcript {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await DeepgramProvider.withDeadline(
                seconds: DeepgramProvider.deadline(forAudioBytes: byteCount)
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
        return try Self.parse(data, pin: pin)
    }

    /// 401 and 403 are a key problem, 429 is rate limiting (retried), 5xx is retried.
    static func error(forStatus status: Int, body: Data, retryAfter: String? = nil) -> ProviderError {
        switch status {
        case 401, 403:
            // A 401 that says the quota is used up is about credits, not the key.
            if String(decoding: body.prefix(2000), as: UTF8.self).contains("quota_exceeded") {
                return .outOfCredits("Your ElevenLabs account is out of credits.")
            }
            return .http(status, "ElevenLabs didn't accept the key.")
        case 429:
            let retry = retryAfter.map { " Retry after \($0)s." } ?? ""
            return .http(429, "Rate limited by ElevenLabs.\(retry)")
        default:
            return .http(status, String(decoding: body, as: UTF8.self))
        }
    }

    struct Response: Decodable {
        let text: String?
        let language_code: String?
        let audio_duration_secs: Double?
    }

    /// ElevenLabs reports ISO 639-3 codes ("eng"). The ones the app has rules for
    /// map to the two-letter codes the rest of the app uses.
    static let iso3to1: [String: String] = [
        "eng": "en", "deu": "de", "fra": "fr", "spa": "es", "ita": "it", "por": "pt",
        "nld": "nl", "pol": "pl", "rus": "ru", "jpn": "ja", "zho": "zh", "kor": "ko",
        "ara": "ar", "hin": "hi", "tur": "tr", "swe": "sv", "ukr": "uk", "dan": "da",
        "nor": "no", "fin": "fi", "ces": "cs", "ell": "el", "hun": "hu", "ron": "ro",
        "ind": "id", "vie": "vi", "tha": "th",
    ]

    /// The detected language is reported only for Auto; a pinned language keeps
    /// governing the rest of the pipeline.
    static func parse(_ data: Data, pin: LanguagePin) throws -> Transcript {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let text = decoded.text else {
            throw ProviderError.badResponse
        }
        var detected: String?
        if pin.isAuto, let code = decoded.language_code?.lowercased(), !code.isEmpty {
            detected = iso3to1[code] ?? code
        }
        return Transcript(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          detectedLanguage: detected,
                          durationSeconds: decoded.audio_duration_secs)
    }
}
