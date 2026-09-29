import Testing
import Foundation
@testable import UsefulVoiceCore

/// Runs the recorded Deepgram output from `evals/formatting` through the real
/// `TranscriptStyle`, so the check covers what Deepgram actually returned rather
/// than sentences typed to suit the code. Re-record with `evals/formatting/run_eval.py`.
struct TranscriptStyleEvalTests {
    private struct Row: Decodable {
        let id: String
        let lang: String
        let got: String
        let expected: String
        let accept: [String]?
        let known_gap: String?
    }
    private struct Run: Decodable { let rows: [Row] }

    private func rows() throws -> [Row] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "evals/results/raw/2026-09-29-formatting-candidate.json"))
        return try JSONDecoder().decode(Run.self, from: data).rows
    }

    @Test func recordedDeepgramOutputEndsUpAsExpected() throws {
        var failures: [String] = []
        for row in try rows() where row.known_gap == nil {
            let styled = TranscriptStyle.apply(to: row.got, language: row.lang)
            if ![row.expected] .appending(contentsOf: row.accept ?? []).contains(styled) {
                failures.append("\(row.id): got \"\(styled)\", want \"\(row.expected)\"")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func knownGapsStayDigitsRatherThanGuessAnEnding() throws {
        for row in try rows() where row.known_gap != nil {
            let styled = TranscriptStyle.apply(to: row.got, language: row.lang)
            // Never a wrongly inflected ordinal: either the digit stays or it is correct.
            #expect(!styled.contains("erste ") || row.expected.contains("erste "), "\(row.id): \(styled)")
        }
    }

    @Test func unknownLanguageIsLeftUntouched() {
        #expect(TranscriptStyle.apply(to: "Es waren 3 Leute dabei.", language: "auto") == "Es waren 3 Leute dabei.")
        #expect(TranscriptStyle.apply(to: "Il y a 3 personnes.", language: "fr") == "Il y a 3 personnes.")
    }
}

private extension Array where Element == String {
    func appending(contentsOf other: [String]) -> [String] { self + other }
}
