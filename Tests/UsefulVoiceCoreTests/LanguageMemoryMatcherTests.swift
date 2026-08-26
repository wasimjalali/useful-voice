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
}
