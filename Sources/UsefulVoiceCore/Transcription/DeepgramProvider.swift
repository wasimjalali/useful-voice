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

    /// Deadline floor for one attempt.
    static let minimumDeadline: TimeInterval = 15

    /// Absolute ceiling for one attempt, so a wedged request can never hang the
    /// pipeline forever.
    static let maximumDeadline: TimeInterval = 180

    /// Worst-case upload throughput assumed when sizing the deadline, in bytes
    /// per second (~0.8 Mbit/s). Deliberately pessimistic: dictation happens on
    /// tethered connections and hotel wifi, and the cost of being generous is
    /// only that a genuinely dead network takes longer to report.
    static let assumedUploadBytesPerSecond: Double = 100_000

    /// Fixed allowance for TLS setup, the server's own processing of Nova-3 on
    /// pre-recorded audio, and the response download.
    static let processingAllowance: TimeInterval = 12

    /// Wall-clock deadline for one attempt, sized to the audio being uploaded.
    ///
    /// A fixed 15 s cap covered upload *and* server processing, so a long
    /// dictation could never succeed: 16 kHz mono WAV is ~32 kB/s, which is
    /// ~9.6 MB for a five-minute recording — over 15 s of upload alone on a
    /// 5 Mbit/s link, before Deepgram has even looked at the audio. The app
    /// advertises recordings up to ten minutes, so the deadline has to scale.
    static func deadline(forAudioBytes bytes: Int) -> TimeInterval {
        let upload = Double(max(0, bytes)) / assumedUploadBytesPerSecond
        let total = upload + processingAllowance
        return min(maximumDeadline, max(minimumDeadline, total))
    }

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
        // vocabulary. Repeated once per term. The caller bounds this list: the
        // API rejects the whole request when the terms exceed its token limit,
        // and every term is URL-encoded into the request line.
        for term in hint.dictionaryWords where KeytermBudget.isSendableKeyterm(term) {
            items.append(URLQueryItem(name: "keyterm", value: term))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio
        // Idle timeout only (it resets per byte); the real cap is the wall-clock
        // deadline below.
        request.timeoutInterval = Self.deadline(forAudioBytes: audio.count)
        return request
    }

    /// Races work against a true wall-clock deadline. URLRequest.timeoutInterval
    /// is only an idle timeout (it resets on every byte), so a slow trickling
    /// upload could exceed it indefinitely; this enforces a real total cap.
    ///
    /// Cancellation matters here: `group.cancelAll()` alone would leave the
    /// losing URLSession task running, so a timed-out request would keep
    /// uploading and billing. The work closure is wrapped on a task that is
    /// cancelled explicitly and awaited, which cancels the session task.
    static func withDeadline<T: Sendable>(
        seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let workTask = Task<T, Error> { try await work() }
        let timeoutTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            workTask.cancel()
        }
        defer { timeoutTask.cancel() }

        do {
            return try await workTask.value
        } catch is CancellationError {
            throw ProviderError.timedOut
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw ProviderError.timedOut
        }
    }

    public func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        // Read the bytes off the caller's actor: this is file I/O and would
        // otherwise block the main thread inside the dictation pipeline.
        let audioData: Data
        do {
            audioData = try Data(contentsOf: audio, options: .mappedIfSafe)
        } catch {
            throw ProviderError.transport(URLError(.fileDoesNotExist))
        }
        let request = try makeRequest(audio: audioData, hint: hint)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.withDeadline(
                seconds: Self.deadline(forAudioBytes: audioData.count)
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
            // Surface a rate-limit hint rather than a bare 429.
            if http.statusCode == 429 {
                let retry = http.value(forHTTPHeaderField: "Retry-After")
                    .map { " Retry after \($0)s." } ?? ""
                throw ProviderError.http(429, "Rate limited by Deepgram.\(retry)")
            }
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
