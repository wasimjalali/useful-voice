import Foundation

/// Deepgram Nova-3 pre-recorded transcription.
/// POST https://api.deepgram.com/v1/listen with the raw WAV bytes as the body.
/// @unchecked Sendable: no mutable state; both stored properties are Sendable.
public final class DeepgramProvider: TranscriptionProvider, @unchecked Sendable {
    public struct Config: Sendable {
        public let apiKey: String
        public let model: String
        public let smartFormat: Bool

        public init(apiKey: String, model: String = "nova-3", smartFormat: Bool) {
            self.apiKey = apiKey
            self.model = model
            self.smartFormat = smartFormat
        }
    }

    public let name = "Deepgram"
    private let config: Config
    private let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    static let baseURL = URL(string: "https://api.deepgram.com/v1/listen")!

    /// Wall-clock deadline for one attempt (matches the old provider chain).
    static let totalDeadline: TimeInterval = 15

    /// Nova-3 language codes. Auto-detect maps to `multi` (multilingual
    /// code-switching, a Nova-3 feature).
    static func languageParameter(for pin: LanguagePin) -> String {
        switch pin {
        case .en: return "en"
        case .de: return "de"
        case .auto: return "multi"
        }
    }

    public func makeRequest(audio: Data, hint: TranscriptionHint) throws -> URLRequest {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ProviderError.notConfigured("Enter your Deepgram API key.")
        }
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "model", value: config.model),
            URLQueryItem(name: "language", value: Self.languageParameter(for: hint.languagePin)),
        ]
        if config.smartFormat {
            items.append(URLQueryItem(name: "smart_format", value: "true"))
        }
        // Nova-3 keyterm prompting biases recognition toward the user's
        // vocabulary. Repeated once per term.
        for term in hint.dictionaryWords {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio
        request.timeoutInterval = Self.totalDeadline
        return request
    }

    /// Races work against a true wall-clock deadline. URLRequest.timeoutInterval
    /// is only an idle timeout (it resets on every byte), so a slow trickling
    /// upload could exceed it indefinitely; this enforces a real total cap.
    static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ProviderError.timedOut
            }
            guard let result = try await group.next() else {
                throw ProviderError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    public func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        let request = try makeRequest(audio: Data(contentsOf: audio), hint: hint)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.withDeadline(seconds: Self.totalDeadline) { [session] in
                try await session.data(for: request)
            }
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw ProviderError.timedOut
        } catch let urlError as URLError {
            throw ProviderError.transport(urlError)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> Transcript {
        struct Response: Decodable {
            struct Metadata: Decodable { let duration: Double? }
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alternative: Decodable { let transcript: String }
                    let alternatives: [Alternative]
                }
                let channels: [Channel]
            }
            let metadata: Metadata?
            let results: Results
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let transcript = decoded.results.channels.first?.alternatives.first?.transcript else {
            throw ProviderError.badResponse
        }
        return Transcript(
            text: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: nil,
            durationSeconds: decoded.metadata?.duration)
    }
}
