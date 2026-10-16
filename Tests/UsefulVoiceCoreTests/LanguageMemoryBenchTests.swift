import Foundation
import Testing
@testable import UsefulVoiceCore

/// The Language Memory benchmark. Off unless `UV_LM_BENCH=1`, because it takes tens of
/// seconds. Run it in release so the numbers mean something:
///
///   UV_LM_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter LanguageMemoryBenchTests
///
/// Prints one `LMBENCH {json}` line per case (and appends it to `UV_LM_BENCH_OUT` if set).
/// `production` times the public entry point the dictation path calls. `legacy` times the
/// pre-index matcher kept in `LanguageMemoryLegacyOracle.swift`, so one run gives both sides.
@Suite struct LanguageMemoryBenchTests {
    private static let enabled = ProcessInfo.processInfo.environment["UV_LM_BENCH"] == "1"

    private func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    private func time(_ body: () -> LanguageMemoryProcessingResult) -> (ms: Double, result: LanguageMemoryProcessingResult) {
        let start = DispatchTime.now().uptimeNanoseconds
        let r = body()
        return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, r)
    }

    @Test(.enabled(if: LanguageMemoryBenchTests.enabled))
    func benchmark() throws {
        let transcript = LanguageMemoryBenchCorpus.transcript()
        #expect(transcript.count == LanguageMemoryBenchCorpus.transcriptLength)
        let runs = Int(ProcessInfo.processInfo.environment["UV_LM_BENCH_RUNS"] ?? "") ?? 5
        let sizes = (ProcessInfo.processInfo.environment["UV_LM_BENCH_SIZES"] ?? "1000,5000")
            .split(separator: ",").compactMap { Int($0) }
        let skipLegacy = ProcessInfo.processInfo.environment["UV_LM_BENCH_SKIP_LEGACY"] == "1"
        var lines: [String] = []

        for size in sizes {
            let snapshot = LanguageMemoryBenchCorpus.snapshot(terms: size, transcript: transcript)
            let stable = Set(snapshot.replacements.map(\.id) + snapshot.terms.map(\.id) + snapshot.snippets.map(\.id))
            for (scopeName, language) in [("auto", MemoryLanguage.auto), ("de", MemoryLanguage.de)] {
                for side in ["production", "legacy"] {
                    if side == "legacy" && skipLegacy { continue }
                    var samples: [Double] = []
                    var last: LanguageMemoryProcessingResult?
                    for _ in 0..<runs {
                        let (ms, r) = time {
                            side == "production"
                                ? LanguageMemoryPostProcessor.applyDeterministic(to: transcript, snapshot: snapshot, language: language)
                                : LegacyLanguageMemory.applyDeterministic(to: transcript, snapshot: snapshot, language: language)
                        }
                        samples.append(ms)
                        last = r
                    }
                    let r = last!
                    // How much of the pass is just building the rules (canonical keys and the
                    // locale-aware sort), which the index does not touch.
                    var ruleSamples: [Double] = []
                    for _ in 0..<runs {
                        let start = DispatchTime.now().uptimeNanoseconds
                        _ = DictionaryCorrector.effectiveRules(from: snapshot, language: language)
                        ruleSamples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                    }
                    let line = """
                    {"side":"\(side)","terms":\(size),"scope":"\(scopeName)","chars":\(transcript.count),\
                    "first_ms":\(String(format: "%.2f", samples[0])),"median_ms":\(String(format: "%.2f", median(samples))),\
                    "min_ms":\(String(format: "%.2f", samples.min()!)),"rules_median_ms":\(String(format: "%.2f", median(ruleSamples))),"runs":\(runs),\
                    "fired":\(r.replacementRuleIDs.count),"hits":\(r.memoryHitIDs.count),"snippets":\(r.snippetIDs.count),\
                    "fingerprint":"\(LanguageMemoryBenchCorpus.fingerprint(r, stableIDs: stable))"}
                    """
                    print("LMBENCH \(line)")
                    lines.append(line)
                }
            }
        }
        if let out = ProcessInfo.processInfo.environment["UV_LM_BENCH_OUT"] {
            try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
