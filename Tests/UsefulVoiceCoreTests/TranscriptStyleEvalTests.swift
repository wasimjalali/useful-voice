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
        #expect(try rows().count == 44)
        for row in try rows() where row.known_gap == nil {
            let styled = TranscriptStyle.apply(to: row.got, language: row.lang)
            if ![row.expected] .appending(contentsOf: row.accept ?? []).contains(styled) {
                failures.append("\(row.id): got \"\(styled)\", want \"\(row.expected)\"")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func knownGapsStayDigitsRatherThanGuessAnEnding() throws {
        #expect(try rows().filter { $0.known_gap != nil }.count == 3)
        for row in try rows() where row.known_gap != nil {
            let styled = TranscriptStyle.apply(to: row.got, language: row.lang)
            // "der 3." and "die 3." have no certain ending, so the digit must survive.
            let regex = try NSRegularExpression(pattern: #"\b(?:[Dd]er|[Dd]ie) \d\."#)
            let gaps = regex.matches(in: row.got, range: NSRange(row.got.startIndex..., in: row.got))
                .compactMap { Range($0.range, in: row.got).map { String(row.got[$0]) } }
            #expect(!gaps.isEmpty, "\(row.id) has no der/die ordinal")
            for gap in gaps { #expect(styled.contains(gap), "\(row.id): \(styled)") }
        }
    }

    private struct Guard: Decodable { let lang: String; let input: String; let expected: String }
    private struct Guards: Decodable { let cases: [Guard] }

    /// False positives found in review (acronyms, versions, times, money, ranges,
    /// abbreviations) plus a few that must change. Same file as the Windows test.
    @Test func guardCasesKeepTheirDigitsAndChangeOnlyWhatIsSafe() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("evals/formatting/style-guards.json"))
        var failures: [String] = []
        let guards = try JSONDecoder().decode(Guards.self, from: data).cases
        #expect(guards.count == 121)
        for c in guards {
            let styled = TranscriptStyle.apply(to: c.input, language: c.lang)
            if styled != c.expected { failures.append("\(c.input) -> \(styled), want \(c.expected)") }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func unknownLanguageIsLeftUntouched() {
        #expect(TranscriptStyle.apply(to: "Es waren 3 Leute dabei.", language: "auto") == "Es waren 3 Leute dabei.")
        #expect(TranscriptStyle.apply(to: "Il y a 3 personnes.", language: "fr") == "Il y a 3 personnes.")
    }
}

private extension Array where Element == String {
    func appending(contentsOf other: [String]) -> [String] { self + other }
}
