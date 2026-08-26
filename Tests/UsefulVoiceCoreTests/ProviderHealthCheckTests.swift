import Testing
import Foundation
@testable import UsefulVoiceCore

private struct HealthFakeProvider: TranscriptionProvider {
    let name: String
    let result: Result<Transcript, Error>

    func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        #expect(FileManager.default.fileExists(atPath: audio.path))
        return try result.get()
    }
}

@Suite(.serialized) struct ProviderHealthCheckTests {
    @Test func testRedactionRemovesPathAndQuery() {
        let redacted = ProviderHealthCheck.redactedEndpoint(
            "https://api.deepgram.com/v1/listen?model=nova-3"
        )
        #expect(redacted == "https://api.deepgram.com")
    }

    @Test func testSanitizeRemovesKeysAndBearerTokens() {
        let message = #"api-key: abc123 Bearer token.secret Ocp-Apim-Subscription-Key="speech" Token dg_deadbeef123"#
        let sanitized = ProviderHealthCheck.sanitize(message)
        #expect(!sanitized.contains("abc123"))
        #expect(!sanitized.contains("token.secret"))
        #expect(!sanitized.contains("speech"))
        #expect(!sanitized.contains("dg_deadbeef123"))
    }

    @Test func testHealthCheckSuccessReportsLatencyAndRedactedEndpoint() async {
        let provider = HealthFakeProvider(
            name: "Fake",
            result: .success(Transcript(text: "", detectedLanguage: nil, durationSeconds: nil))
        )
        var dates = [
            Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 10.25),
        ]
        let result = await ProviderHealthCheck.check(
            provider: provider,
            endpoint: "https://api.deepgram.com/v1/listen?model=nova-3",
            hint: TranscriptionHint(languagePin: .auto, dictionaryWords: []),
            now: { dates.isEmpty ? Date(timeIntervalSince1970: 10.25) : dates.removeFirst() }
        )

        #expect(result.ok)
        #expect(result.latencyMilliseconds == 250)
        #expect(result.redactedEndpoint == "https://api.deepgram.com")
        #expect(!result.message.contains("nova-3"))
    }

    @Test func testHealthCheckFailureSanitizesProviderBody() async {
        let provider = HealthFakeProvider(
            name: "Fake",
            result: .failure(ProviderError.http(401, #"api-key: secret"#))
        )
        let result = await ProviderHealthCheck.check(
            provider: provider,
            endpoint: "https://api.deepgram.com/v1/listen",
            hint: TranscriptionHint(languagePin: .auto, dictionaryWords: [])
        )

        #expect(!result.ok)
        #expect(result.message.contains("HTTP 401"))
        #expect(!result.message.contains("secret"))
    }
}
