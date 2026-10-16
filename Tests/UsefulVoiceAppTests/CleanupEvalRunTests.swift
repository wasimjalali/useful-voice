import Foundation
import Testing
@testable import UsefulVoiceCore
import UsefulVoiceLlama
@testable import UsefulVoiceApp

/// The cleanup eval's cases through the app's own path: `CleanupPipeline.run` with the real
/// S1-mini in `LocalCleanupModel` and `LlamaCleanupGenerator` (the placement the app picks on
/// this Mac), the Swift rules and guard, and the 1.5 s deadline. Writes a raw file in
/// `evals/cleanup/run_eval.py`'s format, so `run_eval.py --rescore` scores it like the
/// llama-server runs. Runs only when asked:
///
///   UV_S1_MINI_PATH=<gguf> UV_CLEANUP_EVAL_CASES=evals/cleanup/heldout.json \
///   UV_CLEANUP_EVAL_OUT=<new file> swift test --filter CleanupEvalRunTests
///
/// A run where the model gave no answer in time keeps the rules text as its `output` (what the
/// app shows), with the reason in `outcome` and any late answer in `late_output`.
@Suite("Cleanup eval through the app's pipeline (needs the weights and an output path)", .serialized,
       .enabled(if: ["UV_S1_MINI_PATH", "UV_CLEANUP_EVAL_CASES", "UV_CLEANUP_EVAL_OUT"]
           .allSatisfy { ProcessInfo.processInfo.environment[$0] != nil }))
struct CleanupEvalRunTests {
    private struct Case: Decodable {
        let id: String
        let app: String?
        let input: String
    }

    /// Passes calls through and remembers whether, and with what, the last one returned.
    private final class Recorder: CleanupModel, @unchecked Sendable {
        let inner: LocalCleanupModel
        private let lock = NSLock()
        private var answer: String??

        init(_ inner: LocalCleanupModel) { self.inner = inner }

        func reset() { lock.withLock { answer = nil } }
        var returned: String?? { lock.withLock { answer } }

        func clean(_ text: String, controlLine: String, deadline: ContinuousClock.Instant) async -> String? {
            let out = await inner.clean(text, controlLine: controlLine, deadline: deadline)
            lock.withLock { answer = .some(out) }
            return out
        }
    }

    @Test(.timeLimit(.minutes(30)))
    func runTheCasesThroughThePipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        let weights = try #require(env["UV_S1_MINI_PATH"])
        let casesURL = URL(fileURLWithPath: try #require(env["UV_CLEANUP_EVAL_CASES"]))
        let outURL = URL(fileURLWithPath: try #require(env["UV_CLEANUP_EVAL_OUT"]))
        try #require(!FileManager.default.fileExists(atPath: outURL.path), "results are never overwritten")
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: casesURL))

        let generator = LlamaCleanupGenerator()
        let model = LocalCleanupModel(modelURL: URL(fileURLWithPath: weights), generator: generator, idleUnloadAfter: .seconds(3600))
        let recorder = Recorder(model)
        let gates = CleanupPipeline.Gates(flagOn: true, modelInstalled: true, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        await model.begin()
        await model.waitForLoad()
        try #require(await model.isLoaded)
        await model.end()
        let placement = generator.loadedPlacement?.rawValue ?? "none"
        print("EVAL placement \(placement), \(cases.count) cases from \(casesURL.lastPathComponent)")

        // Not scored: the first runs pay one-off costs (as run_eval.py's three warm-ups).
        for _ in 0..<3 {
            await model.begin()
            let warm = await CleanupPipeline.run(
                raw: "Hello there, um, this is a warm up.", language: "en", category: nil, style: nil,
                gates: gates, model: model, deadline: .seconds(60))
            await model.end()
            try #require(warm.model != .timedOut, "a warm-up ran past 60 s")
        }

        var rows: [[String: Any]] = []
        var rulesText: [String: String] = [:]
        for (n, c) in cases.enumerated() {
            let rules = CleanupRules.apply(to: c.input, language: "en")
            rulesText[c.id] = rules
            recorder.reset()
            await model.begin()
            let start = ContinuousClock.now
            let result = await CleanupPipeline.run(
                raw: c.input, language: "en", category: c.app, style: nil, gates: gates, model: recorder)
            let took = start.duration(to: .now)
            await model.end()

            var row: [String: Any] = [
                "id": c.id, "model_input": rules, "reasoning": false,
                "latency_ms": Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15,
                "pipeline_text": result.text, "pipeline_source": "\(result.source)",
                "outcome": result.model.map { "\($0)" } ?? "rulesLeftNothing",
            ]
            switch result.model {
            case .accepted?, .rejected?:
                row["output"] = (recorder.returned ?? nil) ?? rules
            case .timedOut?, .failed?:
                // No answer in time: the app shows the rules text. Wait for the late run to end,
                // so it cannot take the next case's deadline or answer for it, and keep what it said.
                row["output"] = rules
                let waitStart = ContinuousClock.now
                while recorder.returned == nil, waitStart.duration(to: .now) < .seconds(60) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(recorder.returned != nil, "the model was still running \(c.id) after 60 s")
                if case .some(.some(let late)) = recorder.returned { row["late_output"] = late }
            case .skipped?, nil:
                // The model was never asked (rules left nothing, or a gate said skip).
                row["output"] = result.text
            }
            rows.append(row)
            if (n + 1) % 25 == 0 { print("EVAL \(n + 1)/\(cases.count)") }
        }

        let outcomes = Dictionary(grouping: rows, by: { $0["outcome"] as? String ?? "" }).mapValues(\.count)
        print("EVAL outcomes \(outcomes.sorted { $0.key < $1.key })")
        let raw: [String: Any] = [
            "cases_ids": cases.map(\.id),
            "rules_text": rulesText,
            "runs": ["rules+s1": rows],
            "servers": ["s1": [
                "cmd": "app pipeline: CleanupPipeline.run, LocalCleanupModel, LlamaCleanupGenerator (\(placement)), deadline \(CleanupModelPolicy.defaultDeadline)",
                "peak_rss_mb": NSNull(),
                "model": ["name": S1MiniModel.credit, "revision": S1MiniModel.revision, "file": S1MiniModel.model.fileName, "sha256": S1MiniModel.model.sha256],
            ]],
            "meta": [
                "date": ISO8601DateFormatter().string(from: Date()), "runner": "app-pipeline",
                "placement": placement,
                "llama_cpp": "b11669 xcframework", "llama_version": LlamaRuntime.version(),
                "deadline_ms": 1500, "warmup": 3,
                "physical_memory": ProcessInfo.processInfo.physicalMemory,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "cases_file": casesURL.lastPathComponent,
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["raw": raw], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outURL, options: .withoutOverwriting)
        await model.unload()
    }
}
