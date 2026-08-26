import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct DictionaryCorrectorTests {
    @Test func testTermAliasBecomesLocalCorrectionWithoutExplicitRule() {
        let term = MemoryTerm(
            phrase: "Claude Code",
            pronunciations: ["cloud code"],
            priority: .high
        )
        let snapshot = LanguageMemorySnapshot(terms: [term])
        let rules = DictionaryCorrector.effectiveRules(from: snapshot, language: .en)

        let result = ReplacementEngine.apply(rules, to: "I love cloud code.", language: .en)
        #expect(result.text == "I love Claude Code.")
    }

    @Test func testDictionaryPhraseFixesCasing() {
        let term = MemoryTerm(phrase: "Sadaa", priority: .always)
        let snapshot = LanguageMemorySnapshot(terms: [term])
        let rules = DictionaryCorrector.effectiveRules(from: snapshot, language: .auto)

        let result = ReplacementEngine.apply(rules, to: "sadaa is ready", language: .en)
        #expect(result.text == "Sadaa is ready")
    }

    @Test func testExplicitRuleWinsAndLongestMatchPreferred() {
        let term = MemoryTerm(phrase: "Code", aliases: ["code"])
        let rule = ReplacementRule(
            match: "cloud code",
            replacement: "Claude Code",
            matchMode: .wordBoundaryPhrase
        )
        let snapshot = LanguageMemorySnapshot(terms: [term], replacements: [rule])
        let rules = DictionaryCorrector.effectiveRules(from: snapshot, language: .auto)

        let result = ReplacementEngine.apply(rules, to: "try cloud code now", language: .en)
        #expect(result.text == "try Claude Code now")
    }

    @Test func testPostProcessorUsesTermPronunciationsAlone() {
        let term = MemoryTerm(
            phrase: "Kubernetes",
            pronunciations: ["kubernets", "coopernetes"]
        )
        let snapshot = LanguageMemorySnapshot(terms: [term])
        let result = LanguageMemoryPostProcessor.rawResult(
            for: "Scale the kubernets cluster",
            snapshot: snapshot,
            language: .en
        )
        #expect(result.text == "Scale the Kubernetes cluster")
        #expect(result.memoryHitIDs == [term.id])
    }
}
