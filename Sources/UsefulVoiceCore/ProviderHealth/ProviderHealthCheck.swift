import Foundation

public struct ProviderHealthResult: Equatable, Sendable {
    public let providerName: String
    public let ok: Bool
    public let latencyMilliseconds: Int?
    public let message: String
    public let redactedEndpoint: String

    public init(providerName: String,
                ok: Bool,
                latencyMilliseconds: Int?,
                message: String,
                redactedEndpoint: String) {
        self.providerName = providerName
        self.ok = ok
        self.latencyMilliseconds = latencyMilliseconds
        self.message = message
        self.redactedEndpoint = redactedEndpoint
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
                message: describe(error)
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
                              message: String) -> ProviderHealthResult {
        ProviderHealthResult(
            providerName: providerName,
            ok: ok,
            latencyMilliseconds: Int(finishedAt.timeIntervalSince(startedAt) * 1000),
            message: sanitize(message),
            redactedEndpoint: redactedEndpoint(endpoint)
        )
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
            case .badResponse:
                return "unreadable provider response"
            case .notConfigured(let what):
                return what
            case .timedOut:
                return "timed out"
            case .transport(let urlError):
                return urlError.localizedDescription
            }
        }
        return sanitize(error.localizedDescription)
    }
}
