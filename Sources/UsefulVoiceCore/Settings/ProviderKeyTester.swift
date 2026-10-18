import Foundation

/// What "Test" on a key row found.
public enum KeyTestResult: Equatable, Sendable {
    case ok(milliseconds: Int)
    /// The provider answered 401, 403 or (Gemini) 400 for an invalid key.
    case rejected
    case offline
    case failed(String)
}

/// A cheap authenticated call per provider, so a key can be checked without
/// spending a transcription. Deepgram's own check stays the real transcription
/// probe in `ProviderHealthCheck`; this covers the other three.
public enum ProviderKeyTester {
    /// The request that proves the key, or nil for Deepgram.
    public static func request(provider: KeyProvider, key: String) -> URLRequest? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .deepgram:
            return nil
        case .gemini:
            // Header, never the URL: a key in a URL ends up in logs.
            let model = ModelCatalog.language.first { $0.provider == "gemini" }?.apiModel ?? "gemini-3.8-flash"
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model)")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            return request
        case .anthropic:
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return request
        case .elevenLabs:
            var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/models")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            return request
        }
    }

    /// Maps a status to a result. Gemini answers an invalid key with 400.
    public static func classify(status: Int, body: String, milliseconds: Int) -> KeyTestResult {
        switch status {
        case 200..<300: return .ok(milliseconds: milliseconds)
        case 401, 403: return body.contains("quota_exceeded")
            ? .failed("Your ElevenLabs account is out of credits.") : .rejected
        case 400 where body.contains("API_KEY_INVALID") || body.lowercased().contains("api key not valid"):
            return .rejected
        default: return .failed("The provider answered HTTP \(status).")
        }
    }

    public static func test(provider: KeyProvider, key: String,
                            session: URLSession = .shared) async -> KeyTestResult {
        guard var request = request(provider: provider, key: key) else {
            return .failed("Use the Deepgram connection test.")
        }
        request.timeoutInterval = 12
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("Unreadable answer.") }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return classify(status: http.statusCode,
                            body: String(decoding: data.prefix(2000), as: UTF8.self), milliseconds: ms)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed:
                return .offline
            case .timedOut: return .failed("The provider took too long to answer.")
            default: return .failed("Could not connect.")
            }
        } catch {
            return .failed("Could not connect.")
        }
    }
}
