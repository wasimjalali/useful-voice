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

    var loads: Int { lock.withLock { _loads } }
    var unloads: Int { lock.withLock { _unloads } }
    var prompts: [String] { lock.withLock { _prompts } }

    func load(modelAt url: URL) throws {
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

struct LocalCleanupModelTests {
    private let url = URL(fileURLWithPath: "/tmp/none.gguf")
    private let line = "[Styling: semi-formal] [Structure: prose] [Context: general]"
    private var soon: ContinuousClock.Instant { .now.advanced(by: .seconds(10)) }

    private func waitUntil(_ condition: @escaping () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func loadsOnDemandAndRendersTheCardPrompt() async {
        let gen = FakeGenerator()
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        #expect(await !model.isLoaded)
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
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .milliseconds(120))
        _ = await model.clean("x", controlLine: line, deadline: soon)
        #expect(await model.isLoaded)
        #expect(await waitUntil { await !model.isLoaded })
        #expect(gen.unloads == 1)
        // The next dictation loads it again.
        _ = await model.clean("y", controlLine: line, deadline: soon)
        #expect(gen.loads == 2)
        await model.unload()
    }

    @Test func activityRestartsTheIdleTimerAndADictationInProgressIsNeverUnloaded() async {
        let gen = FakeGenerator()
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .milliseconds(200))
        await model.begin()
        // Longer than the idle window while the dictation is still going: still loaded.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(await model.isLoaded)
        #expect(gen.unloads == 0)
        // The dictation ends: the window starts then.
        await model.end()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await model.isLoaded)
        await model.begin()
        try? await Task.sleep(for: .milliseconds(350))
        #expect(await model.isLoaded)
        await model.end()
        #expect(await waitUntil { await !model.isLoaded })
        #expect(gen.unloads == 1)
    }

    @Test func loadFailureReturnsNilAndRetriesNextTime() async {
        let gen = FakeGenerator()
        gen.failLoad = true
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        #expect(await model.clean("x", controlLine: line, deadline: soon) == nil)
        #expect(await !model.isLoaded)
        gen.failLoad = false
        #expect(await model.clean("x", controlLine: line, deadline: soon) == gen.answer)
        await model.unload()
    }

    @Test func runFailureReturnsNilAndKeepsTheModelLoaded() async {
        let gen = FakeGenerator()
        gen.failGenerate = true
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        #expect(await model.clean("x", controlLine: line, deadline: soon) == nil)
        #expect(await model.isLoaded)
        await model.unload()
    }

    @Test func aDeadlineThatAlreadyPassedSkipsTheRun() async {
        let gen = FakeGenerator()
        let model = LocalCleanupModel(modelURL: url, generator: gen, idleUnloadAfter: .seconds(60))
        #expect(await model.clean("x", controlLine: line, deadline: .now.advanced(by: .milliseconds(-1))) == nil)
        #expect(gen.prompts.isEmpty)
        await model.unload()
    }
}
