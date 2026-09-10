import Foundation

/// Deepgram Nova-3 pre-recorded transcription.
/// POST https://api.deepgram.com/v1/listen with the raw WAV bytes as the body.
/// @unchecked Sendable: no mutable state; both stored properties are Sendable.
public final class DeepgramProvider: TranscriptionProvider, @unchecked Sendable {
    public struct Config: Sendable {
        public let apiKey: String
        public let model: String
        public let smartFormat: Bool
        /// Convert spoken punctuation commands ("period", "new line") into the
        /// characters themselves, via Deepgram's Dictation feature.
        ///
        /// Off by default and never implied by `smartFormat`: it is a behaviour
        /// change, not a formatting improvement. Saying "period" stops producing
        /// the word "period", which is what a dictating user usually wants but is
        /// surprising if they did not ask for it.
        public let spokenPunctuation: Bool

        public init(
            apiKey: String,
            model: String = "nova-3",
            smartFormat: Bool,
            spokenPunctuation: Bool = false
        ) {
            self.apiKey = apiKey
            self.model = model
            self.smartFormat = smartFormat
            self.spokenPunctuation = spokenPunctuation
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
    ///
    /// Must stay above the largest deadline `deadline(forAudioBytes:)` can
    /// produce, or the ceiling silently cancels the long dictations the formula
    /// exists to protect. A ten-minute recording is 19.2 MB; at the pessimistic
    /// `assumedUploadBytesPerSecond` that is 192 s of upload, plus the 12 s
    /// processing allowance = 204 s. This was 180, so the advertised ten-minute
    /// dictation was guaranteed to fail on exactly the slow connections the
    /// pessimistic figure was chosen for.
    static let maximumDeadline: TimeInterval = 210

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

    /// The languages this app offers, used to restrict auto-detection.
    ///
    /// Both are natively supported by Nova-3, which matters: the docs say an
    /// unsupported detected language makes Deepgram "automatically select the
    /// next highest model", and that fallback would drop Nova-3 — the only model
    /// that supports `keyterm`, which is the whole dictionary feature. Restricting
    /// detection to these two makes that fallback unreachable.
    static let autoDetectLanguages = ["en", "de"]

    /// The `language` value for a pinned language. Auto has no value here: it is
    /// expressed with `detect_language` instead. See `appendLanguageParameters`.
    static func languageParameter(for pin: LanguagePin) -> String? {
        switch pin {
        case .en: return "en"
        case .de: return "de"
        case .auto: return nil
        }
    }

    /// Append the language parameters for a pin.
    ///
    /// Auto used to send `language=multi`, on the belief that `multi` was the
    /// auto-detect mode. It is not: `multi` is Multilingual Code-Switching, for
    /// audio where speakers switch between languages mid-conversation, and it
    /// tells Deepgram to expect that. A user dictating in one language with the
    /// pin on auto was therefore being transcribed in the wrong mode, which is the
    /// most likely cause of the punctuation and capitalisation looking off.
    ///
    /// Detection is the documented mechanism for auto, and it can be restricted to
    /// a set of languages, so it does not have to guess across all of them.
    /// https://developers.deepgram.com/docs/language-detection
    static func appendLanguageParameters(to items: inout [URLQueryItem], pin: LanguagePin) {
        if let pinned = languageParameter(for: pin) {
            items.append(URLQueryItem(name: "language", value: pinned))
            return
        }
        for language in autoDetectLanguages {
            items.append(URLQueryItem(name: "detect_language", value: language))
        }
    }

    /// Whether the Dictation feature applies to this pin.
    ///
    /// Deepgram documents spoken punctuation as "English (all available regions)"
    /// only, so it is suppressed for German rather than sent and ignored.
    /// https://developers.deepgram.com/docs/dictation
    static func supportsSpokenPunctuation(_ pin: LanguagePin) -> Bool {
        pin != .de
    }

    public func makeRequest(audio: Data, hint: TranscriptionHint) throws -> URLRequest {
        let apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ProviderError.notConfigured("Enter your Deepgram API key.")
        }
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "model", value: config.model)]
        Self.appendLanguageParameters(to: &items, pin: hint.languagePin)
        if config.smartFormat {
            items.append(URLQueryItem(name: "smart_format", value: "true"))
            // Smart Format only *guarantees* punctuation and paragraphs. Numerals
            // are documented as available "for select languages" on non-English
            // models, and German is one of them, so asking explicitly removes a
            // language-dependent ambiguity rather than relying on the default.
            items.append(URLQueryItem(name: "numerals", value: "true"))
        }
        if config.spokenPunctuation, Self.supportsSpokenPunctuation(hint.languagePin) {
            // The docs are explicit that punctuation must also be enabled:
            // "Be sure to add `dictation=true&punctuate=true`". Without
            // smart_format there is nothing else turning punctuation on, so
            // `punctuate` is sent here rather than unconditionally.
            items.append(URLQueryItem(name: "dictation", value: "true"))
            items.append(URLQueryItem(name: "punctuate", value: "true"))
        }
        // Usage attribution, so requests from this app are identifiable in
        // Deepgram's usage reporting. Optional, and bounded to 128 characters.
        items.append(URLQueryItem(name: "tag", value: "useful-voice"))
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

        // Bounded retry for the failures that are worth retrying. Three attempts
        // total, so a genuinely down service still fails fast enough to be
        // reported rather than leaving the user waiting on a hotkey that did
        // nothing.
        var attempt = 0
        while true {
            do {
                return try await attemptOnce(request: request, byteCount: audioData.count)
            } catch let error as ProviderError where attempt < Self.retryBackoff.count {
                guard case .http(let status, _) = error, Self.isRetryable(status: status) else {
                    throw error
                }
                let delay = Self.retryBackoff[attempt]
                attempt += 1
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// One attempt: send the request, classify the response.
    private func attemptOnce(request: URLRequest, byteCount: Int) async throws -> Transcript {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.withDeadline(
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
            let requestID = Self.requestID(fromBody: data)
            let suffix = requestID.map { " (reference \($0))" } ?? ""
            switch http.statusCode {
            case 402:
                throw ProviderError.outOfCredits(
                    "Your Deepgram account is out of credits.\(suffix)")
            case 429:
                // Retry-After is not documented for this API, so it is used when
                // present and the backoff above covers the case where it is not.
                let retry = http.value(forHTTPHeaderField: "Retry-After")
                    .map { " Retry after \($0)s." } ?? ""
                throw ProviderError.http(429, "Rate limited by Deepgram.\(retry)\(suffix)")
            default:
                let body = String(decoding: data, as: UTF8.self)
                throw ProviderError.http(http.statusCode, body + suffix)
            }
        }
        return try Self.parse(data)
    }

    /// The parts of a Deepgram response this app reads.
    struct Response: Decodable {
        struct Metadata: Decodable {
            let duration: Double?
            let request_id: String?
        }
        struct Results: Decodable {
            struct Channel: Decodable {
                struct Alternative: Decodable { let transcript: String }
                let alternatives: [Alternative]
                /// Present only when `detect_language` was sent. This field was
                /// previously hardcoded to `nil`, while the request never asked
                /// for detection, so the plumbing that stores and displays a
                /// detected language was unreachable on every code path.
                let detected_language: String?
            }
            let channels: [Channel]
        }
        let metadata: Metadata?
        let results: Results
    }

    static func parse(_ data: Data) throws -> Transcript {
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let channel = decoded.results.channels.first,
              let transcript = channel.alternatives.first?.transcript else {
            throw ProviderError.badResponse
        }
        return Transcript(
            text: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            detectedLanguage: channel.detected_language,
            durationSeconds: decoded.metadata?.duration)
    }

    /// The `request_id` from a failed response, when Deepgram supplied one.
    ///
    /// Worth extracting because it is the one thing support asks for: "contact
    /// support with the request ID and details about how the audio was uploaded."
    /// It is parsed leniently — a body that is not JSON, or has no request id,
    /// simply yields nothing rather than masking the real error.
    static func requestID(fromBody data: Data) -> String? {
        struct ErrorBody: Decodable { let request_id: String? }
        struct Envelope: Decodable { let metadata: Metadata?
                                     struct Metadata: Decodable { let request_id: String? } }
        if let error = try? JSONDecoder().decode(ErrorBody.self, from: data),
           let id = error.request_id, !id.isEmpty {
            return id
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           let id = envelope.metadata?.request_id, !id.isEmpty {
            return id
        }
        return nil
    }

    /// Startup backoff for a retried attempt. Doubles per attempt, so three
    /// attempts wait 0.5 s then 1.5 s.
    static let retryBackoff: [TimeInterval] = [0.5, 1.5]

    /// Whether a status is worth retrying.
    ///
    /// Deepgram's own guidance for 429 is "an exponential-backoff retry strategy
    /// is recommended", and 5xx is documented as "may succeed if retried". This
    /// app had no retry at all, so a single transient 429 during a dictation
    /// surfaced as a hard failure the user had to repeat by hand.
    static func isRetryable(status: Int) -> Bool {
        status == 429 || status == 408 || (500..<600).contains(status)
    }
}
