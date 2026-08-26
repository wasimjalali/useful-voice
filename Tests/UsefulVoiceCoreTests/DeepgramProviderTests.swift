import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite(.serialized) struct DeepgramProviderTests {
    private func provider(
        apiKey: String = "test-key",
        smartFormat: Bool = true,
        session: URLSession = .shared
    ) -> DeepgramProvider {
        DeepgramProvider(
            config: .init(apiKey: apiKey, smartFormat: smartFormat),
            session: session
        )
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

    @Test func testAutoLanguageMapsToMultiAndSmartFormatOffOmitsParam() throws {
        let request = try provider(smartFormat: false).makeRequest(
            audio: Data([0x01]),
            hint: TranscriptionHint(languagePin: .auto, dictionaryWords: [])
        )
        let query = request.url?.query ?? ""
        #expect(query.contains("language=multi"))
        #expect(!query.contains("smart_format"))
        #expect(!query.contains("keyterm"))
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
