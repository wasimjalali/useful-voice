import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct MemorySuggestionEngineTests {
    @Test func testAggregatesAndRejectsExistingTerms() {
        let snapshot = LanguageMemorySnapshot(
            terms: [MemoryTerm(phrase: "Karko AI")],
            replacements: [],
            snippets: [],
            suggestions: []
        )
        let suggestions = MemorySuggestionEngine.termSuggestions(
            from: ["Karko AI", "Claude Code", "Claude-Code", "12"],
            snapshot: snapshot,
            now: Date(timeIntervalSince1970: 1)
        )
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.proposed == "Claude Code")
        #expect(suggestions.first?.evidenceCount == 2)
    }
}
