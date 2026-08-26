import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct LanguageMemoryPostProcessorTests {
    @Test func testRawResultAppliesLocalMemoryWithoutFormatter() {
        let term = MemoryTerm(phrase: "Claude Code", aliases: ["cloud code"])
        let rule = ReplacementRule(match: "cloud code", replacement: "Claude Code")
        let snippet = MemorySnippet(trigger: "my signature", expansion: "Best,\nWasim")
        let snapshot = LanguageMemorySnapshot(
            terms: [term],
            replacements: [rule],
            snippets: [snippet]
        )

        let result = LanguageMemoryPostProcessor.rawResult(
            for: "Please add cloud code and my signature.",
            snapshot: snapshot,
            language: .en
        )

        #expect(result.text == "Please add Claude Code and Best,\nWasim.")
        #expect(result.mode == .raw)
        #expect(result.replacementRuleIDs == [rule.id])
        #expect(result.memoryHitIDs == [term.id])
        #expect(result.snippetIDs == [snippet.id])
    }

    @Test func testFormattedResultMergesPreAndPostDeterministicMemory() {
        let preRule = ReplacementRule(match: "cloud code", replacement: "Claude Code")
        let postRule = ReplacementRule(match: "g p t", replacement: "GPT")
        let snippet = MemorySnippet(trigger: "my signoff", expansion: "Best,\nWasim")
        let term = MemoryTerm(phrase: "GPT", priority: .always)
        let snapshot = LanguageMemorySnapshot(
            terms: [term],
            replacements: [preRule, postRule],
            snippets: [snippet]
        )
        let prepared = LanguageMemoryPostProcessor.applyDeterministic(
            to: "cloud code",
            snapshot: snapshot,
            language: .auto
        )
        let formatted = FormattingResult(
            text: "Use g p t and my signoff.",
            newTerms: ["GPT"],
            mode: .formatted
        )

        let result = LanguageMemoryPostProcessor.formattedResult(
            prepared: prepared,
            formatted: formatted,
            snapshot: snapshot,
            language: .auto
        )

        #expect(result.text == "Use GPT and Best,\nWasim.")
        #expect(result.mode == .formatted)
        #expect(result.newTerms == ["GPT"])
        #expect(result.replacementRuleIDs == [preRule.id, postRule.id])
        #expect(result.memoryHitIDs == [term.id])
        #expect(result.snippetIDs == [snippet.id])
    }
}
