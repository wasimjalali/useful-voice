import Testing
import Foundation
@testable import UsefulVoiceCore

final class FakeRecorder: AudioRecording {
    var onLevel: ((Float) -> Void)?
    var onAutoStop: (() -> Void)?
    var startedURL: URL?
    var cancelled = false
    /// Bytes the fake "recording" writes. Defaults above the controller's
    /// minimum-audio guard so normal tests record a plausible clip; a test can
    /// lower it to exercise the too-short guard.
    var bytesToWrite = 8192
    /// Whether the fake recording "heard" speech. Defaults true so normal tests
    /// model a real dictation; a test sets it false to exercise the silence gate.
    var didCaptureSpeech = true
    /// Set to make `stop()` throw, exercising the failed-stop early return.
    var stopError: Error?
    var configuredSilenceTimeout: TimeInterval?
    /// Set to make `start()` throw, exercising the failed-start path.
    var startError: Error?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start(to url: URL) throws {
        if let startError { throw startError }
        startCount += 1
        startedURL = url
        try Data(count: bytesToWrite).write(to: url)
    }
    func stop() throws -> URL {
        if let stopError { throw stopError }
        guard let url = startedURL else { throw AudioRecorderError.notRecording }
        return url
    }
    func cancel() { cancelled = true; cancelCount += 1 }
    func updateSilenceTimeout(_ timeout: TimeInterval) {
        configuredSilenceTimeout = timeout
    }
}

struct FakeProvider: TranscriptionProvider {
    let name: String
    let result: Result<Transcript, Error>
    func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        try result.get()
    }
}

/// Records every hint it is sent, so a test can prove the whole provider chain
/// received the same captured hint rather than a per-provider re-read of live
/// settings.
final class CapturingProvider: TranscriptionProvider {
    let name: String
    let result: Result<Transcript, Error>
    private(set) var hints: [TranscriptionHint] = []
    init(name: String, result: Result<Transcript, Error>) {
        self.name = name
        self.result = result
    }
    func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        hints.append(hint)
        return try result.get()
    }
}

@Suite @MainActor final class DictationControllerTests {
    private let dir: URL
    private let store: RecordingStore
    private let recorder: FakeRecorder
    private var delivered: [String] = []
    private var deliveredModes: [DeliveryMode] = []
    private var outcomes: [DictationOutcome] = []
    /// Ordered log of state changes, records and outcomes, to prove ordering.
    private var timeline: [String] = []
    /// When true, deliver() parks its completion instead of calling it.
    private var holdDelivery = false
    private var parkedCompletions: [(DeliveryReport) -> Void] = []
    /// Overrides what the fake delivery reports; nil means pasted / copied by mode.
    private var deliveryResultOverride: DeliveryResult?
    /// When set, the fake delivery reports this failure.
    private var deliveryFailure: DeliveryFailure?
    private var states: [DictationState] = []
    private var records: [DictationRecord] = []
    private var suggested: [String] = []
    private var fellBack = false

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-\(UUID().uuidString)")
        store = try RecordingStore(directory: dir)
        recorder = FakeRecorder()
        delivered = []
        states = []
        records = []
        suggested = []
        fellBack = false
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeController(providers: [TranscriptionProvider],
                                now: @escaping () -> Date = { Date() },
                                isSecureInputActive: @escaping () -> Bool = { false })
        -> DictationController {
        let controller = DictationController(
            recorder: recorder,
            providers: { providers },
            store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            record: { [weak self] record in
                self?.records.append(record)
                self?.timeline.append("record")
            },
            now: now,
            isSecureInputActive: isSecureInputActive,
            frontmostApp: { [weak self] in
                self?.frontmostLookups += 1
                return self?.frontmostApp
            }
        )
        wire(controller)
        return controller
    }

    /// What the fake system reports as frontmost, at start and at delivery.
    private var frontmostApp: FrontmostApp? = FrontmostApp(id: "com.tinyspeck.slack", name: "Slack")
    private var frontmostLookups = 0

    /// Hooks the controller's callbacks into the suite's logs.
    private func wire(_ controller: DictationController) {
        controller.onStateChange = { [weak self] state in
            self?.states.append(state)
            self?.timeline.append("state:\(Self.label(of: state))")
        }
        controller.onOutcome = { [weak self] outcome in
            self?.outcomes.append(outcome)
            self?.timeline.append("outcome")
        }
    }

    private static func label(of state: DictationState) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .delivering: return "delivering"
        case .error(let error): return "error:\(error.kind)"
        }
    }

    private func fakeDeliver(_ text: String, _ mode: DeliveryMode,
                             _ done: @escaping (DeliveryReport) -> Void) {
        delivered.append(text)
        deliveredModes.append(mode)
        if holdDelivery {
            parkedCompletions.append(done)
            return
        }
        if let deliveryFailure { done(.failure(deliveryFailure)); return }
        done(.success(deliveryResultOverride ?? (mode == .paste ? .pasted : .copied)))
    }

    private func makeFormattingController(
        providers: [TranscriptionProvider],
        languagePin: LanguagePin = .auto,
        hint: (() -> TranscriptionHint)? = nil,
        rawTransform: ((String, FormattingContext) async -> FormattingResult)? = nil,
        format: @escaping (String, FormattingContext) async throws -> FormattingResult)
        -> DictationController {
        let controller = DictationController(
            recorder: recorder,
            providers: { providers },
            store: store,
            hint: hint ?? { TranscriptionHint(languagePin: languagePin, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            record: { [weak self] record in self?.records.append(record) },
            format: format,
            rawTransform: rawTransform,
            context: { FormattingContext(appBundleID: nil, dictionaryWords: [],
                                         language: languagePin) },
            suggestTerms: { [weak self] terms in self?.suggested.append(contentsOf: terms) },
            formatterUnavailable: { [weak self] in self?.fellBack = true })
        wire(controller)
        return controller
    }

    @Test func testUpdateRecordingSettingsAppliesWithoutRelaunch() {
        let controller = makeController(providers: [])

        controller.updateRecordingSettings(silenceTimeout: 35, recordingsToKeep: 4)

        #expect(recorder.configuredSilenceTimeout == 35)
        #expect(controller.recordingsToKeep == 4)
    }

    @Test func testFormatterAppliedAndTermsSuggested() async throws {
        let memoryID = UUID()
        let snippetID = UUID()
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hello world",
                                        detectedLanguage: "english", durationSeconds: 1)))
        let controller = makeFormattingController(providers: [provider]) { raw, _ in
            #expect(raw == "hello world")
            return FormattingResult(text: "Hello, world.", newTerms: ["Karko"],
                                    memoryHitIDs: [memoryID],
                                    snippetIDs: [snippetID])
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == ["Hello, world."])
        #expect(records.first?.text == "Hello, world.")
        #expect(records.first?.memoryHitIDs == [memoryID])
        #expect(records.first?.snippetIDs == [snippetID])
        #expect(suggested == ["Karko"])
        let sidecar = recorder.startedURL!.deletingPathExtension()
            .appendingPathExtension("txt")
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "hello world")
    }

    @Test func testRawModeSkipsFormatter() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hello world",
                                        detectedLanguage: nil, durationSeconds: nil)))
        let controller = makeFormattingController(providers: [provider]) { _, _ in
            Issue.record("formatter must not run in raw mode")
            return FormattingResult(text: "WRONG", newTerms: [])
        }
        controller.toggle()                 // start
        controller.toggle(rawMode: true)    // stop, raw
        await controller.toggleAndWait()
        #expect(delivered == ["hello world"])
    }

    @Test func testRawModeCanApplyLocalTransformWithoutFormatter() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "cloud code",
                                        detectedLanguage: nil, durationSeconds: nil)))
        let ruleID = UUID()
        let controller = makeFormattingController(
            providers: [provider],
            rawTransform: { raw, _ in
                #expect(raw == "cloud code")
                return FormattingResult(
                    text: "Claude Code",
                    newTerms: [],
                    mode: .raw,
                    replacementRuleIDs: [ruleID]
                )
            },
            format: { _, _ in
                Issue.record("formatter must not run in raw mode")
                return FormattingResult(text: "WRONG", newTerms: [])
            }
        )
        controller.toggle()
        controller.toggle(rawMode: true)
        await controller.toggleAndWait()
        #expect(delivered == ["Claude Code"])
        #expect(records.first?.mode == .raw)
        #expect(records.first?.replacementRuleIDs == [ruleID])
    }

    @Test func testFormatterFailureFallsBackToRaw() async throws {
        struct Boom: Error {}
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hello world",
                                        detectedLanguage: nil, durationSeconds: nil)))
        let controller = makeFormattingController(providers: [provider]) { _, _ in
            throw Boom()
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == ["hello world"])
        #expect(fellBack)
    }

    @Test func testFormatterFailureUsesLocalRawTransformWhenAvailable() async throws {
        struct Boom: Error {}
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "cloud code",
                                        detectedLanguage: nil, durationSeconds: nil)))
        let ruleID = UUID()
        let controller = makeFormattingController(
            providers: [provider],
            rawTransform: { _, _ in
                FormattingResult(
                    text: "Claude Code",
                    newTerms: [],
                    mode: .raw,
                    replacementRuleIDs: [ruleID]
                )
            },
            format: { _, _ in throw Boom() }
        )
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == ["Claude Code"])
        #expect(records.first?.mode == .raw)
        #expect(records.first?.replacementRuleIDs == [ruleID])
        #expect(fellBack)
    }

    @Test func testHappyPath() async throws {
        let provider = FakeProvider(
            name: "fake",
            result: .success(Transcript(text: "hello world",
                                        detectedLanguage: "english",
                                        durationSeconds: 1)))
        let controller = makeController(providers: [provider])

        controller.toggle() // start
        #expect(controller.state == .recording)
        #expect(recorder.startedURL != nil)

        await controller.toggleAndWait() // stop + process
        #expect(delivered == ["hello world"])
        #expect(controller.state == .idle)
        let sidecar = recorder.startedURL!
            .deletingPathExtension().appendingPathExtension("txt")
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "hello world")

        #expect(records.count == 1)
        #expect(records.first?.text == "hello world")
        // An unknown reported code is stored as reported — it is never
        // re-resolved or sent back to the provider.
        #expect(records.first?.language == "english")
        #expect(records.first?.provider == "fake")
        #expect(records.first?.audioPath == recorder.startedURL!.path)
    }

    @Test func testDurationFallsBackToMeasuredWhenProviderOmitsIt() async throws {
        // The Azure json path returns no duration; the cost meter must not read 0.
        let provider = FakeProvider(
            name: "fake",
            result: .success(Transcript(text: "hello", detectedLanguage: nil,
                                        durationSeconds: nil)))
        var ticks = [Date(timeIntervalSince1970: 100),
                     Date(timeIntervalSince1970: 107)]
        let controller = makeController(providers: [provider]) {
            ticks.isEmpty ? Date(timeIntervalSince1970: 107) : ticks.removeFirst()
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(records.first?.durationSeconds == 7)
    }

    @Test func testProviderDurationIsPreferredOverMeasured() async throws {
        let provider = FakeProvider(
            name: "fake",
            result: .success(Transcript(text: "hello", detectedLanguage: nil,
                                        durationSeconds: 3)))
        var ticks = [Date(timeIntervalSince1970: 100),
                     Date(timeIntervalSince1970: 999)]
        let controller = makeController(providers: [provider]) {
            ticks.isEmpty ? Date(timeIntervalSince1970: 999) : ticks.removeFirst()
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(records.first?.durationSeconds == 3)
    }

    @Test func testSecondaryProviderCanRecoverIfFirstFails() async throws {
        let failing = FakeProvider(name: "primary",
                                   result: .failure(ProviderError.http(500, "boom")))
        let working = FakeProvider(
            name: "secondary",
            result: .success(Transcript(text: "rescued",
                                        detectedLanguage: nil,
                                        durationSeconds: nil)))
        let controller = makeController(providers: [failing, working])

        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == ["rescued"])
        #expect(controller.state == .idle)
    }

    @Test func testRetryLastRecoversAfterAllProvidersFail() async throws {
        // Spec section 5: all providers fail -> audio retained, one-click retry.
        var attempt = 0
        let failing = FakeProvider(name: "p1",
                                   result: .failure(ProviderError.http(500, "boom")))
        let working = FakeProvider(
            name: "p2",
            result: .success(Transcript(text: "rescued on retry",
                                        detectedLanguage: nil, durationSeconds: nil)))
        let controller = DictationController(
            recorder: recorder,
            providers: { attempt += 1; return attempt == 1 ? [failing] : [working] },
            store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            record: { [weak self] record in self?.records.append(record) })
        wire(controller)

        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == [])
        #expect(controller.canRetry)

        await controller.retryLastAndWait()
        #expect(delivered == ["rescued on retry"])
        #expect(!controller.canRetry)
    }

    @Test func testSuccessClearsRetry() async throws {
        let provider = FakeProvider(
            name: "fake",
            result: .success(Transcript(text: "hi", detectedLanguage: nil,
                                        durationSeconds: nil)))
        let controller = makeController(providers: [provider])
        controller.toggle()
        await controller.toggleAndWait()
        #expect(!controller.canRetry)
    }

    @Test func testAllProvidersFailKeepsAudioAndReportsError() async throws {
        let failing = FakeProvider(name: "only",
                                   result: .failure(ProviderError.http(500, "boom")))
        let controller = makeController(providers: [failing])

        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == [])
        guard case .error = controller.state else {
            Issue.record("expected error state, got \(controller.state)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: recorder.startedURL!.path))
    }

    @Test func testEmptyTranscriptIsDiscardedNothingInsertedOrBilled() async throws {
        // Spec section 5: no speech detected -> discard, nothing inserted, nothing
        // billed beyond the STT call. A whitespace-only result must not be
        // formatted, recorded, or delivered (delivery would also clobber clipboard).
        let provider = FakeProvider(
            name: "fake",
            result: .success(Transcript(text: "   \n ", detectedLanguage: nil,
                                        durationSeconds: nil)))
        var formatterRan = false
        let controller = makeFormattingController(providers: [provider]) { _, _ in
            formatterRan = true
            return FormattingResult(text: "WRONG", newTerms: [])
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == [])
        #expect(records.isEmpty)
        #expect(!formatterRan)
        guard case .error(let error) = controller.state else {
            Issue.record("expected a no-speech notice, got \(controller.state)")
            return
        }
        #expect(error.kind == .noSpeech)
        #expect(error.message.lowercased().contains("speech"))
    }

    @Test func testSilentRecordingIsRejectedBeforeUpload() async throws {
        // The user held the key but said nothing. Without this gate, the silent
        // clip is uploaded and Whisper echoes its dictionary prompt-bias back as a
        // fake transcript, which gets formatted, pasted and left on the clipboard.
        // Nothing must be transcribed, formatted, recorded, delivered or retried.
        recorder.didCaptureSpeech = false
        let provider = FakeProvider(
            name: "fake",
            result: .success(Transcript(text: "Karko AI, Supabase, Stripe",
                                        detectedLanguage: nil, durationSeconds: nil)))
        var formatterRan = false
        let controller = makeFormattingController(providers: [provider]) { _, _ in
            formatterRan = true
            return FormattingResult(text: "WRONG", newTerms: [])
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == [])
        #expect(records.isEmpty)
        #expect(!formatterRan)
        #expect(!controller.canRetry)
        guard case .error(let error) = controller.state else {
            Issue.record("expected a no-speech notice, got \(controller.state)")
            return
        }
        #expect(error.kind == .noSpeech)
        #expect(error.message.lowercased().contains("speech"))
    }

    @Test func testTooShortRecordingIsRejectedBeforeUpload() async throws {
        // A header-only / near-empty WAV must not be uploaded (the provider 400s
        // on it). The user gets a plain "too short" notice; nothing is
        // transcribed, recorded, delivered, or kept for retry.
        recorder.bytesToWrite = 100
        let provider = FakeProvider(
            name: "fake",
            result: .success(Transcript(text: "must not be used",
                                        detectedLanguage: nil, durationSeconds: nil)))
        let controller = makeController(providers: [provider])
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == [])
        #expect(records.isEmpty)
        #expect(!controller.canRetry)
        guard case .error(let error) = controller.state else {
            Issue.record("expected a too-short notice, got \(controller.state)")
            return
        }
        #expect(error.kind == .tooShort)
        #expect(error.message.lowercased().contains("short"))
    }

    @Test func testProviderErrorBodyIsSurfaced() async throws {
        // The provider's own error text must reach the user so a genuine failure
        // is distinguishable from an opaque status code.
        let failing = FakeProvider(
            name: "only",
            result: .failure(ProviderError.http(400, "audio file is too short")))
        let controller = makeController(providers: [failing])
        controller.toggle()
        await controller.toggleAndWait()
        guard case .error(let error) = controller.state else {
            Issue.record("expected error state, got \(controller.state)")
            return
        }
        #expect(error.kind == .providerFailed)
        #expect(error.message.contains("400"))
        #expect(error.message.contains("audio file is too short"))
    }

    @Test func testCancelDiscardsRecording() {
        let provider = FakeProvider(
            name: "fake",
            result: .success(Transcript(text: "x", detectedLanguage: nil,
                                        durationSeconds: nil)))
        let controller = makeController(providers: [provider])

        controller.toggle()
        controller.cancel()
        #expect(recorder.cancelled)
        #expect(controller.state == .idle)
        #expect(delivered == [])
    }

    @Test func testSecureInputRefusesRecording() {
        // Spec section 5: a password field is active -> refuse dictation with a
        // clear message instead of recording and pasting into the secure field.
        let provider = FakeProvider(
            name: "fake",
            result: .success(Transcript(text: "secret", detectedLanguage: nil,
                                        durationSeconds: nil)))
        let controller = makeController(providers: [provider],
                                        isSecureInputActive: { true })
        controller.toggle()
        #expect(recorder.startedURL == nil)
        guard case .error(let error) = controller.state else {
            Issue.record("expected a secure-field refusal, got \(controller.state)")
            return
        }
        #expect(error.kind == .secureField)
        #expect(error.fix == nil)
        #expect(error.message.lowercased().contains("secure"))
        #expect(delivered == [])
    }

    @Test func testFormattedResultRecordsFormattedMode() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hello", detectedLanguage: nil,
                                        durationSeconds: nil)))
        let controller = makeFormattingController(providers: [provider]) { raw, _ in
            FormattingResult(text: raw, newTerms: [])
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(records.first?.mode == .formatted)
    }

    @Test func testRawModeRecordsRawMode() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hello", detectedLanguage: nil,
                                        durationSeconds: nil)))
        let controller = makeFormattingController(providers: [provider]) { raw, _ in
            FormattingResult(text: raw, newTerms: [])
        }
        controller.toggle()
        controller.toggle(rawMode: true)
        await controller.toggleAndWait()
        #expect(records.first?.mode == .raw)
    }

    @Test func testFormatterFailureRecordsRawMode() async throws {
        struct Boom: Error {}
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hello", detectedLanguage: nil,
                                        durationSeconds: nil)))
        let controller = makeFormattingController(providers: [provider]) { _, _ in
            throw Boom()
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(records.first?.mode == .raw)
    }

    @Test func testRetryUsesContextCapturedAtDictationTime() async throws {
        // The bug: retryLast resolved the frontmost app at retry time, so a
        // retry clicked from Useful Voice's own window formatted for Useful Voice, not for
        // the app the user dictated into.
        var attempt = 0
        let failing = FakeProvider(name: "p1",
                                   result: .failure(ProviderError.http(500, "boom")))
        let working = FakeProvider(name: "p2",
            result: .success(Transcript(text: "ok", detectedLanguage: nil,
                                        durationSeconds: nil)))
        var bundleAtFormat: String?
        var contextCalls = 0
        let controller = DictationController(
            recorder: recorder,
            providers: { attempt += 1; return attempt == 1 ? [failing] : [working] },
            store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            record: { [weak self] record in self?.records.append(record) },
            format: { _, ctx in
                bundleAtFormat = ctx.appBundleID
                return FormattingResult(text: "formatted", newTerms: [])
            },
            context: {
                contextCalls += 1
                return FormattingContext(
                    appBundleID: contextCalls == 1 ? "com.target.app" : "ai.karko.sadaa",
                    dictionaryWords: [], language: .auto)
            })
        controller.toggle()
        await controller.toggleAndWait()
        #expect(controller.canRetry)

        await controller.retryLastAndWait()
        #expect(delivered == ["formatted"])
        #expect(bundleAtFormat == "com.target.app")
    }

    @Test func testNoProvidersConfigured() async {
        let controller = makeController(providers: [])
        controller.toggle()
        await controller.toggleAndWait()
        guard case .error(let error) = controller.state else {
            Issue.record("expected error state")
            return
        }
        #expect(error.kind == .noProvider)
        #expect(error.fix == .openEngineSettings)
        #expect(error.message.contains("provider"))
    }

    // MARK: - Detected language

    /// What the provider detected decides the processing language: a regional
    /// tag the catalogue does not carry resolves to its base language, while
    /// history stores the raw code verbatim.
    @Test func testRegionalDetectionScopesProcessingButIsStoredRaw() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hallo welt",
                                        detectedLanguage: "de-DE", durationSeconds: 1)))
        var languageAtFormat: LanguagePin?
        let controller = makeFormattingController(providers: [provider]) { raw, ctx in
            languageAtFormat = ctx.language
            return FormattingResult(text: raw, newTerms: [])
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(languageAtFormat == .de)
        #expect(records.first?.language == "de-DE")
    }

    /// `de-CH` is its own catalogue row — Swiss German, not a restyling of
    /// German — so it must keep its region rather than collapse the way
    /// `de-DE` does.
    @Test func testCatalogueRegionalDetectionKeepsItsRegion() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "gruezi welt",
                                        detectedLanguage: "de-CH", durationSeconds: 1)))
        var languageAtFormat: LanguagePin?
        let controller = makeFormattingController(providers: [provider]) { raw, ctx in
            languageAtFormat = ctx.language
            return FormattingResult(text: raw, newTerms: [])
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(languageAtFormat == LanguagePin(rawValue: "de-CH"))
        #expect(records.first?.language == "de-CH")
    }

    /// Wiring-level: the format closure runs the real deterministic memory pass
    /// on `ctx.language`, the same thing the app's memory closure does. With an
    /// auto pin and a German detection, a German-scoped term must fire while an
    /// English-scoped one must not — under the old auto scope, both would.
    @Test func testDetectedLanguageScopesMemoryByResolvedLanguage() async throws {
        let snapshot = LanguageMemorySnapshot(
            terms: [
                MemoryTerm(phrase: "Kubernetes", pronunciations: ["kubernets"],
                           language: .de),
                MemoryTerm(phrase: "TypeScript", pronunciations: ["type script"],
                           language: .en),
            ])
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "deploy kubernets and type script",
                                        detectedLanguage: "de-DE", durationSeconds: 1)))
        let controller = makeFormattingController(providers: [provider]) { raw, ctx in
            LanguageMemoryPostProcessor.rawResult(
                for: raw, snapshot: snapshot,
                language: MemoryLanguage(languagePin: ctx.language))
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == ["deploy Kubernetes and type script"])
        #expect(records.first?.memoryHitIDs == [snapshot.terms[0].id])
        #expect(records.first?.language == "de-DE")
    }

    /// An unknown detection is processed as auto — every language's rules
    /// participate, which is permissive rather than wrong-language — but
    /// history records what the provider actually reported.
    @Test func testUnknownDetectionProcessesAsAutoAndStoresRaw() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hallo",
                                        detectedLanguage: "is", durationSeconds: 1)))
        var languageAtFormat: LanguagePin?
        let controller = makeFormattingController(providers: [provider]) { raw, ctx in
            languageAtFormat = ctx.language
            return FormattingResult(text: raw, newTerms: [])
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(languageAtFormat == .auto)
        #expect(records.first?.language == "is")
    }

    /// A pinned dictation whose response carries no detected_language stores
    /// the requested pin — previously nil — and processes under it.
    @Test func testAbsentDetectionStoresAndAppliesTheRequestedPin() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "konnichiwa",
                                        detectedLanguage: nil, durationSeconds: 1)))
        var languageAtFormat: LanguagePin?
        let controller = makeFormattingController(
            providers: [provider],
            languagePin: LanguagePin(rawValue: "ja")) { raw, ctx in
            languageAtFormat = ctx.language
            return FormattingResult(text: raw, newTerms: [])
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(languageAtFormat == LanguagePin(rawValue: "ja"))
        #expect(records.first?.language == "ja")
    }

    /// A whitespace-only detection is not a detection: the requested pin is
    /// stored and used, and nothing empty reaches history.
    @Test func testWhitespaceOnlyDetectionStoresTheRequestedPin() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hallo",
                                        detectedLanguage: "   ", durationSeconds: 1)))
        let controller = makeFormattingController(
            providers: [provider], languagePin: .de) { raw, _ in
            FormattingResult(text: raw, newTerms: [])
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(records.first?.language == "de")
    }

    /// A malformed detection must not forge a history row or a log line: the
    /// stored code is stripped to tag characters (letters and hyphen), so a
    /// newline cannot inject a fake record or diagnostic entry.
    @Test func testDetectedCodeIsSanitizedBeforeStorage() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hallo",
                                        detectedLanguage: "de\n-DE injected",
                                        durationSeconds: 1)))
        let controller = makeFormattingController(providers: [provider]) { raw, _ in
            FormattingResult(text: raw, newTerms: [])
        }
        controller.toggle()
        await controller.toggleAndWait()
        let stored = try #require(records.first?.language)
        #expect(stored == "de-DEinjected")
        #expect(stored.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "-") })
    }

    /// `hint()` reads live settings: called per provider, a pin change
    /// mid-chain would hand each provider a different request. The controller
    /// captures the hint once and hands that same value to the whole chain.
    @Test func testEveryProviderReceivesTheSameCapturedHint() async throws {
        let first = CapturingProvider(name: "primary",
                                      result: .failure(ProviderError.http(500, "boom")))
        let second = CapturingProvider(name: "secondary",
            result: .success(Transcript(text: "rescued", detectedLanguage: nil,
                                        durationSeconds: nil)))
        var hintCalls = 0
        let controller = makeFormattingController(
            providers: [first, second],
            hint: {
                // Alternate pins on every call so a per-provider re-read is
                // observable: the second provider would see `de`, not `en`.
                hintCalls += 1
                return TranscriptionHint(
                    languagePin: hintCalls % 2 == 1 ? .en : .de,
                    dictionaryWords: [])
            },
            format: { raw, _ in FormattingResult(text: raw, newTerms: []) }
        )
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == ["rescued"])
        #expect(first.hints.count == 1)
        #expect(second.hints.count == 1)
        #expect(first.hints.first?.languagePin == .en)
        #expect(second.hints.first?.languagePin == .en)
    }

    /// Regression: a raw-mode dictation whose providers all failed used to
    /// leave `pendingRawMode` set. The flag can only be *observed* stale by
    /// `retryLast()` — the next dictation's own `toggle(rawMode:)` stop
    /// rewrites it before `process()` reads it. So the guard must end with a
    /// retry, not a fresh dictation: without the fix, the retried dictation
    /// silently runs through rawTransform instead of the formatter.
    @Test func testFailedRawModeDoesNotLeakIntoRetry() async throws {
        let failing = FakeProvider(name: "p1",
                                   result: .failure(ProviderError.http(500, "boom")))
        let working = FakeProvider(name: "p2",
            result: .success(Transcript(text: "rescued", detectedLanguage: nil,
                                        durationSeconds: nil)))
        var providersWork = false
        var formatRan = false
        var rawTransformRan = false
        let controller = DictationController(
            recorder: recorder,
            providers: { providersWork ? [working] : [failing] },
            store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            record: { [weak self] record in self?.records.append(record) },
            format: { raw, _ in
                formatRan = true
                return FormattingResult(text: "formatted: \(raw)", newTerms: [])
            },
            rawTransform: { raw, _ in
                rawTransformRan = true
                return FormattingResult(text: "raw: \(raw)", newTerms: [], mode: .raw)
            })
        controller.toggle()                  // start
        controller.toggle(rawMode: true)     // stop, raw — providers all fail
        await controller.toggleAndWait()
        #expect(delivered == [])
        #expect(!formatRan && !rawTransformRan)
        #expect(controller.canRetry)

        providersWork = true
        await controller.retryLastAndWait()
        #expect(formatRan)
        #expect(!rawTransformRan)
        #expect(delivered == ["formatted: rescued"])
    }

    /// The formatter-failure fallback runs the same resolved context as the
    /// formatter path: a detected `de-DE` scopes the raw transform as `de` too.
    @Test func testFormatterFailureFallbackUsesTheResolvedLanguage() async throws {
        struct Boom: Error {}
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hallo",
                                        detectedLanguage: "de-DE", durationSeconds: 1)))
        var languageAtFallback: LanguagePin?
        let controller = makeFormattingController(
            providers: [provider],
            rawTransform: { raw, ctx in
                languageAtFallback = ctx.language
                return FormattingResult(text: raw, newTerms: [], mode: .raw)
            },
            format: { _, _ in throw Boom() }
        )
        controller.toggle()
        await controller.toggleAndWait()
        #expect(languageAtFallback == .de)
        #expect(records.first?.language == "de-DE")
    }

    /// An auto pin whose response carries no detected_language stores the
    /// requested mode itself: `"auto"`, not nil and not a re-resolved value.
    @Test func testAutoPinWithAbsentDetectionStoresAuto() async throws {
        let provider = FakeProvider(name: "fake",
            result: .success(Transcript(text: "hello",
                                        detectedLanguage: nil, durationSeconds: 1)))
        var languageAtFormat: LanguagePin?
        let controller = makeFormattingController(
            providers: [provider], languagePin: .auto) { raw, ctx in
            languageAtFormat = ctx.language
            return FormattingResult(text: raw, newTerms: [])
        }
        controller.toggle()
        await controller.toggleAndWait()
        #expect(languageAtFormat == .auto)
        #expect(records.first?.language == "auto")
    }

    /// Retry must re-send the request the original dictation made: the pin and
    /// bias list captured at record time, not whatever `hint()` would read now.
    /// After the pin changes post-failure, the provider still receives pin A.
    @Test func testRetrySendsTheOriginalCapturedHintAfterPinChange() async throws {
        let failing = CapturingProvider(name: "p1",
            result: .failure(ProviderError.http(500, "boom")))
        let working = CapturingProvider(name: "p2",
            result: .success(Transcript(text: "rescued",
                                        detectedLanguage: nil, durationSeconds: nil)))
        var attempt = 0
        // Live settings: the pin flips after the first dictation fails.
        var livePin: LanguagePin = .en
        let controller = DictationController(
            recorder: recorder,
            providers: { attempt += 1; return attempt == 1 ? [failing] : [working] },
            store: store,
            hint: {
                TranscriptionHint(languagePin: livePin,
                                  dictionaryWords: ["live-\(livePin.rawValue)"])
            },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            record: { [weak self] record in self?.records.append(record) },
            context: {
                FormattingContext(appBundleID: nil,
                                  dictionaryWords: ["ctx-\(livePin.rawValue)"],
                                  language: livePin)
            })

        controller.toggle()
        await controller.toggleAndWait()
        #expect(controller.canRetry)
        #expect(failing.hints.first?.languagePin == .en)

        // The user pins a different language before clicking Retry.
        livePin = .de
        await controller.retryLastAndWait()
        #expect(delivered == ["rescued"])
        // The retry re-sent the original request: pin A and its bias list, not
        // the live pin B `hint()` would have produced.
        let retryHint = try #require(working.hints.first)
        #expect(retryHint.languagePin == .en)
        #expect(retryHint.dictionaryWords == ["ctx-en"])
    }

    /// Regression: a raw-mode dictation that early-returns on the silent path
    /// used to leave `pendingRawMode` set. The next dictation's own
    /// `toggle(rawMode:)` stop rewrites the flag before `process()` reads it,
    /// so the only way to observe the stale value is `retryLast()` — the raw
    /// intent dies with the dictation that never reached process(), and the
    /// retried failure must still run the formatter.
    @Test func testSilentRawModeDoesNotLeakIntoRetry() async throws {
        let failing = FakeProvider(name: "p1",
                                   result: .failure(ProviderError.http(500, "boom")))
        let working = FakeProvider(name: "p2",
            result: .success(Transcript(text: "rescued",
                                        detectedLanguage: nil, durationSeconds: nil)))
        var providersWork = false
        var formatRan = false
        var rawTransformRan = false
        let controller = DictationController(
            recorder: recorder,
            providers: { providersWork ? [working] : [failing] },
            store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            record: { [weak self] record in self?.records.append(record) },
            format: { raw, _ in
                formatRan = true
                return FormattingResult(text: "formatted: \(raw)", newTerms: [])
            },
            rawTransform: { raw, _ in
                rawTransformRan = true
                return FormattingResult(text: "raw: \(raw)", newTerms: [], mode: .raw)
            })

        // Seed a retrievable failure so a later stale flag has a consumer.
        controller.toggle()
        await controller.toggleAndWait()
        #expect(controller.canRetry)

        recorder.didCaptureSpeech = false
        controller.toggle()                  // start
        controller.toggle(rawMode: true)     // stop, raw — silent: early return
        await controller.toggleAndWait()
        #expect(delivered == [])
        #expect(!formatRan && !rawTransformRan)

        providersWork = true
        await controller.retryLastAndWait()
        #expect(formatRan)
        #expect(!rawTransformRan)
        #expect(delivered == ["formatted: rescued"])
    }

    /// Same leak on the failed-stop path: `recorder.stop()` throws before
    /// process() consumes the flag, so it must be cleared at the early return
    /// or `retryLast()` reprocesses the retained failure through rawTransform.
    @Test func testFailedStopRawModeDoesNotLeakIntoRetry() async throws {
        struct StopFailed: Error {}
        let failing = FakeProvider(name: "p1",
                                   result: .failure(ProviderError.http(500, "boom")))
        let working = FakeProvider(name: "p2",
            result: .success(Transcript(text: "rescued",
                                        detectedLanguage: nil, durationSeconds: nil)))
        var providersWork = false
        var formatRan = false
        var rawTransformRan = false
        let controller = DictationController(
            recorder: recorder,
            providers: { providersWork ? [working] : [failing] },
            store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            record: { [weak self] record in self?.records.append(record) },
            format: { raw, _ in
                formatRan = true
                return FormattingResult(text: "formatted: \(raw)", newTerms: [])
            },
            rawTransform: { raw, _ in
                rawTransformRan = true
                return FormattingResult(text: "raw: \(raw)", newTerms: [], mode: .raw)
            })

        controller.toggle()
        await controller.toggleAndWait()
        #expect(controller.canRetry)

        recorder.stopError = StopFailed()
        controller.toggle()                  // start
        controller.toggle(rawMode: true)     // stop, raw — stop() throws
        await controller.toggleAndWait()
        #expect(delivered == [])
        #expect(!formatRan && !rawTransformRan)

        recorder.stopError = nil
        providersWork = true
        await controller.retryLastAndWait()
        #expect(formatRan)
        #expect(!rawTransformRan)
        #expect(delivered == ["formatted: rescued"])
    }

    // MARK: - Source, delivery mode and outcomes (see DictationEnablersTests.swift
    // for the list of failure modes these cover)

    private func okProvider(_ text: String = "hello world") -> TranscriptionProvider {
        FakeProvider(name: "fake",
                     result: .success(Transcript(text: text, detectedLanguage: nil,
                                                 durationSeconds: 1)))
    }

    private func failingProvider(_ error: ProviderError) -> TranscriptionProvider {
        FakeProvider(name: "bad", result: .failure(error))
    }

    /// Lets main-queue work (the recorder's auto-stop hop) run.
    private func drainMainQueue() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    @Test func testWindowStartDeliversByCopyWithoutAppName() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle(source: .window)
        await controller.toggleAndWait()
        #expect(deliveredModes == [.copy])
        #expect(outcomes == [.delivered(words: 2, mode: .copied, appName: nil)])
        // A window dictation has no target app to look up.
        #expect(frontmostLookups == 0)
    }

    @Test func testHotkeyStartPastesAndNamesTheApp() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        await controller.toggleAndWait()
        #expect(deliveredModes == [.paste])
        #expect(outcomes == [.delivered(words: 2, mode: .pasted, appName: "Slack")])
        #expect(frontmostLookups == 2)   // at start, and again at delivery
    }

    @Test func testStopToggleNeverChangesTheSourceChosenAtStart() async throws {
        // Started in the window, stopped by the hotkey: still copies.
        let controller = makeController(providers: [okProvider()])
        controller.toggle(source: .window)
        controller.toggle(source: .hotkey)
        await controller.awaitProcessing()
        #expect(deliveredModes == [.copy])

        // Started by the hotkey, stopped from the window: still pastes.
        controller.toggle(source: .hotkey)
        controller.toggle(source: .window)
        await controller.awaitProcessing()
        #expect(deliveredModes == [.copy, .paste])
    }

    @Test func testAutoStopKeepsTheSourceChosenAtStart() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle(source: .window)
        recorder.onAutoStop?()
        try await drainMainQueue()
        await controller.awaitProcessing()
        #expect(deliveredModes == [.copy])
        #expect(outcomes.count == 1)
    }

    @Test func testAutoStopAfterManualStopDoesNotStartAnotherRecording() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        controller.toggle()                    // manual stop: now transcribing
        recorder.onAutoStop?()                 // late auto-stop from the old session
        try await drainMainQueue()
        await controller.awaitProcessing()
        #expect(recorder.startCount == 1)
        #expect(controller.state == .idle)
        #expect(delivered == ["hello world"])

        // And the same late call after the dictation fully finished.
        recorder.onAutoStop?()
        try await drainMainQueue()
        #expect(recorder.startCount == 1)
        #expect(controller.state == .idle)
    }

    @Test func testSourceDoesNotLeakIntoTheNextDictation() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle(source: .window)
        await controller.toggleAndWait()
        controller.toggle(source: .hotkey)
        await controller.toggleAndWait()
        #expect(deliveredModes == [.copy, .paste])
        #expect(outcomes.last == .delivered(words: 2, mode: .pasted, appName: "Slack"))
    }

    @Test func testSourceDoesNotLeakPastAWindowDictationThatFailed() async throws {
        var chain: [TranscriptionProvider] = [failingProvider(.http(500, "boom"))]
        let controller = DictationController(
            recorder: recorder, providers: { chain }, store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            frontmostApp: { FrontmostApp(id: "com.apple.mail", name: "Mail") })
        wire(controller)
        controller.toggle(source: .window)
        await controller.toggleAndWait()          // fails, audio retained
        guard case .error = controller.state else {
            Issue.record("expected the window dictation to fail"); return
        }
        chain = [okProvider()]
        controller.toggle(source: .hotkey)         // a fresh hotkey dictation
        await controller.toggleAndWait()
        #expect(deliveredModes == [.paste])
        #expect(outcomes == [.delivered(words: 2, mode: .pasted, appName: "Mail")])
    }

    @Test func testStartFailureDoesNotCaptureASource() async throws {
        let controller = makeController(providers: [okProvider()])
        recorder.startError = AudioRecorderError.noInputDevice
        controller.toggle(source: .window)
        guard case .error(let error) = controller.state else {
            Issue.record("expected a start failure"); return
        }
        #expect(error.kind == .micUnavailable)
        #expect(error.fix == .openMicrophoneSettings)
        #expect(error.message.hasPrefix("Couldn't start recording: "))
        recorder.startError = nil
        controller.toggle(source: .hotkey)
        await controller.toggleAndWait()
        #expect(deliveredModes == [.paste])
    }

    @Test func testRetryAlwaysCopiesWhateverStartedTheOriginal() async throws {
        for source in [DictationSource.hotkey, .window] {
            deliveredModes = []
            outcomes = []
            var attempt = 0
            let controller = DictationController(
                recorder: recorder,
                providers: {
                    attempt += 1
                    return attempt == 1 ? [self.failingProvider(.http(500, "boom"))]
                                       : [self.okProvider("rescued today")]
                },
                store: store,
                hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
                recordingsToKeep: 10,
                deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
                frontmostApp: { FrontmostApp(id: "com.tinyspeck.slack", name: "Slack") })
            wire(controller)
            controller.toggle(source: source)
            await controller.toggleAndWait()
            #expect(controller.canRetry)
            await controller.retryLastAndWait()
            #expect(deliveredModes == [.copy])
            #expect(outcomes == [.delivered(words: 2, mode: .copied, appName: nil)])
        }
    }

    @Test func testOutcomeIsPublishedAfterTheRecordAndBeforeIdle() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        await controller.toggleAndWait()
        #expect(timeline == ["state:recording", "state:transcribing", "record",
                             "state:delivering", "outcome", "state:idle"])
    }

    @Test func testDeliveryResultIsPassedThroughToTheOutcome() async throws {
        deliveryResultOverride = .copiedNotPasted
        let controller = makeController(providers: [okProvider("one two three")])
        controller.toggle()
        await controller.toggleAndWait()
        #expect(outcomes == [.delivered(words: 3, mode: .copiedNotPasted, appName: "Slack")])
        #expect(controller.state == .idle)
    }

    @Test func testWordCountIsWhitespaceSeparatedTokens() {
        #expect(DictationOutcome.wordCount(of: "hallo   Welt\nwie geht's") == 4)
        #expect(DictationOutcome.wordCount(of: "سلام دنیا، حال شما چطور است؟") == 6)
        #expect(DictationOutcome.wordCount(of: "  one\ttwo  ") == 2)
        #expect(DictationOutcome.wordCount(of: "") == 0)
    }

    @Test func testDeliveryCompletionFiresTheOutcomeOnlyOnce() async throws {
        holdDelivery = true
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        await controller.toggleAndWait()
        #expect(controller.state == .delivering)
        #expect(parkedCompletions.count == 1)

        parkedCompletions[0](.success(.pasted))
        parkedCompletions[0](.success(.pasted))          // a second call of the same completion
        #expect(outcomes.count == 1)
        #expect(controller.state == .idle)
        #expect(states.filter { $0 == .idle }.count == 1)
    }

    @Test func testStaleCompletionCannotEndTheNextDeliveryOrFireItsOutcome() async throws {
        holdDelivery = true
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        await controller.toggleAndWait()
        let first = parkedCompletions[0]
        first(.success(.pasted))
        #expect(outcomes.count == 1)

        controller.toggle()
        await controller.toggleAndWait()
        #expect(controller.state == .delivering)
        first(.success(.pasted))                          // late duplicate of the first dictation
        #expect(controller.state == .delivering)
        #expect(outcomes.count == 1)

        parkedCompletions[1](.success(.pasted))
        #expect(outcomes.count == 2)
        #expect(controller.state == .idle)
    }

    @Test func testEscDuringDeliveringIsIgnored() async throws {
        holdDelivery = true
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        await controller.toggleAndWait()
        controller.cancel()
        #expect(controller.state == .delivering)
        #expect(recorder.cancelCount == 0)
        #expect(outcomes.isEmpty)
        parkedCompletions[0](.success(.pasted))
        #expect(outcomes == [.delivered(words: 2, mode: .pasted, appName: "Slack")])
    }

    @Test func testNewToggleIsIgnoredWhileDelivering() async throws {
        holdDelivery = true
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        await controller.toggleAndWait()
        controller.toggle(source: .window)
        #expect(controller.state == .delivering)
        #expect(recorder.startCount == 1)
    }

    @Test func testRetryWhileRecordingIsIgnored() async throws {
        let controller = makeController(providers: [failingProvider(.http(500, "boom"))])
        controller.toggle()
        await controller.toggleAndWait()
        #expect(controller.canRetry)
        controller.toggle()                     // a new recording from the error state
        #expect(controller.state == .recording)
        controller.retryLast()
        #expect(controller.state == .recording)
        #expect(delivered.isEmpty)
    }

    @Test func testCancelPublishesOneCancelledOutcomeBeforeIdle() {
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        controller.cancel()
        controller.cancel()                     // a second Esc
        #expect(outcomes == [.cancelled])
        #expect(timeline == ["state:recording", "outcome", "state:idle"])
    }

    @Test func testCancelOutsideRecordingPublishesNothing() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.cancel()                     // idle
        #expect(outcomes.isEmpty)
        controller.toggle()
        controller.toggle()                     // transcribing
        controller.cancel()
        await controller.awaitProcessing()
        #expect(outcomes == [.delivered(words: 2, mode: .pasted, appName: "Slack")])
    }

    @Test func testAutoStopAfterCancelIsIgnored() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        controller.cancel()
        recorder.onAutoStop?()
        try await drainMainQueue()
        #expect(controller.state == .idle)
        #expect(recorder.startCount == 1)
        #expect(delivered.isEmpty)
    }

    @Test func testNoOutcomeFiresForErrors() async throws {
        let controller = makeController(providers: [failingProvider(.http(500, "boom"))])
        controller.toggle()
        await controller.toggleAndWait()
        #expect(outcomes.isEmpty)
    }

    // MARK: Typed errors

    @Test func testTranscriptionFailuresAreTypedWithTheirFixAndTheOldMessage() async throws {
        let cases: [(ProviderError, DictationError.Kind, DictationFix?, String)] = [
            (.http(401, "invalid credentials"), .keyRejected, .openEngineSettings,
             "Transcription failed: HTTP 401: invalid credentials"),
            (.http(403, "forbidden"), .keyRejected, .openEngineSettings,
             "Transcription failed: HTTP 403: forbidden"),
            (.http(500, "boom"), .providerFailed, .retry,
             "Transcription failed: HTTP 500: boom"),
            (.http(429, "slow down"), .providerFailed, .retry,
             "Transcription failed: HTTP 429: slow down"),
            (.outOfCredits("x"), .outOfCredits, .openEngineSettings,
             "Transcription failed: Your Deepgram account is out of credits. Add credits, then try again."),
            (.badResponse, .providerFailed, .retry,
             "Transcription failed: unreadable provider response"),
            (.notConfigured("Enter your Deepgram API key."), .noProvider, .openEngineSettings,
             "Transcription failed: Enter your Deepgram API key."),
            (.timedOut, .timedOut, .retry, "Transcription failed: timed out"),
            (.transport(URLError(.notConnectedToInternet)), .offline, .retry,
             "Transcription failed: \(URLError(.notConnectedToInternet).localizedDescription)"),
            (.transport(URLError(.networkConnectionLost)), .offline, .retry,
             "Transcription failed: \(URLError(.networkConnectionLost).localizedDescription)"),
            (.transport(URLError(.timedOut)), .timedOut, .retry,
             "Transcription failed: \(URLError(.timedOut).localizedDescription)"),
            (.transport(URLError(.secureConnectionFailed)), .providerFailed, .retry,
             "Transcription failed: \(URLError(.secureConnectionFailed).localizedDescription)"),
            (.engineFailed("model crashed"), .engineFailed, .retry,
             "Transcription failed: model crashed"),
        ]
        for (providerError, kind, fix, message) in cases {
            let controller = makeController(providers: [failingProvider(providerError)])
            controller.toggle()
            await controller.toggleAndWait()
            guard case .error(let error) = controller.state else {
                Issue.record("expected an error for \(providerError)"); continue
            }
            #expect(error.kind == kind, "\(providerError)")
            #expect(error.fix == fix, "\(providerError)")
            #expect(error.message == message, "\(providerError)")
            // Every transcription failure keeps the audio, and a .retry fix is
            // only ever offered when there is audio to retry.
            #expect(controller.canRetry, "\(providerError)")
        }
    }

    @Test func testNonProviderTransportErrorIsClassifiedToo() async throws {
        let provider = FakeProvider(name: "x", result: .failure(URLError(.notConnectedToInternet)))
        let controller = makeController(providers: [provider])
        controller.toggle()
        await controller.toggleAndWait()
        guard case .error(let error) = controller.state else {
            Issue.record("expected an error"); return
        }
        #expect(error.kind == .offline)
        let unknown = FakeProvider(name: "x", result: .failure(CocoaError(.fileReadUnknown)))
        let other = makeController(providers: [unknown])
        other.toggle()
        await other.toggleAndWait()
        guard case .error(let second) = other.state else {
            Issue.record("expected an error"); return
        }
        #expect(second.kind == .providerFailed)
    }

    @Test func testErrorsWithoutRetainedAudioNeverOfferRetry() async throws {
        // Secure field, start failure, stop failure, silence, too short and no
        // provider all leave nothing to retry, so none may carry .retry.
        var errors: [DictationError] = []
        func capture(_ controller: DictationController) {
            if case .error(let error) = controller.state { errors.append(error) }
            #expect(!controller.canRetry)
        }

        capture({ let c = makeController(providers: [okProvider()], isSecureInputActive: { true })
                  c.toggle(); return c }())

        recorder.startError = AudioRecorderError.noInputDevice
        capture({ let c = makeController(providers: [okProvider()]); c.toggle(); return c }())
        recorder.startError = nil

        struct StopFailed: Error {}
        recorder.stopError = StopFailed()
        let stopFail = makeController(providers: [okProvider()])
        stopFail.toggle(); await stopFail.toggleAndWait()
        capture(stopFail)
        recorder.stopError = nil

        recorder.didCaptureSpeech = false
        let silent = makeController(providers: [okProvider()])
        silent.toggle(); await silent.toggleAndWait()
        capture(silent)
        recorder.didCaptureSpeech = true

        recorder.bytesToWrite = 100
        let tooShort = makeController(providers: [okProvider()])
        tooShort.toggle(); await tooShort.toggleAndWait()
        capture(tooShort)
        recorder.bytesToWrite = 8192

        let none = makeController(providers: [])
        none.toggle(); await none.toggleAndWait()
        capture(none)

        let blank = makeController(providers: [okProvider("   ")])
        blank.toggle(); await blank.toggleAndWait()
        capture(blank)

        #expect(errors.map(\.kind) == [.secureField, .micUnavailable, .stopFailed,
                                       .noSpeech, .tooShort, .noProvider, .noSpeech])
        #expect(errors.map(\.fix) == [nil, .openMicrophoneSettings, nil, nil, nil,
                                      .openEngineSettings, nil])
        #expect(errors.allSatisfy { $0.fix != .retry })
        #expect(errors[2].message.hasPrefix("Couldn't stop recording: "))
        #expect(errors[0].message == "Secure field active. Dictation is off here.")
        #expect(errors[3].message == "No speech detected.")
        #expect(errors[4].message == "Recording was too short.")
        #expect(errors[5].message == "No transcription provider configured. Open Settings.")
    }

    @Test func testNewRecordingAfterAnErrorStartsClean() async throws {
        let controller = makeController(providers: [failingProvider(.http(401, "no"))])
        controller.toggle(source: .window)
        await controller.toggleAndWait()
        controller.toggle(source: .hotkey)
        #expect(controller.state == .recording)
        #expect(Array(timeline.suffix(2)) == ["state:error:keyRejected", "state:recording"])
    }

    // MARK: - Review round 1

    // Item 4: a failed clipboard write must not read as "Saved and copied".
    @Test func testFailedCopyEndsWithATypedErrorAndNoOutcome() async throws {
        deliveryFailure = DeliveryFailure()
        let controller = makeController(providers: [okProvider()])
        controller.toggle(source: .window)
        await controller.toggleAndWait()
        guard case .error(let error) = controller.state else {
            Issue.record("expected deliveryFailed, got \(controller.state)"); return
        }
        #expect(error.kind == .deliveryFailed)
        #expect(error.fix == nil)
        #expect(error.message == "Couldn't copy the text. It's saved in Useful Voice.")
        #expect(outcomes.isEmpty)
        #expect(records.count == 1)          // the dictation itself is still saved
        #expect(!controller.canRetry)
    }

    @Test func testFailedDeliveryCompletionActsOnlyOnce() async throws {
        holdDelivery = true
        let controller = makeController(providers: [okProvider()])
        controller.toggle(source: .window)
        await controller.toggleAndWait()
        parkedCompletions[0](.failure(DeliveryFailure()))
        parkedCompletions[0](.success(.copied))      // a late second call
        #expect(outcomes.isEmpty)
        guard case .error(let error) = controller.state else {
            Issue.record("expected an error"); return
        }
        #expect(error.kind == .deliveryFailed)
        #expect(states.filter { if case .error = $0 { return true } else { return false } }.count == 1)
    }

    // Item 5: start failures are typed by cause.
    @Test func testStartFailuresAreTypedByCause() {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }
        let cases: [(Error, DictationError.Kind, DictationFix?)] = [
            (AudioRecorderError.noInputDevice, .micUnavailable, .openMicrophoneSettings),
            (AudioRecorderError.inputDeviceLost, .micUnavailable, .openMicrophoneSettings),
            (AudioRecorderError.diskWriteFailed("Only 3 MB is free."), .diskFull, nil),
            (AudioRecorderError.formatUnsupported, .recordingFailed, nil),
            (AudioRecorderError.alreadyRecording, .recordingFailed, nil),
            (CocoaError(.fileWriteOutOfSpace), .diskFull, nil),
            (CocoaError(.fileWriteNoPermission), .recordingFailed, nil),
            (Boom(), .micUnavailable, .openMicrophoneSettings),
        ]
        for (cause, kind, fix) in cases {
            let controller = makeController(providers: [okProvider()])
            recorder.startError = cause
            controller.toggle()
            guard case .error(let error) = controller.state else {
                Issue.record("expected an error for \(cause)"); continue
            }
            #expect(error.kind == kind, "\(cause)")
            #expect(error.fix == fix, "\(cause)")
            #expect(error.message == "Couldn't start recording: \(cause.localizedDescription)", "\(cause)")
        }
        recorder.startError = nil
    }

    // Item 6: the recorder already delivers on main and checks its session, so the
    // controller reacts at once; there is no second hop for a stale call to hide in.
    @Test func testAutoStopActsSynchronouslyWithNoExtraHop() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle(source: .window)
        recorder.onAutoStop?()
        #expect(controller.state == .transcribing)
        await controller.awaitProcessing()
        #expect(deliveredModes == [.copy])
    }

    @Test func testAutoStopWhileNotRecordingIsIgnoredSynchronously() async throws {
        let controller = makeController(providers: [okProvider()])
        recorder.onAutoStop?()                      // idle
        #expect(controller.state == .idle)
        #expect(recorder.startCount == 0)
        controller.toggle()
        controller.toggle()                         // transcribing
        recorder.onAutoStop?()
        await controller.awaitProcessing()
        #expect(recorder.startCount == 1)
        #expect(delivered == ["hello world"])
    }

    // Item 7: paste only into the app the dictation started in.
    @Test func testHotkeyDictationStoppedElsewhereDeliversByCopyAndSaysSo() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle()                          // started in Slack
        frontmostApp = FrontmostApp(id: "com.apple.mail", name: "Mail")
        controller.toggle()                          // stopped after switching apps
        await controller.awaitProcessing()
        #expect(deliveredModes == [.copy])
        #expect(outcomes == [.delivered(words: 2, mode: .copiedNotPasted, appName: "Slack")])
    }

    @Test func testHotkeyDictationDeliveredWhileUsefulVoiceIsFrontCopies() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        frontmostApp = FrontmostApp(id: "ai.karko.usefulvoice", name: "Useful Voice", isSelf: true)
        controller.toggle()                          // e.g. stopped from the dock
        await controller.awaitProcessing()
        #expect(deliveredModes == [.copy])
        #expect(outcomes == [.delivered(words: 2, mode: .copiedNotPasted, appName: "Slack")])
    }

    @Test func testHotkeyDictationStartedAndDeliveredInUsefulVoicePastesThere() async throws {
        frontmostApp = FrontmostApp(id: "ai.karko.usefulvoice", name: "Useful Voice", isSelf: true)
        let controller = makeController(providers: [okProvider()])
        controller.toggle()                          // hotkey while typing in a note
        controller.toggle()
        await controller.awaitProcessing()
        #expect(deliveredModes == [.paste])
        #expect(outcomes.last == .delivered(words: 2, mode: .pasted, appName: "Useful Voice"))
    }

    @Test func testSameAppAtDeliveryStillPastes() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle()
        controller.toggle()
        await controller.awaitProcessing()
        #expect(deliveredModes == [.paste])
        #expect(outcomes == [.delivered(words: 2, mode: .pasted, appName: "Slack")])
    }

    @Test func testWindowAndRetryDeliveriesDoNotLookAtTheFrontmostAppAtDelivery() async throws {
        let controller = makeController(providers: [okProvider()])
        controller.toggle(source: .window)
        controller.toggle(source: .window)
        await controller.awaitProcessing()
        #expect(outcomes == [.delivered(words: 2, mode: .copied, appName: nil)])
        #expect(frontmostLookups == 0)
    }

    // Retained audio can be discarded (Delete all dictations).
    @Test func testDiscardRetainedAudioDisablesRetry() async throws {
        let controller = makeController(providers: [failingProvider(.http(500, "boom"))])
        controller.toggle()
        await controller.toggleAndWait()
        #expect(controller.canRetry)
        controller.discardRetainedAudio()
        #expect(!controller.canRetry)
        controller.retryLast()
        #expect(controller.state != .transcribing)
        #expect(delivered.isEmpty)
    }

    @Test func testDiscardRetainedAudioIsIgnoredWhileBusy() async throws {
        holdDelivery = true
        var attempt = 0
        let controller = DictationController(
            recorder: recorder,
            providers: { attempt += 1; return attempt == 1 ? [self.failingProvider(.http(500, "boom"))] : [self.okProvider()] },
            store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) })
        wire(controller)
        controller.toggle()
        await controller.toggleAndWait()
        #expect(controller.canRetry)
        controller.toggle()                          // new recording; the old audio is still retained
        controller.discardRetainedAudio()
        #expect(controller.canRetry)
    }
}
