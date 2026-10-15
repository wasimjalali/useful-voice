import Testing
import Foundation
@testable import UsefulVoiceCore

/// Runs the shared fixtures in `evals/cleanup/fixtures` through the Swift cleanup core.
/// `windows/tests/cleanup.test.ts` runs the same rows through the TypeScript mirror, so
/// the two cores are held to one list instead of two hand-copied ones.
struct CleanupTests {
    private struct RulesRow: Decodable {
        let name: String
        let input: String
        let expected: String
    }

    private struct GuardRow: Decodable {
        let name: String
        let rulesText: String
        let output: String
        let verdict: String
        let text: String?
    }

    private struct ControlRow: Decodable {
        let category: String?
        let style: String?
        let line: String
    }

    private struct ControlFile: Decodable {
        let systemPrompt: String
        let rows: [ControlRow]
    }

    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("evals/cleanup/fixtures/\(name)"))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Letters and digits only, lowercase, so punctuation and case do not matter.
    private func wordList(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in word.filter { $0.isLetter || $0.isNumber || $0 == "'" } }
            .filter { !$0.isEmpty }
    }

    private func isSubsequence(_ small: [String], of big: [String]) -> Bool {
        var i = 0
        for word in big where i < small.count && word == small[i] { i += 1 }
        return i == small.count
    }

    // MARK: Rules

    @Test func rulesMatchTheSharedFixtures() throws {
        let rows = try fixture("rules.json", as: [RulesRow].self)
        #expect(rows.count >= 80)
        var failures: [String] = []
        for row in rows {
            let got = CleanupRules.apply(to: row.input, language: "en")
            if got != row.expected { failures.append("\(row.name): got \(got.debugDescription), want \(row.expected.debugDescription)") }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func rulesOnlyEverDeleteWords() throws {
        for row in try fixture("rules.json", as: [RulesRow].self) {
            let out = wordList(CleanupRules.apply(to: row.input, language: "en"))
            #expect(isSubsequence(out, of: wordList(row.input)), "\(row.name)")
        }
    }

    @Test func rulesAreIdempotent() throws {
        for row in try fixture("rules.json", as: [RulesRow].self) {
            let once = CleanupRules.apply(to: row.input, language: "en")
            #expect(CleanupRules.apply(to: once, language: "en") == once, "\(row.name)")
        }
    }

    @Test func rulesCleanEnglishCodesOnly() {
        let text = "Um, so we the the go."
        #expect(CleanupRules.apply(to: text, language: "en") == "So we the go.")
        #expect(CleanupRules.apply(to: text, language: "EN-us") == "So we the go.")
        #expect(CleanupRules.apply(to: text, language: "en-GB") == "So we the go.")
        #expect(CleanupRules.apply(to: text, language: "de") == text)
        #expect(CleanupRules.apply(to: "um, a casa", language: "pt-BR") == "um, a casa")
        #expect(CleanupRules.apply(to: text, language: nil) == text)
        #expect(CleanupRules.apply(to: text, language: "") == text)
    }

    // MARK: Guard

    @Test func guardMatchesTheSharedFixtures() throws {
        let rows = try fixture("guard.json", as: [GuardRow].self)
        var failures: [String] = []
        var seen = Set<String>()
        for row in rows {
            seen.insert(row.verdict)
            let verdict = CleanupGuard.evaluate(rulesText: row.rulesText, modelOutput: row.output)
            let want: CleanupGuard.Verdict
            if row.verdict == "accept" {
                want = .accept(row.text ?? "")
            } else if let reason = CleanupGuard.Reason(rawValue: row.verdict) {
                want = .reject(reason)
            } else {
                failures.append("\(row.name): unknown verdict \(row.verdict)")
                continue
            }
            if verdict != want { failures.append("\(row.name): got \(verdict), want \(want)") }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(seen == ["accept", "reasoning", "empty", "tooLong", "droppedContent", "addedContent"])
    }

    @Test func guardHonoursCustomLimits() {
        let input = "Ship the release candidate tonight."
        let output = "Ship the release tonight."
        #expect(CleanupGuard.evaluate(rulesText: input, modelOutput: output) == .reject(.droppedContent))
        var loose = CleanupGuard.Limits.standard
        loose.maxDropShare = 0.5
        #expect(CleanupGuard.evaluate(rulesText: input, modelOutput: output, limits: loose) == .accept(output))
    }

    @Test func guardIsCaseAndFormatBlind() {
        let verdict = CleanupGuard.evaluate(rulesText: "so we ship friday", modelOutput: "SO, WE SHIP: FRIDAY!!")
        #expect(verdict == .accept("SO, WE SHIP: FRIDAY!!"))
    }

    // MARK: Control line

    @Test func controlLineMatchesTheSharedFixtures() throws {
        let file = try fixture("controlline.json", as: ControlFile.self)
        #expect(CleanupControlLine.systemPrompt == file.systemPrompt)
        var failures: [String] = []
        for row in file.rows {
            let got = CleanupControlLine.line(category: row.category, style: row.style)
            if got != row.line { failures.append("\(row.category ?? "nil") / \(row.style ?? "nil"): got \(got), want \(row.line)") }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func controlLineOnlyUsesTrainedValues() {
        let trained = try! NSRegularExpression(
            pattern: #"^\[Styling: (casual|semi-casual|semi-formal|formal)\] \[Structure: prose\] \[Context: (general|email)\]$"#)
        let categories: [String?] = [nil, "email", "chat", "coding", "x", "", "Notes"]
        let styles: [String?] = [nil, "casual", "formal", "semi-casual", "semi-formal", "weird"]
        for category in categories {
            for style in styles {
                let line = CleanupControlLine.line(category: category, style: style)
                #expect(trained.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil, "\(line)")
            }
        }
    }

    @Test func userMessagePutsTheControlLineOnItsOwnLine() {
        #expect(CleanupControlLine.userMessage(category: "email", style: nil, text: "hello")
            == "[Styling: semi-formal] [Structure: prose] [Context: email]\nhello")
        #expect(CleanupControlLine.settings(category: "chat", style: "formal")
            == CleanupControlLine.Settings(styling: .formal, structure: .prose, context: .general))
    }

    @Test func systemPromptIsTheModelCardText() {
        #expect(CleanupControlLine.systemPrompt ==
            "You are a text normalizer for speech-to-text transcripts. The input begins with a control line "
            + "specifying the styling, structure, and context settings; clean the transcript to match those "
            + "settings and output only the cleaned text.")
    }
}
