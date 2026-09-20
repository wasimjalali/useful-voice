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

    @Test func testUnchangedTextSkipsSecondPassAndStillReportsMemoryHitOnce() {
        // With no snippets and no rule that changes the text, all four text
        // variants are the same string: the second pass is skipped and term
        // matching runs over the single distinct text — so the hit must still
        // appear, and appear exactly once.
        let term = MemoryTerm(phrase: "Claude Code", priority: .always)
        let unmatchedRule = ReplacementRule(match: "not present", replacement: "nope")
        let snapshot = LanguageMemorySnapshot(
            terms: [term],
            replacements: [unmatchedRule]
        )

        let result = LanguageMemoryPostProcessor.applyDeterministic(
            to: "please open Claude Code now",
            snapshot: snapshot,
            language: .en
        )

        #expect(result.text == "please open Claude Code now")
        #expect(result.replacementRuleIDs.isEmpty)
        #expect(result.memoryHitIDs == [term.id])
        #expect(result.snippetIDs.isEmpty)
    }

    @Test func testPassTwoStillRunsWhenRulesFiredWithNetZeroOutput() {
        // A net-zero rule cycle restores the input text: A rewrites it, a
        // middle rule misses on the intermediate text, B restores it. The
        // pass-two skip requires `appliedRuleIDs.isEmpty` — text equality
        // alone is NOT sufficient, because a rule evaluated against the
        // intermediate state can match the restored text. Without pass two,
        // the middle rule's "it slept" is silently dropped.
        // Sorted longest-first by effectiveRules: A(16) -> X(11) -> B(9).
        let ruleA = ReplacementRule(match: "the cat sat here", replacement: "a dog sat")
        let ruleX = ReplacementRule(match: "the cat sat", replacement: "it slept")
        let ruleB = ReplacementRule(match: "a dog sat", replacement: "the cat sat here")
        let snapshot = LanguageMemorySnapshot(replacements: [ruleA, ruleX, ruleB])

        let result = LanguageMemoryPostProcessor.applyDeterministic(
            to: "the cat sat here",
            snapshot: snapshot,
            language: .en
        )

        #expect(result.text == "it slept here")
        // Pass one fires A then B; pass two fires X — merged first-seen order.
        #expect(result.replacementRuleIDs == [ruleA.id, ruleB.id, ruleX.id])
    }

    @Test func testPassTwoCatchesRuleTargetIntroducedBySnippet() {
        // The snippet expansion creates a match for a rule that did not fire
        // in pass one; pass two must still resolve it.
        let rule = ReplacementRule(match: "acme", replacement: "Acme Corp")
        let snippet = MemorySnippet(trigger: "my company", expansion: "acme")
        let snapshot = LanguageMemorySnapshot(
            replacements: [rule],
            snippets: [snippet]
        )

        let result = LanguageMemoryPostProcessor.applyDeterministic(
            to: "call my company today",
            snapshot: snapshot,
            language: .en
        )

        #expect(result.text == "call Acme Corp today")
        #expect(result.replacementRuleIDs == [rule.id])
        #expect(result.snippetIDs == [snippet.id])
    }

    @Test func testPassTwoRunsWithoutSnippetsWhenLaterRuleCreatesEarlierMatch() {
        // Rules apply sequentially over the evolving text, longest match
        // first: "the cat" has already missed when "teh -> the" creates its
        // target. There are no snippets at all, so a snippet-only skip
        // condition would leave "the cat" unresolved — pass two must run
        // because pass one changed the text.
        let tehRule = ReplacementRule(match: "teh", replacement: "the")
        let catRule = ReplacementRule(match: "the cat", replacement: "a cat")
        let snapshot = LanguageMemorySnapshot(replacements: [tehRule, catRule])

        let result = LanguageMemoryPostProcessor.applyDeterministic(
            to: "teh cat sat",
            snapshot: snapshot,
            language: .en
        )

        #expect(result.text == "a cat sat")
        #expect(result.replacementRuleIDs == [tehRule.id, catRule.id])
    }

    @Test func testLaterRuleSeesEarlierRulesOutputWithinPassOne() {
        // Same cascade resolved inside a single pass: the longer rule runs
        // first, and the shorter rule sees its output immediately.
        let first = ReplacementRule(match: "hello world", replacement: "hi world")
        let second = ReplacementRule(match: "hi", replacement: "hey")
        let snapshot = LanguageMemorySnapshot(replacements: [first, second])

        let result = LanguageMemoryPostProcessor.applyDeterministic(
            to: "hello world",
            snapshot: snapshot,
            language: .en
        )

        #expect(result.text == "hey world")
        #expect(result.replacementRuleIDs == [first.id, second.id])
    }

    @Test func testSnippetIntroducesMatchButFiredRuleIsNotReapplied() {
        // Strengthens the Karko regression: the alias rule fires in pass one,
        // then a snippet introduces a fresh "Karko". Pass two runs (the text
        // changed twice) but must not re-run the fired rule — "Karko AI AI"
        // is the corruption the fired-rule filter exists to prevent.
        let term = MemoryTerm(phrase: "Karko AI", aliases: ["Karko"], priority: .always)
        let snippet = MemorySnippet(trigger: "signoff", expansion: "Karko")
        let snapshot = LanguageMemorySnapshot(
            terms: [term],
            snippets: [snippet]
        )

        let result = LanguageMemoryPostProcessor.applyDeterministic(
            to: "Karko signoff",
            snapshot: snapshot,
            language: .en
        )

        #expect(result.text == "Karko AI Karko")
        #expect(result.replacementRuleIDs.count == 1)
        #expect(result.snippetIDs == [snippet.id])
    }

    @Test func testMemoryHitIDsDedupeAcrossPartiallyDistinctTextVariants() {
        // Pass one changes the text but snippets and pass two do not, so only
        // two of the four variants are distinct. The same term matches in
        // both and must be reported exactly once.
        let term = MemoryTerm(phrase: "Claude Code", priority: .always)
        let rule = ReplacementRule(match: "g p t", replacement: "GPT")
        let snapshot = LanguageMemorySnapshot(
            terms: [term],
            replacements: [rule]
        )

        let result = LanguageMemoryPostProcessor.applyDeterministic(
            to: "use claude code and g p t",
            snapshot: snapshot,
            language: .en
        )

        #expect(result.text == "use Claude Code and GPT")
        #expect(result.memoryHitIDs == [term.id])
    }

    @Test func testFormattedResultMergesIDsInFirstSeenOrderWithDuplicatesInterleaved() {
        // prepared contributes [X, Y] / [termA]; final contributes [Y, Z] /
        // [termA, termB]. First-seen order across the interleaved duplicates
        // must be [X, Y, Z] and [termA, termB].
        let ruleX = ReplacementRule(match: "zxq", replacement: "X1")
        let ruleY = ReplacementRule(match: "zyq", replacement: "Y1")
        let ruleZ = ReplacementRule(match: "zzq", replacement: "Z1")
        let termA = MemoryTerm(phrase: "axlotl")
        let termB = MemoryTerm(phrase: "bison")
        let snapshot = LanguageMemorySnapshot(
            terms: [termA, termB],
            replacements: [ruleX, ruleY, ruleZ]
        )

        let prepared = LanguageMemoryPostProcessor.applyDeterministic(
            to: "axlotl zxq zyq",
            snapshot: snapshot,
            language: .en
        )
        let formatted = FormattingResult(
            text: "zyq zzq axlotl bison",
            newTerms: [],
            mode: .formatted
        )

        let result = LanguageMemoryPostProcessor.formattedResult(
            prepared: prepared,
            formatted: formatted,
            snapshot: snapshot,
            language: .en
        )

        #expect(result.text == "Y1 Z1 axlotl bison")
        #expect(result.replacementRuleIDs == [ruleX.id, ruleY.id, ruleZ.id])
        #expect(result.memoryHitIDs == [termA.id, termB.id])
    }
}
