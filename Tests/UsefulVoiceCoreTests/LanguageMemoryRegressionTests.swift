import Foundation
import Testing
@testable import UsefulVoiceCore

/// Regressions for defects found in the language-memory audit that silently
/// corrupted delivered text.
@Suite struct LanguageMemoryRegressionTests {

    // MARK: - MEM-01: dictionary casing must not rewrite inside words

    @Test func testDictionaryTermCasingDoesNotRewriteSubstrings() {
        // "AI" is an extremely likely dictionary entry, and it is also a
        // substring of many ordinary words. The synthetic case-normalization
        // rule used to be a plain substring replace, so saving the term "AI"
        // turned "I said email is available" into "I sAId emAIl is avAIlable".
        let term = MemoryTerm(phrase: "AI", priority: .always)
        let snapshot = LanguageMemorySnapshot(terms: [term])
        let result = LanguageMemoryPostProcessor.rawResult(
            for: "I said email is available and certain",
            snapshot: snapshot,
            language: .en
        )
        #expect(result.text == "I said email is available and certain")
    }

    @Test func testDictionaryTermCasingStillFixesRealCasing() {
        // The intended behaviour must survive the word-boundary fix.
        let term = MemoryTerm(phrase: "Claude Code", priority: .always)
        let snapshot = LanguageMemorySnapshot(terms: [term])
        let result = LanguageMemoryPostProcessor.rawResult(
            for: "open claude code please",
            snapshot: snapshot,
            language: .en
        )
        #expect(result.text == "open Claude Code please")
    }

    @Test func testShortTermDoesNotCorruptLargerWords() {
        // Same class as above with a technical abbreviation.
        let term = MemoryTerm(phrase: "API", priority: .high)
        let snapshot = LanguageMemorySnapshot(terms: [term])
        let result = LanguageMemoryPostProcessor.rawResult(
            for: "the therapist was rapid",
            snapshot: snapshot,
            language: .en
        )
        #expect(result.text == "the therapist was rapid")
    }

    // MARK: - MEM-02: rules must not be applied twice

    @Test func testSelfContainingRuleIsNotAppliedTwice() {
        // An alias whose replacement contains its own match. The post-processor
        // applies rules, expands snippets, then applies rules again; without the
        // first-pass filter this produced "Karko AI AI".
        let term = MemoryTerm(phrase: "Karko AI", aliases: ["Karko"], priority: .always)
        let snapshot = LanguageMemorySnapshot(terms: [term])
        let result = LanguageMemoryPostProcessor.rawResult(
            for: "Karko",
            snapshot: snapshot,
            language: .en
        )
        #expect(result.text == "Karko AI")
    }

    @Test func testSelfContainingRuleIsNotTripled() {
        let term = MemoryTerm(phrase: "Useful Voice", pronunciations: ["Useful"], priority: .always)
        let snapshot = LanguageMemorySnapshot(terms: [term])
        let result = LanguageMemoryPostProcessor.rawResult(
            for: "Useful is great",
            snapshot: snapshot,
            language: .en
        )
        #expect(result.text == "Useful Voice is great")
    }

    // MARK: - MEM-12: Unicode normalization

    @Test func testCanonicalFoldsUnicodeNormalizationForms() {
        // NFC and NFD spellings of the same German word must produce the same
        // key. macOS text fields tend to produce NFC while STT output and file
        // round-trips often produce NFD; without folding, regex matching and
        // dictionary keys see two different terms and two rules end up
        // rewriting each other.
        //
        // NOTE: Swift's `==` already treats these as equal (canonical
        // equivalence), so the scalars must be compared to prove the fixtures
        // really are different byte sequences — an `==` guard would be a no-op.
        let nfc = "M\u{00FC}ller"          // ü as one scalar
        let nfd = "Mu\u{0308}ller"          // u + combining diaeresis
        #expect(nfc.unicodeScalars.map(\.value) != nfd.unicodeScalars.map(\.value))

        #expect(TermMatcher.canonical(nfc) == TermMatcher.canonical(nfd))
        #expect(TermMatcher.matches(nfc, nfd))

        // The canonical key must be composed, not decomposed, so dictionary
        // lookups and keyterm de-duplication agree with the NFC on-disk form.
        let canonical = TermMatcher.canonical(nfd)
        #expect(canonical.unicodeScalars.map(\.value)
                == TermMatcher.canonical(nfc).unicodeScalars.map(\.value))
    }

    @Test func testNFCandNFDTermsAreNotDuplicatedInBiasSelection() {
        // The audit's MEM-12 scenario: the same name saved in both normal forms
        // must not consume two keyterm slots.
        let terms = [
            MemoryTerm(phrase: "M\u{00FC}ller", priority: .high),
            MemoryTerm(phrase: "Mu\u{0308}ller", priority: .high),
        ]
        let selection = MemoryBiasBuilder.boundedSelection(
            terms: terms,
            baseVocabulary: [],
            budget: 100,
            language: .en
        )
        #expect(selection.terms.count == 1)
        #expect(selection.duplicateCount == 1)
    }

    @Test func testCanonicalFoldsNormalizationWithCaseAndSpacing() {
        let decomposed = "  Z\u{0075}\u{0308}rich-Office  "
        let composed = "Z\u{00FC}rich Office"
        #expect(TermMatcher.canonical(decomposed) == TermMatcher.canonical(composed))
    }

    // MARK: - MEM-17: deterministic rule ordering

    @Test func testRuleOrderIsDeterministicForEqualLengthMatches() {
        // Equal-length rules must not depend on locale or on the sort's
        // stability, so the same dictionary always produces the same text.
        let terms = [
            MemoryTerm(phrase: "Delta Force", aliases: ["DF unit"], priority: .always),
            MemoryTerm(phrase: "Bravo Squad", aliases: ["BS unit"], priority: .always),
        ]
        let snapshot = LanguageMemorySnapshot(terms: terms)
        let first = DictionaryCorrector.effectiveRules(from: snapshot, language: .en)
            .map(\.match)
        let second = DictionaryCorrector.effectiveRules(from: snapshot, language: .en)
            .map(\.match)
        #expect(first == second)
    }
}

/// Regressions for the Deepgram keyterm token ceiling (a hard request failure:
/// exceeding 500 tokens returns "Keyterm limit exceeded" and breaks *every*
/// dictation, not just the oversized one).
@Suite struct KeytermBudgetTests {

    @Test func testBudgetIsBelowHardLimit() {
        #expect(KeytermBudget.hardTokenLimit == 500)
        #expect(KeytermBudget.tokenBudget < KeytermBudget.hardTokenLimit)
        #expect(KeytermBudget.tokenBudget + KeytermBudget.safetyMarginTokens
                <= KeytermBudget.hardTokenLimit)
    }

    @Test func testEstimatorIsConservativeNotOptimistic() {
        // The estimator must never undercount. Real BPE tokenizers split
        // technical terms and digits aggressively, so the estimate errs high on
        // purpose: the whole point is to stay under Deepgram's 500-token ceiling
        // for every dictionary, not to squeeze in the maximum number of terms.
        #expect(KeytermBudget.estimatedTokens(for: "Kubernetes") >= 1)
        #expect(KeytermBudget.estimatedTokens(for: "claude code")
                > KeytermBudget.estimatedTokens(for: "claude"))
        #expect(KeytermBudget.estimatedTokens(for: "next js app router")
                > KeytermBudget.estimatedTokens(for: "next"))
    }

    @Test func testEmptyTermCostsNothing() {
        #expect(KeytermBudget.estimatedTokens(for: "") == 0)
        #expect(KeytermBudget.estimatedTokens(for: "   ") == 0)
    }

    @Test func testSeparatorsAndDigitsCostExtraTokens() {
        // Punctuation is usually its own token, so a hyphenated or versioned term
        // costs more than a plain word of the same length.
        #expect(KeytermBudget.estimatedTokens(for: "GPT-4")
                > KeytermBudget.estimatedTokens(for: "GPT4"))
    }

    @Test func testLongIdentifierCostsMoreThanOneToken() {
        // A single "word" that is really a long identifier is split by the
        // tokenizer; the estimate must not treat it as free.
        let tokens = KeytermBudget.estimatedTokens(for: "extremelyLongIdentifierName")
        #expect(tokens > 1)
    }

    @Test func testHundredTermsOfTwoWordsFitBudget() {
        // The realistic worst case: 100 two-word terms.
        let terms = (0..<100).map { "term\($0) name" }
        let total = terms.reduce(0) { $0 + KeytermBudget.estimatedTokens(for: $1) }
        #expect(total <= KeytermBudget.tokenBudget)
    }

    @Test func testRejectsTermsDeepgramCannotUse() {
        #expect(!KeytermBudget.isSendableKeyterm(""))
        #expect(!KeytermBudget.isSendableKeyterm("   "))
        #expect(!KeytermBudget.isSendableKeyterm("!!!"))
        #expect(!KeytermBudget.isSendableKeyterm(String(repeating: "a", count: 65)))
        #expect(!KeytermBudget.isSendableKeyterm("bad\u{0007}term"))
    }

    @Test func testAcceptsRealTerms() {
        #expect(KeytermBudget.isSendableKeyterm("Kubernetes"))
        #expect(KeytermBudget.isSendableKeyterm("gpt-4o"))
        #expect(KeytermBudget.isSendableKeyterm("Claude Code"))
        #expect(KeytermBudget.isSendableKeyterm("Zürich"))
    }

    @Test func testExceedsBudgetDetectsOversizedInput() {
        #expect(!KeytermBudget.exceedsBudget(["one", "two"]))
        let huge = (0..<600).map { "word\($0)" }
        #expect(KeytermBudget.exceedsBudget(huge))
    }

    @Test func testBiasSelectionStaysInsideBudgetAndCountsDrops() {
        // 400 multi-word terms would be 800 tokens: over the ceiling. The
        // selection must bound itself and report what it dropped.
        let terms = (0..<400).map { index in
            MemoryTerm(phrase: "multi word term \(index)", priority: .high)
        }
        let selection = MemoryBiasBuilder.boundedSelection(
            terms: terms,
            baseVocabulary: [],
            budget: 100,
            language: .en
        )

        #expect(selection.terms.count <= KeytermBudget.maxTerms)
        #expect(selection.estimatedTokens <= KeytermBudget.tokenBudget)
        #expect(selection.isOverCapacity)
        #expect(selection.droppedCount > 0)
    }

    @Test func testBiasSelectionIncludesBaseVocabularyWithinBudget() {
        let selection = MemoryBiasBuilder.boundedSelection(
            terms: [],
            baseVocabulary: BaseVocabulary.terms,
            budget: 100,
            language: .en
        )
        #expect(!selection.terms.isEmpty)
        #expect(selection.estimatedTokens <= KeytermBudget.tokenBudget)
        #expect(selection.terms.allSatisfy { KeytermBudget.isSendableKeyterm($0) })
    }

    @Test func testBiasSelectionRejectsUnusableTermsAndCountsThem() {
        let terms = [
            MemoryTerm(phrase: "Valid Term", priority: .high),
            MemoryTerm(phrase: "!!!", priority: .high),
            MemoryTerm(phrase: String(repeating: "x", count: 200), priority: .high),
        ]
        let selection = MemoryBiasBuilder.boundedSelection(
            terms: terms,
            baseVocabulary: [],
            budget: 100,
            language: .en
        )
        #expect(selection.terms == ["Valid Term"])
        #expect(selection.rejectedCount == 2)
        #expect(selection.omittedCount == 2)
    }

    @Test func testBiasSelectionNeverSendsPronunciationsAsKeyterms() {
        // Misheard forms must never bias the model toward the mistake.
        let term = MemoryTerm(
            phrase: "Kubernetes",
            pronunciations: ["coopernetes", "kubernets"],
            priority: .always
        )
        let selection = MemoryBiasBuilder.boundedSelection(
            terms: [term],
            baseVocabulary: [],
            budget: 100,
            language: .en
        )
        #expect(selection.terms == ["Kubernetes"])
    }

    @Test func testDuplicateTermsAreCountedSeparatelyFromDrops() {
        // Two spellings of the same term. Which one wins is decided by the
        // ranking sort, so assert the invariant (exactly one survives, and it is
        // a real spelling of the term) rather than a specific case.
        let terms = [
            MemoryTerm(phrase: "Claude Code", priority: .high),
            MemoryTerm(phrase: "claude code", priority: .high),
        ]
        let selection = MemoryBiasBuilder.boundedSelection(
            terms: terms,
            baseVocabulary: [],
            budget: 100,
            language: .en
        )
        #expect(selection.terms.count == 1)
        #expect(TermMatcher.canonical(selection.terms[0]) == "claude code")
        #expect(selection.duplicateCount == 1)
        #expect(selection.droppedCount == 0)
        #expect(!selection.isOverCapacity)
    }

    @Test func testZeroBudgetReturnsNothing() {
        let selection = MemoryBiasBuilder.boundedSelection(
            terms: [MemoryTerm(phrase: "Claude Code", priority: .always)],
            baseVocabulary: BaseVocabulary.terms,
            budget: 0,
            language: .en
        )
        #expect(selection.terms.isEmpty)
    }
}
