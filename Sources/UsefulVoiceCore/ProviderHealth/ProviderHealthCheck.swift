import Foundation

public struct ProviderHealthResult: Equatable, Sendable {
    public let providerName: String
    public let ok: Bool
    public let latencyMilliseconds: Int?
    public let message: String
    public let redactedEndpoint: String
    /// Why a failed check failed, so a caller can tell a refused key from a
    /// network problem. `nil` when the check passed.
    public let failure: Failure?

    public enum Failure: Equatable, Sendable {
        /// The provider answered 401 or 403: the key was refused.
        case rejected
        /// The request never got an answer (offline, DNS, TLS, timeout).
        case network
        /// Anything else: an HTTP error, no credits, an unreadable response.
        case other
    }

    public init(providerName: String,
                ok: Bool,
                latencyMilliseconds: Int?,
                message: String,
                redactedEndpoint: String,
                failure: Failure? = nil) {
        self.providerName = providerName
        self.ok = ok
        self.latencyMilliseconds = latencyMilliseconds
        self.message = message
        self.redactedEndpoint = redactedEndpoint
        self.failure = failure
    }
}

public enum ProviderHealthCheck {
    public static func check(provider: TranscriptionProvider,
                             endpoint: String,
                             hint: TranscriptionHint,
                             now: @escaping () -> Date = { Date() }) async -> ProviderHealthResult {
        let startedAt = now()
        let audioURL: URL
        do {
            audioURL = try makeProbeWAV()
        } catch {
            return result(
                providerName: provider.name,
                endpoint: endpoint,
                ok: false,
                startedAt: startedAt,
                finishedAt: now(),
                message: "Could not create probe audio: \(error.localizedDescription)"
            )
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            let transcript = try await provider.transcribe(audio: audioURL, hint: hint)
            let sample = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = sample.isEmpty ? "connected; empty probe transcript"
                                    : "connected; \"\(sample.prefix(80))\""
            return result(
                providerName: provider.name,
                endpoint: endpoint,
                ok: true,
                startedAt: startedAt,
                finishedAt: now(),
                message: detail
            )
        } catch {
            return result(
                providerName: provider.name,
                endpoint: endpoint,
                ok: false,
                startedAt: startedAt,
                finishedAt: now(),
                message: describe(error),
                failure: classify(error)
            )
        }
    }

    public static func redactedEndpoint(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host else {
            return raw.isEmpty ? "" : "<invalid endpoint>"
        }
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = host
        components.port = url.port
        return components.string ?? "https://\(host)"
    }

    public static func result(providerName: String,
                              endpoint: String,
                              ok: Bool,
                              startedAt: Date,
                              finishedAt: Date,
                              message: String,
                              failure: ProviderHealthResult.Failure? = nil) -> ProviderHealthResult {
        ProviderHealthResult(
            providerName: providerName,
            ok: ok,
            latencyMilliseconds: Int(finishedAt.timeIntervalSince(startedAt) * 1000),
            message: sanitize(message),
            redactedEndpoint: redactedEndpoint(endpoint),
            failure: ok ? nil : (failure ?? .other)
        )
    }

    /// Sorts a provider error into what the user can act on.
    static func classify(_ error: Error) -> ProviderHealthResult.Failure {
        guard let provider = error as? ProviderError else { return .other }
        switch provider {
        case .http(let status, _) where status == 401 || status == 403:
            return .rejected
        case .timedOut, .transport:
            return .network
        default:
            return .other
        }
    }

    public static func sanitize(_ message: String) -> String {
        var sanitized = message
        let keyPatterns = [
            #"api-key["']?\s*[:=]\s*["']?[^"',\s]+"#,
            #"Ocp-Apim-Subscription-Key["']?\s*[:=]\s*["']?[^"',\s]+"#,
            #"Bearer\s+[A-Za-z0-9._\-]+"#,
            // Deepgram uses "Authorization: Token <key>".
            #"Token\s+[A-Za-z0-9._\-]+"#,
        ]
        for pattern in keyPatterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return String(sanitized.prefix(240))
    }

    static func makeProbeWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sadaa-provider-health-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let writer = try WavWriter(url: url)
        let sampleRate = 16_000
        let durationSeconds = 0.55
        let sampleCount = Int(Double(sampleRate) * durationSeconds)
        let samples = (0..<sampleCount).map { index -> Int16 in
            // Low-amplitude deterministic tone: enough bytes for provider
            // validation, not intended to be meaningful speech.
            let period = 80
            let value: Int16 = (index % period) < (period / 2) ? 900 : -900
            return value
        }
        try writer.append(samples: samples)
        try writer.finish()
        return url
    }

    private static func describe(_ error: Error) -> String {
        if let provider = error as? ProviderError {
            switch provider {
            case .http(let status, let body):
                let detail = sanitize(body.trimmingCharacters(in: .whitespacesAndNewlines))
                return detail.isEmpty ? "HTTP \(status) from provider" : "HTTP \(status): \(detail)"
            case .outOfCredits:
                return "the Deepgram account is out of credits"
            case .badResponse:
                return "unreadable provider response"
            case .notConfigured(let what):
                return what
            case .timedOut:
                return "timed out"
            case .transport(let urlError):
                return urlError.localizedDescription
            case .engineFailed(let detail):
                return detail
            }
        }
        return sanitize(error.localizedDescription)
    }
}
