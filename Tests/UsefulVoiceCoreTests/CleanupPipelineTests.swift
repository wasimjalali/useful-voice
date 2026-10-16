import Foundation
import Testing
@testable import UsefulVoiceCore

/// A fake model: returns a canned answer, optionally after a delay, and records what it saw.
private final class FakeModel: CleanupModel, @unchecked Sendable {
    enum Behavior { case answer(String?), sleep(Duration, String?) }
    private let lock = NSLock()
    private var _calls: [(text: String, controlLine: String, deadline: ContinuousClock.Instant)] = []
    let behavior: Behavior

    init(_ behavior: Behavior) { self.behavior = behavior }

    var calls: [(text: String, controlLine: String, deadline: ContinuousClock.Instant)] {
        lock.withLock { _calls }
    }

    func clean(_ text: String, controlLine: String, deadline: ContinuousClock.Instant) async -> String? {
        lock.withLock { _calls.append((text, controlLine, deadline)) }
        switch behavior {
        case .answer(let a): return a
        case .sleep(let d, let a):
            // Ignores cancellation on purpose: the pipeline must not wait for it.
            let end = ContinuousClock.now.advanced(by: d)
            while ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
            return a
        }
    }
}

struct CleanupPipelineTests {
    private let on = CleanupPipeline.Gates(flagOn: true, modelInstalled: true, physicalMemoryBytes: 16 << 30)
    private let raw = "so um I need to send the the report by Friday no wait make that Thursday"
    private let rules = "so I need to send the report by Friday no wait make that Thursday"

    private func run(
        _ raw: String, language: String? = "en", gates: CleanupPipeline.Gates? = nil,
        model: (any CleanupModel)?, deadline: Duration = .seconds(2)
    ) async -> CleanupPipeline.Result {
        await CleanupPipeline.run(
            raw: raw, language: language, category: nil, style: nil,
            gates: gates ?? on, model: model, deadline: deadline)
    }

    @Test func modelAnswerThatPassesTheGuardIsUsed() async {
        let model = FakeModel(.answer("I need to send the report by Thursday."))
        let before = ContinuousClock.now
        let r = await run(raw, model: model)
        #expect(r.text == "I need to send the report by Thursday.")
        #expect(r.source == .model)
        #expect(r.model == .accepted)
        // The model reads the rules text, with the control line, and a deadline in the future.
        let call = model.calls[0]
        #expect(call.text == rules)
        #expect(call.controlLine == "[Styling: semi-formal] [Structure: prose] [Context: general]")
        // The deadline is absolute: two seconds from when the pipeline started.
        #expect(call.deadline >= before.advanced(by: .seconds(2)))
        #expect(call.deadline <= ContinuousClock.now.advanced(by: .seconds(2)))
    }

    @Test func controlLineFollowsCategoryAndStyle() async {
        let model = FakeModel(.answer(nil))
        _ = await CleanupPipeline.run(
            raw: raw, language: "en", category: "email", style: "formal",
            gates: on, model: model, deadline: .seconds(2))
        #expect(model.calls[0].controlLine == "[Styling: formal] [Structure: prose] [Context: email]")
    }

    @Test func flagOffNeverCallsTheModel() async {
        let model = FakeModel(.answer("I need to send the report by Thursday."))
        var gates = on
        gates.flagOn = false
        let r = await run(raw, gates: gates, model: model)
        #expect(r.text == rules)
        #expect(r.source == .rules)
        #expect(r.model == .skipped(.flagOff))
        #expect(model.calls.isEmpty)
    }

    @Test func notDownloadedAndLowMemoryNeverCallTheModel() async {
        let model = FakeModel(.answer("I need to send the report by Thursday."))
        var gates = on
        gates.modelInstalled = false
        #expect(await run(raw, gates: gates, model: model).model == .skipped(.modelNotDownloaded))
        gates = on
        gates.physicalMemoryBytes = 6 << 30
        let low = await run(raw, gates: gates, model: model)
        #expect(low.model == .skipped(.notEnoughMemory))
        #expect(low.text == rules)
        #expect(model.calls.isEmpty)
    }

    @Test func nonEnglishAndMissingModelSkip() async {
        let model = FakeModel(.answer("x"))
        let de = await run("also ähm das ist gut", language: "de", model: model)
        #expect(de.text == "also ähm das ist gut")
        #expect(de.model == .skipped(.notEnglish))
        #expect(await run(raw, model: nil).model == .skipped(.noModel))
        #expect(model.calls.isEmpty)
    }

    @Test func aModelThatCannotLoadNeverReachesTheDictation() async {
        // The disk or the runtime fails at load: the real model object logs it, returns nil, and
        // the pipeline hands back the rules text. Nothing throws or rejects.
        struct DiskError: Error {}
        final class Broken: CleanupTextGenerator, @unchecked Sendable {
            func load(modelAt url: URL) throws { throw DiskError() }
            func generate(prompt: String, deadline: ContinuousClock.Instant) throws -> String { throw DiskError() }
            func unload() {}
        }
        let model = LocalCleanupModel(modelURL: URL(fileURLWithPath: "/nonexistent/s1.gguf"), generator: Broken())
        await model.begin()
        let r = await run(raw, model: model)
        #expect(r.text == rules)
        #expect(r.source == .rules)
        #expect(r.model == .failed)
        await model.end()
    }

    @Test func nilFromTheModelFallsBackToRules() async {
        let r = await run(raw, model: FakeModel(.answer(nil)))
        #expect(r.text == rules)
        #expect(r.source == .rules)
        #expect(r.model == .failed)
    }

    @Test func emptyModelOutputFallsBackToRules() async {
        for empty in ["", "  \n "] {
            let r = await run(raw, model: FakeModel(.answer(empty)))
            #expect(r.text == rules)
            #expect(r.model == .rejected(.empty))
        }
    }

    @Test func guardRejectKeepsTheRulesText() async {
        // Drops "Thursday" and the report: far more than the allowed share of the words.
        let dropped = await run(raw, model: FakeModel(.answer("I need to send.")))
        #expect(dropped.text == rules)
        #expect(dropped.source == .rules)
        if case .rejected = dropped.model {} else { Issue.record("expected a guard reject, got \(String(describing: dropped.model))") }

        // Adds content the speaker never said.
        let added = await run(raw, model: FakeModel(.answer(
            "I need to send the report by Thursday, and please also book a flight to Berlin for the whole team.")))
        #expect(added.text == rules)
        if case .rejected = added.model {} else { Issue.record("expected a guard reject, got \(String(describing: added.model))") }

        // Chat wrapper text.
        let wrapped = await run(raw, model: FakeModel(.answer("Here is the cleaned text: I need to send the report by Thursday.")))
        #expect(wrapped.text == rules)
        #expect(wrapped.model == .rejected(.wrapper))

        // Reasoning leaked into the answer.
        let thinking = await run(raw, model: FakeModel(.answer("<think>hmm</think> I need to send the report by Thursday.")))
        #expect(thinking.model == .rejected(.reasoning))
    }

    @Test func slowModelTimesOutAtTheDeadlineWithoutWaiting() async {
        let model = FakeModel(.sleep(.seconds(20), "I need to send the report by Thursday."))
        let started = ContinuousClock.now
        let r = await run(raw, model: model, deadline: .milliseconds(150))
        let waited = started.duration(to: .now)
        #expect(r.text == rules)
        #expect(r.source == .rules)
        #expect(r.model == .timedOut)
        #expect(waited >= .milliseconds(140))
        #expect(waited < .seconds(15))
    }

    @Test func fastModelDoesNotWaitForTheDeadline() async {
        let started = ContinuousClock.now
        let r = await run(raw, model: FakeModel(.answer("I need to send the report by Thursday.")), deadline: .seconds(30))
        #expect(r.model == .accepted)
        #expect(started.duration(to: .now) < .seconds(25))
    }

    @Test func rulesThatLeaveNothingReturnTheRawTextAndSkipTheModel() async {
        let model = FakeModel(.answer("anything"))
        let r = await run("Um, uh.", model: model)
        #expect(r.text == "Um, uh.")
        #expect(r.source == .raw)
        #expect(r.model == nil)
        #expect(model.calls.isEmpty)
    }

    @Test func whitespaceOnlyNeverReachesTheModel() async {
        let model = FakeModel(.answer("anything"))
        let r = await run("  \n ", model: model)
        #expect(r.text == "  \n ")
        #expect(r.source == .raw)
        #expect(model.calls.isEmpty)
    }

    @Test func emptyRawStaysEmpty() async {
        let r = await run("", model: FakeModel(.answer("x")))
        #expect(r.text == "")
        #expect(r.model == nil)
    }

    @Test func cleanTextTheModelLeavesAloneIsTheRulesText() async {
        // Same words back: the guard calls it a format-only edit and keeps the rules text.
        let text = "I need to send the report by Thursday."
        let r = await run(text, model: FakeModel(.answer(text)))
        #expect(r.text == text)
        #expect(r.source == .raw)
        #expect(r.model == .rejected(.noWordChange))
    }
}
