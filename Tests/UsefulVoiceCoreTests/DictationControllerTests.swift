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
    var configuredSilenceTimeout: TimeInterval?

    func start(to url: URL) throws {
        startedURL = url
        try Data(count: bytesToWrite).write(to: url)
    }
    func stop() throws -> URL {
        guard let url = startedURL else { throw AudioRecorderError.notRecording }
        return url
    }
    func cancel() { cancelled = true }
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

@Suite @MainActor final class DictationControllerTests {
    private let dir: URL
    private let store: RecordingStore
    private let recorder: FakeRecorder
    private var delivered: [String] = []
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
            deliver: { [weak self] text, done in self?.delivered.append(text); done() },
            record: { [weak self] record in self?.records.append(record) },
            now: now,
            isSecureInputActive: isSecureInputActive
        )
        controller.onStateChange = { [weak self] state in
            self?.states.append(state)
        }
        return controller
    }

    private func makeFormattingController(
        providers: [TranscriptionProvider],
        rawTransform: ((String, FormattingContext) async -> FormattingResult)? = nil,
        format: @escaping (String, FormattingContext) async throws -> FormattingResult)
        -> DictationController {
        let controller = DictationController(
            recorder: recorder,
            providers: { providers },
            store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, done in self?.delivered.append(text); done() },
            record: { [weak self] record in self?.records.append(record) },
            format: format,
            rawTransform: rawTransform,
            context: { FormattingContext(appBundleID: nil, dictionaryWords: [],
                                         language: .auto) },
            suggestTerms: { [weak self] terms in self?.suggested.append(contentsOf: terms) },
            formatterUnavailable: { [weak self] in self?.fellBack = true })
        controller.onStateChange = { [weak self] state in self?.states.append(state) }
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
            deliver: { [weak self] text, done in self?.delivered.append(text); done() },
            record: { [weak self] record in self?.records.append(record) })
        controller.onStateChange = { [weak self] state in self?.states.append(state) }

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
        guard case .error(let message) = controller.state else {
            Issue.record("expected a no-speech notice, got \(controller.state)")
            return
        }
        #expect(message.lowercased().contains("speech"))
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
        guard case .error(let message) = controller.state else {
            Issue.record("expected a no-speech notice, got \(controller.state)")
            return
        }
        #expect(message.lowercased().contains("speech"))
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
        guard case .error(let message) = controller.state else {
            Issue.record("expected a too-short notice, got \(controller.state)")
            return
        }
        #expect(message.lowercased().contains("short"))
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
        guard case .error(let message) = controller.state else {
            Issue.record("expected error state, got \(controller.state)")
            return
        }
        #expect(message.contains("400"))
        #expect(message.contains("audio file is too short"))
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
        guard case .error(let message) = controller.state else {
            Issue.record("expected a secure-field refusal, got \(controller.state)")
            return
        }
        #expect(message.lowercased().contains("secure"))
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
            deliver: { [weak self] text, done in self?.delivered.append(text); done() },
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
        guard case .error(let message) = controller.state else {
            Issue.record("expected error state")
            return
        }
        #expect(message.contains("provider"))
    }
}
