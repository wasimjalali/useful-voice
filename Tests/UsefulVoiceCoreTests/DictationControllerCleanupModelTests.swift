import Testing
import Foundation
@testable import UsefulVoiceCore

/// The hidden S1-mini cleanup wired into the controller: flag off changes nothing, flag on
/// preloads at the press, runs after the rules behind the guard and the deadline, and always
/// falls back to the rules text.
@Suite @MainActor final class DictationControllerCleanupModelTests {
    /// Stands in for llama.cpp: records loads and prompts, answers with `answer`.
    final class Generator: CleanupTextGenerator, @unchecked Sendable {
        struct Boom: Error {}
        private let lock = NSLock()
        private var _loads = 0, _unloads = 0, _prompts: [String] = []
        var answer: String? = nil
        var failLoad = false
        /// Waits until the deadline like a real run that is too slow, then throws.
        var stallUntilDeadline = false
        /// When set, `load` blocks until the test signals it: a load that is still running.
        var loadGate: DispatchSemaphore?

        var loads: Int { lock.withLock { _loads } }
        var unloads: Int { lock.withLock { _unloads } }
        var prompts: [String] { lock.withLock { _prompts } }

        func load(modelAt url: URL) throws {
            loadGate?.wait()
            if failLoad { throw Boom() }
            lock.withLock { _loads += 1 }
        }
        func generate(prompt: String, deadline: ContinuousClock.Instant) throws -> String {
            lock.withLock { _prompts.append(prompt) }
            if stallUntilDeadline {
                while ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
                throw Boom()
            }
            guard let answer else { throw Boom() }
            return answer
        }
        func unload() { lock.withLock { _unloads += 1 } }
    }

    /// Counts how often the idle timer was armed, and never fires it.
    final class Timer: @unchecked Sendable {
        private let lock = NSLock()
        private var _armed = 0
        var armed: Int { lock.withLock { _armed } }
        func sleep(_ d: Duration) async throws {
            lock.withLock { _armed += 1 }
            try await Task.sleep(for: .seconds(3600))
        }
    }

    private let dir: URL
    private let store: RecordingStore
    private let recorder = FakeRecorder()
    private var delivered: [String] = []
    private var records: [DictationRecord] = []
    private let generator = Generator()
    private let timer = Timer()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dict-cm-\(UUID().uuidString)")
        store = try RecordingStore(directory: dir)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private let on = CleanupPipeline.Gates(flagOn: true, modelInstalled: true, physicalMemoryBytes: 16 << 30)

    private func makeModel() -> LocalCleanupModel {
        LocalCleanupModel(
            modelURL: URL(fileURLWithPath: "/tmp/s1.gguf"), generator: generator,
            idleUnloadAfter: .seconds(60), sleep: { [timer] in try await timer.sleep($0) })
    }

    private func makeController(
        text: String, language: String? = "en", model: LocalCleanupModel?,
        gates: CleanupPipeline.Gates? = nil, autoFormat: Bool = true, pin: LanguagePin = .auto
    ) -> DictationController {
        let provider = FakeProvider(name: "fake", result: .success(
            Transcript(text: text, detectedLanguage: language, durationSeconds: 1)))
        let gates = gates ?? on
        return DictationController(
            recorder: recorder, providers: { [provider] in [provider] }, store: store,
            hint: { TranscriptionHint(languagePin: pin, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in
                self?.delivered.append(text)
                done(.success(mode == .paste ? .pasted : .copied))
            },
            record: { [weak self] in self?.records.append($0) },
            autoFormat: { autoFormat },
            cleanupModel: model,
            cleanupGates: { gates })
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private let spoken = "so um I need to send the the report by Friday no wait make that Thursday"
    private let rulesText = "so I need to send the report by Friday no wait make that Thursday"

    @Test func flagOffIsIdenticalToNoModel() async {
        // A matrix of transcripts: fillers, stutters, a clean text, filler-only, not English.
        let cases: [(String, String?)] = [
            (spoken, "en"), ("Hello there, this is fine.", "en"), ("Um, uh.", "en"),
            ("also ähm das ist gut", "de"), ("I I think we should go", "en-GB"), (" ", "en"),
        ]
        for (text, language) in cases {
            delivered = []; records = []
            let baseline = makeController(text: text, language: language, model: nil)
            baseline.toggle()
            await baseline.toggleAndWait()
            let baselineDelivered = delivered, baselineRecords = records

            delivered = []; records = []
            let model = makeModel()
            var off = on
            off.flagOn = false
            let flagged = makeController(text: text, language: language, model: model, gates: off)
            generator.answer = "Completely different text that must never be used."
            flagged.toggle()
            await flagged.toggleAndWait()

            #expect(delivered == baselineDelivered, "\(text)")
            #expect(records.map(\.text) == baselineRecords.map(\.text))
            #expect(records.map(\.mode) == baselineRecords.map(\.mode))
            #expect(records.map(\.rawText) == baselineRecords.map(\.rawText))
        }
        #expect(generator.loads == 0)
        #expect(generator.prompts.isEmpty)
        #expect(timer.armed == 0)
    }

    @Test func autoFormatOffNeverTouchesTheModel() async {
        generator.answer = "I need to send the report by Thursday."
        let controller = makeController(text: spoken, model: makeModel(), autoFormat: false)
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == [spoken])
        #expect(generator.prompts.isEmpty)
    }

    @Test func modelTextIsDeliveredWhenAllGatesPass() async {
        generator.answer = "I need to send the report by Thursday."
        let model = makeModel()
        let controller = makeController(text: spoken, model: model)
        controller.toggle()                       // the press preloads
        #expect(await waitUntil { await model.isLoaded })
        #expect(generator.loads == 1)
        await controller.toggleAndWait()
        #expect(delivered == ["I need to send the report by Thursday."])
        #expect(records.first?.text == "I need to send the report by Thursday.")
        #expect(records.first?.rawText == spoken)
        #expect(records.first?.mode == .formatted)
        // The model read the rules text, with the card's control line.
        #expect(generator.prompts.count == 1)
        #expect(generator.prompts[0].contains("[Styling: semi-formal] [Structure: prose] [Context: general]\n\(rulesText)"))
        #expect(generator.loads == 1)
        // The dictation settled: the idle timer is armed once, nothing unloaded yet.
        #expect(await waitUntil { self.timer.armed >= 1 })
        #expect(generator.unloads == 0)
    }

    @Test func aGuardRejectKeepsTheRulesText() async {
        generator.answer = "I need to send."   // drops most of the speaker's words
        let controller = makeController(text: spoken, model: makeModel())
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == [rulesText])
    }

    @Test func aModelThatFailsToLoadStillDeliversTheRulesText() async {
        generator.failLoad = true
        let controller = makeController(text: spoken, model: makeModel())
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == [rulesText])
    }

    @Test func aSlowModelNeverHoldsTheDictationPastTheDeadline() async {
        generator.stallUntilDeadline = true
        let model = makeModel()
        let controller = makeController(text: spoken, model: model)
        controller.toggle()
        #expect(await waitUntil { await model.isLoaded })
        let started = ContinuousClock.now
        await controller.toggleAndWait()
        let took = started.duration(to: .now)
        #expect(delivered == [rulesText])
        #expect(took >= .milliseconds(1400))
        #expect(took < .seconds(10))
    }

    @Test func aColdModelNeverHoldsTheFirstDictationAndServesTheNext() async {
        generator.answer = "I need to send the report by Thursday."
        let gate = DispatchSemaphore(value: 0)
        generator.loadGate = gate
        let model = makeModel()
        let first = makeController(text: spoken, model: model)
        first.toggle()                            // the press starts a load that has not finished
        await first.toggleAndWait()
        // The rules text is delivered while the load is still blocked: the dictation never
        // depended on the model. (That `clean` itself returns at once is proved without any
        // clock in LocalCleanupModelTests.aLoadInFlightNeverMakesACleanWait: its load is
        // blocked until after the call returns.)
        #expect(delivered == [rulesText])
        #expect(await !model.isLoaded)
        #expect(generator.prompts.isEmpty)
        gate.signal()
        #expect(await waitUntil { await model.isLoaded })
        // The next dictation finds the model ready and uses it.
        delivered = []
        let second = makeController(text: spoken, model: model)
        second.toggle()
        await second.toggleAndWait()
        #expect(delivered == ["I need to send the report by Thursday."])
        #expect(generator.prompts.count == 1)
        #expect(generator.loads == 1)
    }

    @Test func aPinnedNonEnglishLanguageSkipsThePreloadAutoAndEnglishDoNot() async {
        generator.answer = "x"
        let german = makeModel()
        let pinnedDe = makeController(text: spoken, model: german, pin: .de)
        pinnedDe.toggle()
        await pinnedDe.awaitCleanupLifecycle()
        await german.waitForLoad()
        #expect(generator.loads == 0)
        #expect(await !german.isLoaded)
        await pinnedDe.toggleAndWait()
        await pinnedDe.awaitCleanupLifecycle()
        #expect(generator.loads == 0)
        #expect(timer.armed == 0)                 // no preload, so no dictation to settle

        for pin in [LanguagePin.auto, .en, LanguagePin(rawValue: "en-GB")] {
            let model = makeModel()
            let controller = makeController(text: spoken, model: model, pin: pin)
            let before = generator.loads
            controller.toggle()
            await controller.awaitCleanupLifecycle()
            await model.waitForLoad()
            #expect(generator.loads == before + 1, "\(pin.rawValue)")
            #expect(await model.isLoaded)
            await controller.toggleAndWait()
            await model.unload()
        }
    }

    @Test func gatesThatFailMeanNoPreloadAndNoModelCall() async {
        generator.answer = "I need to send the report by Thursday."
        for tweak in [
            { (g: inout CleanupPipeline.Gates) in g.modelInstalled = false },
            { (g: inout CleanupPipeline.Gates) in g.physicalMemoryBytes = 6 << 30 },
        ] {
            delivered = []
            var gates = on
            tweak(&gates)
            let controller = makeController(text: spoken, model: makeModel(), gates: gates)
            controller.toggle()
            await controller.toggleAndWait()
            #expect(delivered == [rulesText])
        }
        #expect(generator.loads == 0)
        #expect(generator.prompts.isEmpty)
    }

    @Test func nonEnglishSkipsTheModelButStillPreloadedAtThePress() async {
        generator.answer = "x"
        let controller = makeController(text: "also ähm das ist gut", language: "de", model: makeModel())
        controller.toggle()
        await controller.toggleAndWait()
        #expect(delivered == ["also ähm das ist gut"])
        #expect(generator.prompts.isEmpty)
    }

    @Test func cancelAndErrorPathsSettleTheModelToo() async {
        let model = makeModel()
        let cancelled = makeController(text: spoken, model: model)
        cancelled.toggle()
        #expect(await waitUntil { await model.isLoaded })
        cancelled.cancel()
        #expect(await waitUntil { self.timer.armed == 1 })

        // A silent recording ends in the error state without ever reaching the cleanup step.
        recorder.didCaptureSpeech = false
        let silent = makeController(text: spoken, model: model)
        silent.toggle()
        await silent.toggleAndWait()
        #expect(await waitUntil { self.timer.armed == 2 })
        #expect(generator.prompts.isEmpty)
    }
}
