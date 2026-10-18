import Foundation
import Testing
@testable import UsefulVoiceCore

private func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/models/\(name)")
}

private func fixtureText(_ name: String) throws -> String {
    try String(contentsOf: fixtureURL(name), encoding: .utf8)
}

private func scratchDefaults() -> UserDefaults {
    let suite = "uv-models-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func queryValue(_ request: URLRequest, _ name: String) -> [String] {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        .queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
}

// MARK: - Catalog and prompt fixtures

@Suite("Model catalog") struct ModelCatalogTests {
    private struct Fixture: Decodable {
        struct Entry: Decodable {
            let id, name, provider, apiModel, kind: String
            let badge: String?
            let speed, accuracy: Int
            let platforms: [String]
        }
        let voice: [Entry]
        let language: [Entry]
    }

    private func matches(_ catalog: [ModelEntry], _ fixture: [Fixture.Entry]) {
        let expected = fixture.filter { $0.platforms.contains("macos") }
        #expect(catalog.map(\.id) == expected.map(\.id))
        for (entry, want) in zip(catalog, expected) {
            #expect(entry.name == want.name)
            #expect(entry.provider == want.provider)
            #expect(entry.apiModel == want.apiModel)
            #expect(entry.kind.rawValue == want.kind)
            #expect(entry.badge == want.badge)
            #expect(entry.speed == want.speed)
            #expect(entry.accuracy == want.accuracy)
        }
    }

    @Test func voiceListMatchesTheSharedFixture() throws {
        let data = try Data(contentsOf: fixtureURL("catalog.json"))
        matches(ModelCatalog.voice, try JSONDecoder().decode(Fixture.self, from: data).voice)
    }

    @Test func languageListMatchesTheSharedFixture() throws {
        let data = try Data(contentsOf: fixtureURL("catalog.json"))
        matches(ModelCatalog.language, try JSONDecoder().decode(Fixture.self, from: data).language)
    }

    @Test func formatterPromptIsTheFixtureVerbatim() throws {
        #expect(FormatterPrompt.system + "\n" == (try fixtureText("formatter-system-prompt.txt")))
    }

    @Test func geminiTranscribePromptIsTheFixtureVerbatim() throws {
        #expect(GeminiTranscriptionProvider.systemPrompt + "\n" == (try fixtureText("gemini-transcribe-prompt.txt")))
    }

    @Test func everyWhisperVoiceIdNamesARealModel() {
        for entry in ModelCatalog.voice where entry.provider == "openai" {
            #expect(ModelCatalog.whisperModel(forVoiceID: entry.id) != nil)
        }
        #expect(ModelCatalog.voiceID(forWhisper: WhisperModelCatalog.largeV3Turbo) == "whisper:large-v3-turbo")
    }
}

// MARK: - Settings migration

@Suite("Voice model setting") struct VoiceModelSettingTests {
    @Test func aFreshInstallUsesNova3AndNoFormatter() {
        let settings = AppSettings(defaults: scratchDefaults())
        #expect(settings.voiceModelID == "deepgram:nova-3")
        #expect(settings.formatterModelID == nil)
    }

    @Test func anOldDeepgramEngineMigratesToNova3() {
        let defaults = scratchDefaults()
        defaults.set("deepgram", forKey: "transcriptionEngine")
        #expect(AppSettings(defaults: defaults).voiceModelID == "deepgram:nova-3")
    }

    @Test func anOldLocalEngineKeepsItsActiveWhisperModel() {
        let defaults = scratchDefaults()
        defaults.set("whisperLocal", forKey: "transcriptionEngine")
        defaults.set("whisper-large-v3", forKey: "localModelID")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.voiceModelID == "whisper:large-v3")
        #expect(settings.transcriptionEngine == .whisperLocal)
    }

    @Test func anUnknownSavedIdFallsBackToTheOldChoiceNotAnotherProvider() {
        let defaults = scratchDefaults()
        defaults.set("whisperLocal", forKey: "transcriptionEngine")
        defaults.set("elevenlabs:gone", forKey: "voiceModelID")
        #expect(AppSettings(defaults: defaults).voiceModelID == "whisper:large-v3-turbo")
    }

    @Test func settingTheVoiceModelKeepsTheOldKeysInStep() {
        let defaults = scratchDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.voiceModelID = "whisper:large-v3"
        #expect(settings.localModelID == "whisper-large-v3")
        #expect(settings.transcriptionEngine == .whisperLocal)
        settings.voiceModelID = "elevenlabs:scribe_v2"
        #expect(settings.transcriptionEngine == .deepgram)
        #expect(settings.voiceModelID == "elevenlabs:scribe_v2")
    }

    @Test func aRejectedIdIsNotSaved() {
        let settings = AppSettings(defaults: scratchDefaults())
        settings.voiceModelID = "nonsense"
        settings.formatterModelID = "anthropic:claude-haiku-4-5"
        #expect(settings.voiceModelID == "deepgram:nova-3")
        #expect(settings.formatterModelID == nil)
    }

    @Test func theFirstRunEngineChoiceMapsToTheNewSetting() {
        let settings = AppSettings(defaults: scratchDefaults())
        settings.transcriptionEngine = .whisperLocal
        #expect(settings.voiceModelID == "whisper:large-v3-turbo")
        settings.transcriptionEngine = .deepgram
        #expect(settings.voiceModelID == "deepgram:nova-3")
    }

    @Test func puttingTheEngineBackToDeepgramKeepsACloudChoice() {
        let settings = AppSettings(defaults: scratchDefaults())
        settings.voiceModelID = "elevenlabs:scribe_v2"
        settings.transcriptionEngine = .deepgram
        #expect(settings.voiceModelID == "elevenlabs:scribe_v2")
    }

    @Test func changingTheLocalModelMovesAWhisperVoiceModel() {
        let settings = AppSettings(defaults: scratchDefaults())
        settings.voiceModelID = "whisper:large-v3-turbo"
        settings.localModelID = "whisper-large-v3"
        #expect(settings.voiceModelID == "whisper:large-v3")
    }
}

// MARK: - Provider selection

@Suite("Voice model selection") struct VoiceModelSelectorTests {
    private func plan(_ id: String, keys: Set<KeyProvider> = [],
                      whisper: LocalModelAvailability = .missing) -> VoicePlan {
        VoiceModelSelector.resolve(voiceModelID: id, keyAvailable: { keys.contains($0) },
                                   whisperAvailability: { _ in whisper })
    }

    @Test func aCloudModelWithoutItsKeyNeedsThatKeyAndNeverFallsBack() {
        #expect(plan("elevenlabs:scribe_v2", keys: [.deepgram, .gemini]) == .needsKey(.elevenLabs))
        #expect(plan("gemini-audio:gemini-3.8-flash", keys: [.deepgram]) == .needsKey(.gemini))
        #expect(plan("deepgram:nova-3") == .needsKey(.deepgram))
        #expect(VoiceModelSelector.keyMessage(for: .elevenLabs) == "Add your ElevenLabs key in Settings.")
    }

    @Test func cloudModelsWithKeysResolveToTheirProvider() {
        #expect(plan("deepgram:nova-3-medical", keys: [.deepgram]) == .deepgram(apiModel: "nova-3-medical"))
        #expect(plan("elevenlabs:scribe_v2", keys: [.elevenLabs]) == .elevenLabs(apiModel: "scribe_v2"))
        #expect(plan("gemini-audio:gemini-3.8-flash", keys: [.gemini]) == .gemini(apiModel: "gemini-3.8-flash"))
    }

    @Test func localModelsNeverNeedAKeyAndWhisperChecksTheFile() {
        #expect(plan("parakeet:v3") == .parakeet(.v3))
        #expect(plan("whisper:large-v3", whisper: .missing) == .needsWhisperDownload(WhisperModelCatalog.largeV3))
        #expect(plan("whisper:large-v3", keys: [.deepgram], whisper: .missing)
                == .needsWhisperDownload(WhisperModelCatalog.largeV3))
        #expect(plan("whisper:large-v3", whisper: .usable) == .whisper(WhisperModelCatalog.largeV3))
    }

    @Test func parakeetV2RefusesOtherLanguagesBeforeAnyWork() {
        #expect(ParakeetLanguageGuard.refusal(for: .de, version: .v2)?.contains("English") == true)
        #expect(ParakeetLanguageGuard.refusal(for: .en, version: .v2) == nil)
        #expect(ParakeetLanguageGuard.refusal(for: .auto, version: .v2) == nil)
        #expect(ParakeetLanguageGuard.refusal(for: LanguagePin(rawValue: "en-GB"), version: .v2) == nil)
    }

    @Test func parakeetV3RefusesLanguagesOutsideItsTwentyFive() {
        #expect(ParakeetLanguageGuard.refusal(for: .de, version: .v3) == nil)
        #expect(ParakeetLanguageGuard.refusal(for: LanguagePin(rawValue: "ja"), version: .v3) != nil)
        #expect(ParakeetLanguageGuard.v3Languages.count == 25)
    }

    @Test func theGuardFailsFastWithoutCallingTheModel() async {
        let inner = FakeProvider(name: "p", result: .failure(ProviderError.badResponse))
        let guarded = ParakeetLanguageGuard(version: .v2, inner: inner)
        do {
            _ = try await guarded.transcribe(audio: URL(fileURLWithPath: "/nonexistent.wav"),
                                             hint: TranscriptionHint(languagePin: .de, dictionaryWords: []))
            Issue.record("expected a refusal")
        } catch ProviderError.notConfigured(let message) {
            #expect(message.contains("English"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }
}

// MARK: - Deepgram Nova-3 Medical

@Suite("Nova-3 Medical") struct NovaMedicalTests {
    private func request(pin: LanguagePin, words: [String] = []) throws -> URLRequest {
        try DeepgramProvider(config: .init(apiKey: "k", model: "nova-3-medical", smartFormat: true))
            .makeRequest(audio: Data([1]), hint: TranscriptionHint(languagePin: pin, dictionaryWords: words))
    }

    @Test func otherLanguagesFailBeforeARequestIsMade() {
        for pin in [LanguagePin.de, .multilingual] {
            do {
                _ = try request(pin: pin)
                Issue.record("expected a refusal for \(pin.rawValue)")
            } catch ProviderError.notConfigured(let message) {
                #expect(message == "Nova-3 Medical only speaks English. Pick another voice model or switch the language to English.")
            } catch {
                Issue.record("wrong error \(error)")
            }
        }
    }

    @Test func autoAndEnglishSendLanguageEnAndNeverDetection() throws {
        for pin in [LanguagePin.auto, .en, LanguagePin(rawValue: "en-GB")] {
            let request = try request(pin: pin)
            #expect(queryValue(request, "model") == ["nova-3-medical"])
            #expect(queryValue(request, "language") == ["en"])
            #expect(queryValue(request, "detect_language").isEmpty)
        }
    }

    @Test func keytermsStillGo() throws {
        #expect(queryValue(try request(pin: .en, words: ["metoprolol"]), "keyterm") == ["metoprolol"])
    }
}

// MARK: - ElevenLabs

@Suite("ElevenLabs Scribe") struct ElevenLabsTests {
    private func body(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    private func fields(_ request: URLRequest, _ name: String) -> [String] {
        // "\r\n" is one Character in Swift, so split on the whole line break.
        let lines = body(request).components(separatedBy: "\r\n")
        var result: [String] = []
        for (index, line) in lines.enumerated() where line.contains("name=\"\(name)\"") && index + 2 < lines.count {
            result.append(lines[index + 2])
        }
        return result
    }

    private func make(pin: LanguagePin = .auto, words: [String] = [], key: String = "k") throws -> URLRequest {
        try ElevenLabsProvider(config: .init(apiKey: key))
            .makeRequest(audio: Data([0x52, 0x49]), hint: TranscriptionHint(languagePin: pin, dictionaryWords: words))
    }

    @Test func aMissingKeyIsAnActionableError() {
        do {
            _ = try make(key: "  ")
            Issue.record("expected an error")
        } catch ProviderError.notConfigured(let message) {
            #expect(message == "Add your ElevenLabs key in Settings.")
        } catch { Issue.record("wrong error") }
    }

    @Test func theRequestCarriesTheDocumentedFields() throws {
        let request = try make(pin: .de, words: ["Kubernetes", "Useful Voice"])
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(fields(request, "model_id") == ["scribe_v2"])
        #expect(fields(request, "language_code") == ["de"])
        #expect(fields(request, "tag_audio_events") == ["false"])
        #expect(fields(request, "keyterms") == ["Kubernetes", "Useful Voice"])
        #expect(body(request).contains("name=\"file\"; filename=\"dictation.wav\""))
    }

    @Test func autoOmitsTheLanguage() throws {
        #expect(fields(try make(pin: .auto), "language_code").isEmpty)
        #expect(fields(try make(pin: .multilingual), "language_code").isEmpty)
    }

    @Test func aRegionalPinGoesAsItsBaseLanguage() throws {
        #expect(fields(try make(pin: LanguagePin(rawValue: "de-CH")), "language_code") == ["de"])
    }

    @Test func keytermsAreCappedAndFiltered() throws {
        let tooMany = (0..<80).map { "term\($0)" }
        #expect(fields(try make(words: tooMany), "keyterms").count == 50)
        let bad = ["one two three four five six", String(repeating: "x", count: 50), "a<b", "fine"]
        #expect(fields(try make(words: bad), "keyterms") == ["fine"])
    }

    @Test func statusesMapToKeyRateLimitAndRetry() {
        func code(_ status: Int) -> Int? {
            if case .http(let code, _) = ElevenLabsProvider.error(forStatus: status, body: Data()) { return code }
            return nil
        }
        #expect(code(401) == 401 && code(403) == 403)
        #expect(code(429) == 429)
        #expect(DeepgramProvider.isRetryable(status: 429) && DeepgramProvider.isRetryable(status: 503))
        #expect(!DeepgramProvider.isRetryable(status: 401))
    }

    @Test func responseTextAndDetectedLanguageAreRead() throws {
        let json = #"{"text":"  Hello there. ","language_code":"eng","language_probability":0.99,"words":[]}"#
        let auto = try ElevenLabsProvider.parse(Data(json.utf8), pin: .auto)
        #expect(auto.text == "Hello there.")
        #expect(auto.detectedLanguage == "en")
        let pinned = try ElevenLabsProvider.parse(Data(json.utf8), pin: .en)
        #expect(pinned.detectedLanguage == nil)
    }

    @Test func aBodyWithoutTextIsABadResponse() {
        #expect(throws: ProviderError.self) { try ElevenLabsProvider.parse(Data("{}".utf8), pin: .auto) }
        #expect(throws: ProviderError.self) { try ElevenLabsProvider.parse(Data("nope".utf8), pin: .auto) }
    }
}

// MARK: - Gemini as a voice model

@Suite("Gemini transcription") struct GeminiTranscriptionTests {
    private func make(pin: LanguagePin = .auto, words: [String] = [], audio: Data = Data([1, 2, 3]),
                      model: String = "gemini-3.8-flash") throws -> (URLRequest, [String: Any]) {
        let request = try GeminiTranscriptionProvider(config: .init(apiKey: "k", model: model))
            .makeRequest(audio: audio, hint: TranscriptionHint(languagePin: pin, dictionaryWords: words))
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        return (request, json)
    }

    private func parts(_ json: [String: Any]) -> [[String: Any]] {
        let contents = json["contents"] as! [[String: Any]]
        return contents[0]["parts"] as! [[String: Any]]
    }

    @Test func theKeyIsAHeaderNeverInTheURL() throws {
        let (request, _) = try make()
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "k")
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent")
        #expect(!(request.url?.absoluteString.contains("key=") ?? true))
    }

    @Test func audioGoesInlineAndThePromptIsTheSystemInstruction() throws {
        let (_, json) = try make()
        let inline = parts(json)[0]["inlineData"] as! [String: String]
        #expect(inline["mimeType"] == "audio/wav")
        #expect(inline["data"] == Data([1, 2, 3]).base64EncodedString())
        let system = (json["systemInstruction"] as! [String: Any])["parts"] as! [[String: String]]
        #expect(system[0]["text"] == GeminiTranscriptionProvider.systemPrompt)
        #expect(parts(json).count == 1)
        let level = ((json["generationConfig"] as! [String: Any])["thinkingConfig"] as! [String: String])["thinkingLevel"]
        #expect(level == "low")
    }

    @Test func vocabularyAndAPinnedLanguageGoInATextPart() throws {
        let (_, json) = try make(pin: .de, words: ["Kubernetes", "Wasim"])
        let text = parts(json)[1]["text"] as! String
        #expect(text.contains("<vocabulary>Kubernetes, Wasim</vocabulary>"))
        #expect(text.contains("Language: German"))
    }

    @Test func vocabularyIsCappedAtOneHundredWords() throws {
        let (_, json) = try make(words: (0..<150).map { "w\($0)" })
        let text = parts(json)[1]["text"] as! String
        #expect(text.contains("w99") && !text.contains("w100"))
    }

    @Test func aRecordingTooBigForInlineFailsFast() {
        let big = Data(count: 15_000_000)
        do {
            _ = try make(audio: big)
            Issue.record("expected a refusal")
        } catch ProviderError.notConfigured(let message) {
            #expect(message == "This recording is too long for Gemini. Pick another voice model for long dictations.")
        } catch { Issue.record("wrong error") }
    }

    @Test func textIsJoinedFromNonThoughtParts() throws {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"thinking...","thought":true},{"text":"Hello "},{"text":"world."}]}}]}"#
        #expect(try GeminiTranscriptionProvider.parse(Data(json.utf8)).text == "Hello world.")
    }

    @Test func silenceIsAnEmptyTranscriptAndABlockedPromptToo() throws {
        let empty = #"{"candidates":[{"content":{"parts":[]}}]}"#
        #expect(try GeminiTranscriptionProvider.parse(Data(empty.utf8)).text.isEmpty)
        let blocked = #"{"promptFeedback":{"blockReason":"OTHER"}}"#
        #expect(try GeminiTranscriptionProvider.parse(Data(blocked.utf8)).text.isEmpty)
        #expect(throws: ProviderError.self) { try GeminiTranscriptionProvider.parse(Data("{}".utf8)) }
    }

    @Test func invalidKeyStatusesAreKeyProblems() {
        func code(_ status: Int, _ body: String = "") -> Int? {
            if case .http(let code, _) = GeminiTranscriptionProvider.error(forStatus: status, body: Data(body.utf8)) { return code }
            return nil
        }
        #expect(code(401) == 401 && code(403) == 403)
        #expect(code(400, #"{"error":{"status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#) == 401)
        #expect(code(400, "bad audio") == 400)
        #expect(code(429) == 429)
        #expect(GeminiTranscriptionProvider.deadline(forAudioBytes: 1000) >= 20)
    }
}

// MARK: - AI formatting

@Suite("Formatter guard") struct FormatterGuardTests {
    private let input = "so um i think we should ship it on wednesday after the review"

    @Test func emptyOutputIsRejected() {
        #expect(FormatterGuard.accept(input: input, output: "  \n") == nil)
    }

    @Test func tooLongOutputIsRejected() {
        #expect(FormatterGuard.accept(input: input, output: String(repeating: "a", count: input.count * 2 + 41)) == nil)
        #expect(FormatterGuard.accept(input: input, output: String(repeating: "a", count: input.count * 2 + 40)) != nil)
    }

    @Test func tooShortOutputIsRejectedOnlyForLongInput() {
        #expect(FormatterGuard.accept(input: input, output: "Ship it.") == nil)
        #expect(FormatterGuard.accept(input: "send it now", output: "Go.") == "Go.")
    }

    @Test func anAssistantPreambleIsRejected() {
        for preamble in ["Here is the text: I think we should ship it on Wednesday after the review.",
                         "Here's the cleaned text: I think we should ship it on Wednesday.",
                         "Sure, I think we should ship it on Wednesday after the review.",
                         "Certainly! I think we should ship it on Wednesday after review.",
                         "I've fixed it: we should ship it on Wednesday after the review.",
                         "I have formatted it: we ship on Wednesday after the review.",
                         "Of course. We should ship it on Wednesday after the review."] {
            #expect(FormatterGuard.accept(input: input, output: preamble) == nil, "\(preamble)")
        }
    }

    @Test func aDictationThatReallyStartsThatWayIsKept() {
        let spoken = "sure send it over on wednesday after the review please"
        #expect(FormatterGuard.accept(input: spoken, output: "Sure, send it over on Wednesday after the review, please.") != nil)
    }

    @Test func oneWrappingFenceAndOneDictationTagAreStripped() {
        let clean = "I think we should ship it on Wednesday after the review."
        #expect(FormatterGuard.accept(input: input, output: "```\n\(clean)\n```") == clean)
        #expect(FormatterGuard.accept(input: input, output: "```text\n\(clean)\n```") == clean)
        #expect(FormatterGuard.accept(input: input, output: "<dictation>\n\(clean)\n</dictation>") == clean)
        #expect(FormatterGuard.accept(input: input, output: "  \(clean)  ") == clean)
    }
}

@Suite("Formatter requests") struct FormatterRequestTests {
    private let haiku = ModelCatalog.languageModel(id: "anthropic:claude-haiku-5-5")!
    private let sonnet = ModelCatalog.languageModel(id: "anthropic:claude-sonnet-5-5")!
    private let gemini = ModelCatalog.languageModel(id: "gemini:gemini-3.8-flash")!

    private func json(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    }

    @Test func theUserMessageWrapsTheDictationAndOnlyAddsVocabularyWhenThereIsSome() {
        #expect(FormatterRequest.userMessage(text: "hi there", vocabulary: [])
                == "<dictation>\nhi there\n</dictation>")
        #expect(FormatterRequest.userMessage(text: "hi there", vocabulary: ["Kubernetes", "Wasim"])
                == "<vocabulary>Kubernetes, Wasim</vocabulary>\n<dictation>\nhi there\n</dictation>")
        let many = FormatterRequest.userMessage(text: "x", vocabulary: (0..<130).map { "w\($0)" })
        #expect(many.contains("w99") && !many.contains("w100"))
    }

    @Test func geminiUsesTheHeaderASystemInstructionAndLowThinking() throws {
        let request = try FormatterRequest.gemini(model: gemini, apiKey: "k", text: "hello there friend", vocabulary: [])
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "k")
        #expect(request.url?.path == "/v1beta/models/gemini-3.8-flash:generateContent")
        let body = try json(request)
        let system = (body["systemInstruction"] as! [String: Any])["parts"] as! [[String: String]]
        #expect(system[0]["text"] == FormatterPrompt.system)
        let config = body["generationConfig"] as! [String: Any]
        #expect((config["thinkingConfig"] as! [String: String])["thinkingLevel"] == "low")
        #expect(config["temperature"] == nil)
    }

    @Test func anthropicHaikuDisablesThinkingAndSendsNoSampling() throws {
        let request = try FormatterRequest.anthropic(model: haiku, apiKey: "k", text: "hello there friend", vocabulary: [])
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try json(request)
        #expect((body["thinking"] as! [String: String])["type"] == "disabled")
        #expect(body["temperature"] == nil && body["top_p"] == nil && body["top_k"] == nil)
        #expect(body["system"] as? String == FormatterPrompt.system)
        #expect(body["model"] as? String == "claude-haiku-5-5")
    }

    @Test func sonnetUsesBetweenToolsBecauseItRejectsDisabled() throws {
        let body = try json(FormatterRequest.anthropic(model: sonnet, apiKey: "k", text: "a b c", vocabulary: []))
        #expect((body["thinking"] as! [String: String])["type"] == "between_tools")
    }

    @Test func theThinkingFieldCanBeLeftOut() throws {
        let body = try json(FormatterRequest.anthropic(model: haiku, apiKey: "k", text: "a b c",
                                                       vocabulary: [], includeThinkingField: false))
        #expect(body["thinking"] == nil)
    }

    @Test func maxTokensFollowsTheInputLengthWithinBounds() {
        #expect(FormatterRequest.maxTokens(forInput: "short") == 256)
        #expect(FormatterRequest.maxTokens(forInput: String(repeating: "a", count: 1000)) == 1000)
        #expect(FormatterRequest.maxTokens(forInput: String(repeating: "a", count: 9000)) == 4096)
    }

    @Test func deadlinesAreSixSecondsAndTenForSonnet() {
        #expect(FormatterRequest.deadline(for: gemini) == 6)
        #expect(FormatterRequest.deadline(for: haiku) == 6)
        #expect(FormatterRequest.deadline(for: sonnet) == 10)
    }

    @Test func responsesAreJoinedFromTheRightBlocks() {
        let anthropic = #"{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"One. "},{"type":"text","text":"Two."}]}"#
        #expect(FormatterRequest.parseAnthropic(Data(anthropic.utf8)) == "One. Two.")
        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"x","thought":true},{"text":"Answer."}]}}]}"#
        #expect(FormatterRequest.parseGemini(Data(gemini.utf8)) == "Answer.")
        #expect(FormatterRequest.parseGemini(Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8)) == nil)
        #expect(FormatterRequest.parseAnthropic(Data("[]".utf8)) == nil)
    }
}

private final class FormatterStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var calls: [URLRequest] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FormatterStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.append(request)
        guard let handler = Self.handler else { return }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@Suite("AI formatter", .serialized) struct AIFormatterTests {
    private let spoken = "um so i think we should ship it on wednesday no wait thursday after the review"
    private let cleaned = "I think we should ship it on Thursday after the review."

    private func formatter(_ id: String, key: String? = "k") -> AIFormatter {
        AIFormatter(model: ModelCatalog.languageModel(id: id)!, apiKey: { key },
                    session: FormatterStubURLProtocol.session(), diagnostics: Diagnostics(directory: nil))
    }

    /// URLProtocol sees the body as a stream.
    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private func reset() { FormatterStubURLProtocol.calls = []; FormatterStubURLProtocol.handler = nil }

    private func anthropicBody(_ text: String) -> Data {
        Data(#"{"content":[{"type":"text","text":"\#(text)"}]}"#.utf8)
    }

    @Test func aGoodAnswerReplacesTheTranscript() async {
        reset()
        FormatterStubURLProtocol.handler = { _ in (200, self.anthropicBody(self.cleaned)) }
        let outcome = await formatter("anthropic:claude-haiku-5-5").format(spoken, vocabulary: [])
        #expect(outcome == .formatted(cleaned))
    }

    @Test func aServerErrorDeliversTheTranscriptAsItWas() async {
        reset()
        FormatterStubURLProtocol.handler = { _ in (500, Data("boom".utf8)) }
        let outcome = await formatter("gemini:gemini-3.8-flash").format(spoken, vocabulary: [])
        #expect(outcome.text == nil)
        if case .failed(let reason) = outcome { #expect(reason == "HTTP 500" || reason.contains("500")) }
    }

    @Test func aGuardRejectionFallsBack() async {
        reset()
        FormatterStubURLProtocol.handler = { _ in (200, self.anthropicBody("Sure, here you go: done.")) }
        let outcome = await formatter("anthropic:claude-haiku-5-5").format(spoken, vocabulary: [])
        #expect(outcome.text == nil)
    }

    @Test func aThinkingRejectionIsRetriedOnceWithoutTheField() async {
        reset()
        FormatterStubURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as! [String: Any]
            if body["thinking"] != nil {
                return (400, Data(#"{"error":{"message":"thinking: not supported"}}"#.utf8))
            }
            return (200, self.anthropicBody(self.cleaned))
        }
        let outcome = await formatter("anthropic:claude-sonnet-5-5").format(spoken, vocabulary: [])
        #expect(outcome == .formatted(cleaned))
        #expect(FormatterStubURLProtocol.calls.count == 2)
    }

    @Test func anOtherBadRequestIsNotRetried() async {
        reset()
        FormatterStubURLProtocol.handler = { _ in (400, Data("bad".utf8)) }
        let outcome = await formatter("anthropic:claude-haiku-5-5").format(spoken, vocabulary: [])
        #expect(outcome.text == nil)
        #expect(FormatterStubURLProtocol.calls.count == 1)
    }

    @Test func shortTranscriptsAndMissingKeysNeverCallTheNetwork() async {
        reset()
        let none = await formatter("gemini:gemini-3.8-flash").format("hello there", vocabulary: [])
        #expect(none == .skipped("short transcript"))
        let noKey = await formatter("gemini:gemini-3.8-flash", key: nil).format(spoken, vocabulary: [])
        #expect(noKey.text == nil)
        #expect(FormatterStubURLProtocol.calls.isEmpty)
        #expect(!AIFormatter.shouldFormat("two words") && AIFormatter.shouldFormat("three whole words"))
    }

    @Test func cancellingTheDictationCancelsTheRequest() async {
        reset()
        FormatterStubURLProtocol.handler = { _ in
            Thread.sleep(forTimeInterval: 2)
            return (200, self.anthropicBody(self.cleaned))
        }
        let formatter = formatter("anthropic:claude-haiku-5-5")
        let spoken = spoken
        let started = Date()
        let task = Task { await formatter.format(spoken, vocabulary: []) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let outcome = await task.value
        #expect(outcome.text == nil)
        #expect(Date().timeIntervalSince(started) < 1.5)
    }
}

// MARK: - Keys

@Suite("Provider keys") struct ProviderKeyTests {
    @Test func eachProviderHasItsOwnKeychainAccount() {
        #expect(KeyProvider.allCases.map(\.account) == ["deepgram-key", "elevenlabs-key", "gemini-key", "anthropic-key"])
        #expect(DeepgramKeyStore.account == "deepgram-key")
        #expect(ProviderKeyStore.shared === ProviderKeyStore.deepgram)
    }

    @Test func theKeyTestsAreCheapAuthenticatedGets() {
        let gemini = ProviderKeyTester.request(provider: .gemini, key: " k ")!
        #expect(gemini.httpMethod == nil || gemini.httpMethod == "GET")
        #expect(gemini.value(forHTTPHeaderField: "x-goog-api-key") == "k")
        #expect(!gemini.url!.absoluteString.contains("k="))
        let anthropic = ProviderKeyTester.request(provider: .anthropic, key: "k")!
        #expect(anthropic.url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(anthropic.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let eleven = ProviderKeyTester.request(provider: .elevenLabs, key: "k")!
        #expect(eleven.url?.absoluteString == "https://api.elevenlabs.io/v1/models")
        #expect(eleven.value(forHTTPHeaderField: "xi-api-key") == "k")
    }

    @Test func statusesClassify() {
        #expect(ProviderKeyTester.classify(status: 200, body: "", milliseconds: 5) == .ok(milliseconds: 5))
        #expect(ProviderKeyTester.classify(status: 401, body: "", milliseconds: 5) == .rejected)
        #expect(ProviderKeyTester.classify(status: 400, body: "API_KEY_INVALID", milliseconds: 5) == .rejected)
        if case .failed = ProviderKeyTester.classify(status: 500, body: "", milliseconds: 5) {} else {
            Issue.record("expected failed")
        }
    }

    @Test func providersMapFromCatalogNames() {
        #expect(ModelCatalog.voiceModel(id: "elevenlabs:scribe_v2")?.keyProvider == .elevenLabs)
        #expect(ModelCatalog.voiceModel(id: "gemini-audio:gemini-3.8-flash")?.keyProvider == .gemini)
        #expect(ModelCatalog.voiceModel(id: "parakeet:v3")?.keyProvider == nil)
        #expect(ModelCatalog.languageModel(id: "anthropic:claude-haiku-5-5")?.keyProvider == .anthropic)
    }
}
