import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite(.serialized) struct DeepgramProviderTests {
    private func provider(
        apiKey: String = "test-key",
        smartFormat: Bool = true,
        spokenPunctuation: Bool = false,
        session: URLSession = .shared
    ) -> DeepgramProvider {
        DeepgramProvider(
            config: .init(
                apiKey: apiKey,
                smartFormat: smartFormat,
                spokenPunctuation: spokenPunctuation),
            session: session
        )
    }

    /// The parsed query items, so assertions match parameter NAMES rather than
    /// substrings. Substring matching is how the original bug hid: `language=multi`
    /// looked correct in a `contains` check, and `detect_language=en` contains the
    /// literal text `language=en`, so both forms pass a careless assertion.
    private func items(
        pin: LanguagePin = .auto,
        smartFormat: Bool = true,
        spokenPunctuation: Bool = false,
        words: [String] = []
    ) throws -> [URLQueryItem] {
        let request = try provider(smartFormat: smartFormat, spokenPunctuation: spokenPunctuation)
            .makeRequest(
                audio: Data([0x01]),
                hint: TranscriptionHint(languagePin: pin, dictionaryWords: words))
        return URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private func names(_ items: [URLQueryItem]) -> [String] { items.map(\.name) }

    private func query(
        pin: LanguagePin = .auto,
        smartFormat: Bool = true,
        spokenPunctuation: Bool = false,
        words: [String] = []
    ) throws -> String {
        let request = try provider(smartFormat: smartFormat, spokenPunctuation: spokenPunctuation)
            .makeRequest(
                audio: Data([0x01]),
                hint: TranscriptionHint(languagePin: pin, dictionaryWords: words))
        return request.url?.query ?? ""
    }

    @Test func testRequestShapeUsesListenEndpointWithNova3() throws {
        let request = try provider().makeRequest(
            audio: Data([0x52, 0x49, 0x46, 0x46]),
            hint: TranscriptionHint(languagePin: .de, dictionaryWords: ["Sadaa", "Claude Code"])
        )
        let query = request.url?.query ?? ""
        #expect(request.url?.host == "api.deepgram.com")
        #expect(request.url?.path == "/v1/listen")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Token test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/wav")
        #expect(query.contains("model=nova-3"))
        #expect(query.contains("language=de"))
        #expect(query.contains("smart_format=true"))
        #expect(query.contains("keyterm=Sadaa"))
        #expect(query.contains("keyterm=Claude%20Code"))
        #expect(request.httpBody == Data([0x52, 0x49, 0x46, 0x46]))
    }

    // MARK: - Language mode
    //
    // Auto used to send `language=multi`, which is Multilingual Code-Switching —
    // for audio where the speaker switches languages mid-sentence — not language
    // detection. A user dictating in one language with the pin on auto was
    // transcribed in the wrong mode. These tests pin the corrected behaviour.

    @Test func testAutoUsesLanguageDetectionNotCodeSwitching() throws {
        let items = try items(pin: .auto)
        // The bug: `multi` means code-switching, not detection.
        #expect(!items.contains { $0.name == "language" && $0.value == "multi" })
        // Detection overrides `language`, so sending both would be misleading.
        #expect(!names(items).contains("language"))
        #expect(items.filter { $0.name == "detect_language" }.compactMap(\.value)
                == DeepgramLanguageCatalog.detectionCodes)
    }

    @Test func testAutoDetectionIsRestrictedToSupportedLanguages() throws {
        // A detected language Nova-3 does not support makes Deepgram fall back to
        // a lower model, which would silently drop `keyterm` support — the whole
        // dictionary feature. Restricting detection to en/de keeps that
        // unreachable, so the unqualified boolean form must not be used.
        let values = try items(pin: .auto)
            .filter { $0.name == "detect_language" }.compactMap(\.value)
        // The documented detection set is 35 codes, smaller than Nova-3's language
        // list, so this must NOT simply be the catalogue.
        #expect(values == DeepgramLanguageCatalog.detectionCodes)
        #expect(values.count == 35)
        #expect(!values.contains("true"))
        // Every detection code must also be a language the app can pin, or the
        // picker could offer something detection can never return.
        for code in values {
            #expect(DeepgramLanguageCatalog.isSupported(code), "detection code \(code) is not in the catalogue")
        }
    }

    @Test func testPinnedLanguagesSendLanguageAndNotDetection() throws {
        let english = try items(pin: .en)
        #expect(english.contains { $0.name == "language" && $0.value == "en" })
        #expect(!names(english).contains("detect_language"))

        let german = try items(pin: .de)
        #expect(german.contains { $0.name == "language" && $0.value == "de" })
        // A pinned language must not also request detection.
        #expect(!names(german).contains("detect_language"))
    }

    @Test func testKeytermsAreRepeatedNotJoined() throws {
        // "To boost multiple separate keyterms, repeat the `keyterm` parameter…
        // Do not separate keyterms with commas, semicolons, or line breaks."
        let items = try items(pin: .en, words: ["Sadaa", "Claude Code"])
        #expect(items.filter { $0.name == "keyterm" }.compactMap(\.value) == ["Sadaa", "Claude Code"])
    }

    // MARK: - Formatting parameters

    @Test func testNumeralsAccompanySmartFormat() throws {
        // smart_format only guarantees punctuation and paragraphs; numerals are
        // language-dependent, so they are requested explicitly.
        #expect(try query(smartFormat: true).contains("numerals=true"))
    }

    @Test func testNumeralsAreNotSentWhenFormattingIsOff() throws {
        let query = try query(smartFormat: false)
        #expect(!query.contains("numerals"))
        #expect(!query.contains("smart_format"))
        #expect(!query.contains("keyterm"))
    }

    @Test func testTagIsSentForUsageAttribution() throws {
        #expect(try query().contains("tag=useful-voice"))
    }

    // MARK: - Spoken punctuation (Deepgram "Dictation")

    @Test func testSpokenPunctuationSendsDictationAndPunctuate() throws {
        let query = try query(pin: .en, spokenPunctuation: true)
        // The docs are explicit that punctuation must also be enabled.
        #expect(query.contains("dictation=true"))
        #expect(query.contains("punctuate=true"))
    }

    @Test func testSpokenPunctuationIsOffByDefault() throws {
        let query = try query(pin: .en)
        #expect(!query.contains("dictation"))
        // Without dictation there is no reason to send punctuate at all.
        #expect(!query.contains("punctuate"))
    }

    @Test func testSpokenPunctuationIsSuppressedForGerman() throws {
        // Deepgram documents Dictation as English only, so sending it for German
        // would be asking for behaviour the docs do not promise.
        let query = try query(pin: .de, spokenPunctuation: true)
        #expect(!query.contains("dictation"))
        #expect(!query.contains("punctuate"))
    }

    // MARK: - Deadline sizing

    @Test func testDeadlineCeilingCoversTheLargestAdvertisedRecording() {
        // Ten minutes at 16 kHz mono 16-bit is 19.2 MB. The ceiling must exceed
        // what the formula needs at the pessimistic upload rate, or the ceiling
        // cancels the long dictations the formula exists to protect. At 180 the
        // largest recording could never have succeeded on a slow connection.
        let tenMinutes = 600 * 32_000
        let needed = Double(tenMinutes) / DeepgramProvider.assumedUploadBytesPerSecond
            + DeepgramProvider.processingAllowance
        #expect(DeepgramProvider.maximumDeadline >= needed)
        #expect(DeepgramProvider.deadline(forAudioBytes: tenMinutes) >= needed)
    }

    @Test func testDeadlineStillHasAFloorAndCeiling() {
        #expect(DeepgramProvider.deadline(forAudioBytes: 0) == DeepgramProvider.minimumDeadline)
        #expect(DeepgramProvider.deadline(forAudioBytes: 100_000_000) == DeepgramProvider.maximumDeadline)
    }

    // MARK: - Retry classification

    @Test func testRetryableStatusesFollowDocumentedGuidance() {
        // "An exponential-backoff retry strategy is recommended" for 429, and 5xx
        // is documented as possibly succeeding if retried.
        #expect(DeepgramProvider.isRetryable(status: 429))
        #expect(DeepgramProvider.isRetryable(status: 500))
        #expect(DeepgramProvider.isRetryable(status: 502))
        #expect(DeepgramProvider.isRetryable(status: 504))
        // Documented as an interrupted or slow upload, so it is worth retrying.
        #expect(DeepgramProvider.isRetryable(status: 408))
        // Permanent: retrying spends time to fail identically.
        #expect(!DeepgramProvider.isRetryable(status: 400))
        #expect(!DeepgramProvider.isRetryable(status: 401))
        #expect(!DeepgramProvider.isRetryable(status: 402))
        #expect(!DeepgramProvider.isRetryable(status: 403))
    }

    @Test func testBackoffIsBoundedAndIncreasing() {
        #expect(DeepgramProvider.retryBackoff.count == 2)
        #expect(DeepgramProvider.retryBackoff[1] > DeepgramProvider.retryBackoff[0])
        #expect(DeepgramProvider.retryBackoff.allSatisfy { $0 > 0 && $0 < 10 })
    }

    @Test func testMissingKeyThrows() {
        #expect(throws: ProviderError.self) {
            try provider(apiKey: "   ").makeRequest(
                audio: Data([0x01]),
                hint: TranscriptionHint(languagePin: .auto, dictionaryWords: [])
            )
        }
    }

    @Test func testTranscribeParsesDeepgramJSON() async throws {
        DeepgramStubURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Token test-key")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"metadata":{"duration":1.5},"results":{"channels":[{"alternatives":[{"transcript":"  hello from Sadaa  "}]}]}}"#
            return (response, Data(json.utf8))
        }
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcript = try await provider(session: DeepgramStubURLProtocol.session()).transcribe(
            audio: audioURL,
            hint: TranscriptionHint(languagePin: .auto, dictionaryWords: [])
        )
        #expect(transcript.text == "hello from Sadaa")
        #expect(transcript.durationSeconds == 1.5)
        #expect(transcript.detectedLanguage == nil)
    }

    @Test func testDetectedLanguageIsReadFromTheResponse() async throws {
        // The app has always stored and displayed a detected language, but the
        // field was hardcoded to nil and detection was never requested, so that
        // path could not run. It now comes from the response.
        DeepgramStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"metadata":{"duration":2},"results":{"channels":[{"detected_language":"de","alternatives":[{"transcript":"hallo"}]}]}}"#
            return (response, Data(json.utf8))
        }
        let transcript = try await transcribeWithStub()
        #expect(transcript.detectedLanguage == "de")
        #expect(transcript.text == "hallo")
    }

    @Test func testRequestIDAidsSupportAndIsCappedInOneLine() async throws {
        DeepgramStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            let json = #"{"err_code":"INVALID_JSON","err_msg":"bad audio","request_id":"abc-123"}"#
            return (response, Data(json.utf8))
        }
        do {
            _ = try await transcribeWithStub()
            Issue.record("expected the request to fail")
        } catch let error as ProviderError {
            guard case .http(let status, let body) = error else {
                Issue.record("expected .http, got \(error)"); return
            }
            #expect(status == 400)
            // The docs tell users to quote this to support, so it has to survive
            // into the message the user actually sees.
            #expect(body.contains("abc-123"))
        }
    }

    @Test func testOutOfCreditsIsItsOwnErrorNotAGenericBadRequest() async throws {
        // 402 has its own documented code (ASR_PAYMENT_REQUIRED) and its own fix.
        // Reported as "HTTP 402" it sends the user looking for a problem with
        // their audio instead of topping up their account.
        DeepgramStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 402, httpVersion: nil, headerFields: nil)!
            let json = #"{"err_code":"ASR_PAYMENT_REQUIRED","err_msg":"Project does not have enough credits.","request_id":"pay-1"}"#
            return (response, Data(json.utf8))
        }
        do {
            _ = try await transcribeWithStub()
            Issue.record("expected the request to fail")
        } catch let error as ProviderError {
            guard case .outOfCredits(let message) = error else {
                Issue.record("expected .outOfCredits, got \(error)"); return
            }
            #expect(message.lowercased().contains("credit"))
            #expect(message.contains("pay-1"))
        }
    }

    @Test func testRateLimitIsRetriedThenSucceeds() async throws {
        // "An exponential-backoff retry strategy is recommended" for 429. Before
        // this, a single transient rate limit ended the dictation.
        nonisolated(unsafe) var attempts = 0
        DeepgramStubURLProtocol.handler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 429, httpVersion: nil,
                    headerFields: ["Retry-After": "1"])!
                return (response, Data(#"{"err_code":"TOO_MANY_REQUESTS"}"#.utf8))
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"metadata":{"duration":1},"results":{"channels":[{"alternatives":[{"transcript":"second try"}]}]}}"#
            return (response, Data(json.utf8))
        }
        let transcript = try await transcribeWithStub()
        #expect(attempts == 2)
        #expect(transcript.text == "second try")
    }

    @Test func testRetriesAreBounded() async throws {
        // A genuinely down service must fail, not loop. Three attempts total.
        nonisolated(unsafe) var attempts = 0
        DeepgramStubURLProtocol.handler = { request in
            attempts += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"err_msg":"unavailable"}"#.utf8))
        }
        do {
            _ = try await transcribeWithStub()
            Issue.record("expected the request to fail")
        } catch let error as ProviderError {
            guard case .http(let status, _) = error else {
                Issue.record("expected .http, got \(error)"); return
            }
            #expect(status == 503)
        }
        #expect(attempts == 3)
    }

    @Test func testPermanentFailureIsNotRetried() async throws {
        // Retrying a 401 cannot succeed and only delays the error.
        nonisolated(unsafe) var attempts = 0
        DeepgramStubURLProtocol.handler = { request in
            attempts += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"err_code":"INVALID_AUTH","request_id":"auth-1"}"#.utf8))
        }
        _ = try? await transcribeWithStub()
        #expect(attempts == 1)
    }

    @Test func testRequestIDParsingToleratesUnparseableBodies() {
        // A non-JSON body must not mask the real error with a parse failure.
        #expect(DeepgramProvider.requestID(fromBody: Data("<html>502</html>".utf8)) == nil)
        #expect(DeepgramProvider.requestID(fromBody: Data("{}".utf8)) == nil)
        #expect(DeepgramProvider.requestID(fromBody: Data(#"{"request_id":""}"#.utf8)) == nil)
        #expect(DeepgramProvider.requestID(fromBody: Data(#"{"request_id":"top-level"}"#.utf8)) == "top-level")
        #expect(DeepgramProvider.requestID(fromBody: Data(#"{"metadata":{"request_id":"nested"}}"#.utf8)) == "nested")
    }

    /// Run one transcription against the stub handler with a throwaway audio file.
    private func transcribeWithStub() async throws -> Transcript {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepgram-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        return try await provider(session: DeepgramStubURLProtocol.session()).transcribe(
            audio: audioURL,
            hint: TranscriptionHint(languagePin: .auto, dictionaryWords: [])
        )
    }
}

private final class DeepgramStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepgramStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else { return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
