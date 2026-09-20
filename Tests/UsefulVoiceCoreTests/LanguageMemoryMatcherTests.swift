import Foundation
import Testing
@testable import UsefulVoiceCore

@Suite struct LanguageMemoryMatcherTests {
    @Test func testCanonicalMatchesCaseHyphenAndPossessive() {
        #expect(LanguageMemoryMatcher.canonical("Claude-Code's") == "claude code")
    }

    @Test func testWordBoundaryDoesNotReplaceInsideWord() {
        #expect(LanguageMemoryMatcher.containsWordBoundaryPhrase("cloud code", in: "use cloud code today"))
        #expect(!LanguageMemoryMatcher.containsWordBoundaryPhrase("cloud", in: "cloudflare"))
    }

    @Test func testWordBoundarySupportsTechnicalPunctuation() {
        #expect(LanguageMemoryMatcher.containsWordBoundaryPhrase("C++", in: "use C++ here"))
        #expect(LanguageMemoryMatcher.containsWordBoundaryPhrase("gpt-4o", in: "choose gpt-4o today"))
    }

    @Test func testMatchingTermIDsIncludeAliasesAndPronunciationsWithLanguageFilter() {
        let englishID = UUID()
        let germanID = UUID()
        let terms = [
            MemoryTerm(
                id: englishID,
                phrase: "Claude Code",
                pronunciations: ["cloud code"],
                aliases: ["Claude"],
                language: .en
            ),
            MemoryTerm(
                id: germanID,
                phrase: "Zettelkasten",
                language: .de
            ),
        ]

        let hits = LanguageMemoryMatcher.matchingTermIDs(
            terms,
            in: "please use cloud code here",
            language: .en
        )

        #expect(hits == [englishID])
        #expect(LanguageMemoryMatcher.matchingTermIDs(
            terms,
            in: "zettelkasten",
            language: .en
        ).isEmpty)
    }

    @Test func testRegexCacheKeepsEarlierPhrasesAfterOverflow() {
        // The 4,096 bound limits what is retained, not what works: once the
        // cache is full, new phrases compile uncached while entries that were
        // already cached stay hot. Clearing at the bound would evict a large
        // dictionary's own hot phrases.
        //
        // Note: this test permanently saturates the process-wide static cache
        // for the rest of the suite — deterministic today because no other
        // test mass-inserts phrases and entries are never evicted, but a
        // future test that fills the cache first would change what it sees.
        let earlyPhrase = "cache residency probe zxqv"
        let first = LanguageMemoryMatcher.wordBoundaryRegex(for: earlyPhrase)
        #expect(first != nil)

        // Push past the bound with distinct phrases so the cache fills up.
        for index in 0..<4_200 {
            _ = LanguageMemoryMatcher.wordBoundaryRegex(for: "cache filler phrase \(index)")
        }

        // The early phrase is still served from the cache — the same instance.
        let again = LanguageMemoryMatcher.wordBoundaryRegex(for: earlyPhrase)
        #expect(first === again)
        #expect(LanguageMemoryMatcher.containsWordBoundaryPhrase(
            earlyPhrase,
            in: "the cache residency probe zxqv still matches"
        ))

        // A phrase first compiled past the bound is not retained — each call
        // returns a fresh instance — but it still compiles and matches.
        let overBound = "overflow probe zztop"
        let overBoundFirst = LanguageMemoryMatcher.wordBoundaryRegex(for: overBound)
        let overBoundSecond = LanguageMemoryMatcher.wordBoundaryRegex(for: overBound)
        #expect(overBoundFirst != nil)
        #expect(overBoundFirst !== overBoundSecond)
        #expect(LanguageMemoryMatcher.containsWordBoundaryPhrase(
            overBound,
            in: "an overflow probe zztop works"
        ))
    }
}
