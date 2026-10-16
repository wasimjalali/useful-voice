import Foundation
import Testing
@testable import UsefulVoiceCore

private final class FakeGenerator: CleanupTextGenerator, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var _loads = 0, _unloads = 0, _prompts: [String] = []
    var failLoad = false
    var failGenerate = false
    var answer = "I need to send the report by Thursday."
    /// When set, `load` blocks until the test signals it: a load that is still running.
    var loadGate: DispatchSemaphore?

    var loads: Int { lock.withLock { _loads } }
    var unloads: Int { lock.withLock { _unloads } }
    var prompts: [String] { lock.withLock { _prompts } }

    func load(modelAt url: URL) throws {
        loadGate?.wait()
        if failLoad { throw Failure() }
        lock.withLock { _loads += 1 }
    }

    func generate(prompt: String, deadline: ContinuousClock.Instant) throws -> String {
        if failGenerate { throw Failure() }
        lock.withLock { _prompts.append(prompt) }
        return answer
    }

    func unload() { lock.withLock { _unloads += 1 } }
}

/// A sleeper the test controls: each call is a numbered timer that waits until `fireAll`
/// (or is cancelled), so the idle window is exercised without real waiting or timing margins.
private final class ManualSleeper: @unchecked Sendable {
    struct Cancelled: Error {}
    private let lock = NSLock()
    private var _issued = 0
    private var _fired = 0

    var issued: Int { lock.withLock { _issued } }

    func sleep(_ duration: Duration) async throws {
        let ticket = lock.withLock { () -> Int in _issued += 1; return _issued }
        while lock.withLock({ _fired < ticket }) {
            if Task.isCancelled { throw Cancelled() }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func fireAll() { lock.withLock { _fired = _issued } }
}

struct LocalCleanupModelTests {
    private let url = URL(fileURLWithPath: "/tmp/none.gguf")
    private let line = "[Styling: semi-formal] [Structure: prose] [Context: general]"
    private var soon: ContinuousClock.Instant { .now.advanced(by: .seconds(10)) }

    private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func aColdCleanAnswersNilAtOnceAndStartsTheLoad() async {
        let gen = FakeGenerator()
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        #expect(await !model.isLoaded)
        #expect(await model.clean("so um hello", controlLine: line, deadline: soon) == nil)
        #expect(gen.prompts.isEmpty)
        await model.waitForLoad()
        #expect(await model.isLoaded)
        #expect(gen.loads == 1)
        let out = await model.clean("so um hello", controlLine: line, deadline: soon)
        #expect(out == gen.answer)
        #expect(gen.loads == 1)
        #expect(gen.prompts == [S1MiniModel.prompt(controlLine: line, text: "so um hello")])
        // A second call reuses the loaded weights.
        _ = await model.clean("again", controlLine: line, deadline: soon)
        #expect(gen.loads == 1)
        await model.unload()
    }

    @Test func beginLoadsBeforeAnyCleanup() async {
        let gen = FakeGenerator()
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        await model.begin()
        await model.waitForLoad()
        #expect(await model.isLoaded)
        #expect(gen.loads == 1)
        _ = await model.clean("x", controlLine: line, deadline: soon)
        #expect(gen.loads == 1)
        await model.unload()
        #expect(gen.unloads == 1)
        #expect(await !model.isLoaded)
    }

    @Test func unloadsAfterTheIdleWindow() async {
        let gen = FakeGenerator()
        let timer = ManualSleeper()
        let model = LocalCleanupModel(
            modelURL: url, generator: gen, idleUnloadAfter: .seconds(60), sleep: { try await timer.sleep($0) })
        await model.begin()
        await model.waitForLoad()
        await model.end()
        #expect(await model.isLoaded)
        #expect(await waitUntil { timer.issued == 1 })
        timer.fireAll()
        #expect(await waitUntil { await !model.isLoaded })
        #expect(gen.unloads == 1)
        // The first dictation after the unload is not kept waiting: nil at once, and the
        // load that call started serves the next one.
        #expect(await model.clean("y", controlLine: line, deadline: soon) == nil)
        await model.waitForLoad()
        #expect(gen.loads == 2)
        #expect(await model.clean("z", controlLine: line, deadline: soon) == gen.answer)
        await model.unload()
    }

    @Test func aDictationInProgressIsNeverUnloadedAndActivityRestartsTheTimer() async {
        let gen = FakeGenerator()
        let timer = ManualSleeper()
        let model = LocalCleanupModel(
            modelURL: url, generator: gen, idleUnloadAfter: .seconds(60), sleep: { try await timer.sleep($0) })
        await model.begin()
        await model.waitForLoad()
        // No timer runs while the dictation is going, however long it lasts.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(timer.issued == 0)
        await model.end()
        #expect(await waitUntil { timer.issued == 1 })
        // A new dictation starts before the window ends: the first timer must not unload.
        await model.begin()
        timer.fireAll()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await model.isLoaded)
        #expect(gen.unloads == 0)
        await model.end()
        #expect(await waitUntil { timer.issued == 2 })
        timer.fireAll()
        #expect(await waitUntil { await !model.isLoaded })
        #expect(gen.unloads == 1)
    }

    @Test func aCleanThatFinishesAfterTheNextBeginCannotUnloadUnderIt() async {
        let gen = FakeGenerator()
        let timer = ManualSleeper()
        let model = LocalCleanupModel(
            modelURL: url, generator: gen, idleUnloadAfter: .seconds(60), sleep: { try await timer.sleep($0) })
        // Dictation 1 is still "ending" (clean running) when dictation 2 begins.
        await model.begin()
        await model.waitForLoad()
        let first = Task { await model.clean("one", controlLine: line, deadline: soon) }
        await model.begin()
        #expect(await first.value == gen.answer)
        // Dictation 1's clean finished while dictation 2 is in progress: no timer may run.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(timer.issued == 0)
        timer.fireAll()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await model.isLoaded)
        #expect(gen.unloads == 0)
        // Dictation 1 ends: dictation 2 is still going, so still no timer.
        await model.end()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(timer.issued == 0)
        #expect(await model.isLoaded)
        // Dictation 2 ends: now the window starts, and the weights go.
        await model.end()
        #expect(await waitUntil { timer.issued == 1 })
        timer.fireAll()
        #expect(await waitUntil { await !model.isLoaded })
        #expect(gen.unloads == 1)
    }

    @Test func anExtraEndNeverGoesNegative() async {
        let gen = FakeGenerator()
        let timer = ManualSleeper()
        let model = LocalCleanupModel(
            modelURL: url, generator: gen, idleUnloadAfter: .seconds(60), sleep: { try await timer.sleep($0) })
        await model.end()
        await model.end()
        await model.begin()
        await model.waitForLoad()
        try? await Task.sleep(for: .milliseconds(50))
        let issuedWhileActive = timer.issued
        #expect(await model.isLoaded)
        await model.end()
        #expect(await waitUntil { timer.issued == issuedWhileActive + 1 })
        await model.unload()
    }

    @Test func loadFailureReturnsNilAndRetriesNextTime() async {
        let gen = FakeGenerator()
        gen.failLoad = true
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        #expect(await model.clean("x", controlLine: line, deadline: soon) == nil)
        await model.waitForLoad()
        #expect(await !model.isLoaded)
        gen.failLoad = false
        // The failed load is retried by the next dictation; it answers once that load is done.
        #expect(await model.clean("x", controlLine: line, deadline: soon) == nil)
        await model.waitForLoad()
        #expect(await model.clean("x", controlLine: line, deadline: soon) == gen.answer)
        await model.unload()
    }

    @Test func runFailureReturnsNilAndKeepsTheModelLoaded() async {
        let gen = FakeGenerator()
        gen.failGenerate = true
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        await model.begin()
        await model.waitForLoad()
        #expect(await model.clean("x", controlLine: line, deadline: soon) == nil)
        #expect(await model.isLoaded)
        await model.unload()
    }

    @Test func aDeadlineThatAlreadyPassedSkipsTheRun() async {
        let gen = FakeGenerator()
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        await model.begin()
        await model.waitForLoad()
        #expect(await model.clean("x", controlLine: line, deadline: .now.advanced(by: .milliseconds(-1))) == nil)
        #expect(gen.prompts.isEmpty)
        await model.unload()
    }

    @Test func aLoadInFlightNeverMakesACleanWait() async {
        let gen = FakeGenerator()
        let gate = DispatchSemaphore(value: 0)
        gen.loadGate = gate
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        await model.begin()                       // the load starts and blocks in the generator
        // The load stays blocked until after this call: if `clean` waited for it, this would hang.
        #expect(await model.clean("x", controlLine: line, deadline: soon) == nil)
        #expect(await !model.isLoaded)
        #expect(gen.prompts.isEmpty)
        #expect(gen.loads == 0)
        gate.signal()
        await model.waitForLoad()
        #expect(await model.isLoaded)
        #expect(gen.loads == 1)                   // the cold clean did not start a second load
        #expect(await model.clean("x", controlLine: line, deadline: soon) == gen.answer)
        await model.unload()
    }

    @Test func anUnloadDuringALoadFreesTheWeightsWhenItEnds() async {
        let gen = FakeGenerator()
        let gate = DispatchSemaphore(value: 0)
        gen.loadGate = gate
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        await model.begin()
        await model.unload()
        #expect(gen.unloads == 0)                 // nothing to free yet
        gate.signal()
        await model.waitForLoad()
        #expect(await !model.isLoaded)
        #expect(gen.unloads == 1)
        // A begin that arrives while loading cancels a pending unload.
        let gate2 = DispatchSemaphore(value: 0)
        gen.loadGate = gate2
        await model.begin()
        await model.unload()
        await model.begin()
        gate2.signal()
        await model.waitForLoad()
        #expect(await model.isLoaded)
        #expect(gen.unloads == 1)
        await model.end()
        await model.end()
        await model.unload()
    }

    @Test func aLoadNobodyUsesIsFreedAfterTheIdleWindow() async {
        let gen = FakeGenerator()
        let timer = ManualSleeper()
        let model = LocalCleanupModel(
            modelURL: url, generator: gen, idleUnloadAfter: .seconds(60), sleep: { try await timer.sleep($0) })
        #expect(await model.clean("x", controlLine: line, deadline: soon) == nil)   // starts a load, no dictation
        await model.waitForLoad()
        #expect(await model.isLoaded)
        #expect(await waitUntil { timer.issued >= 1 })
        timer.fireAll()
        #expect(await waitUntil { await !model.isLoaded })
        #expect(gen.unloads == 1)
    }
}
