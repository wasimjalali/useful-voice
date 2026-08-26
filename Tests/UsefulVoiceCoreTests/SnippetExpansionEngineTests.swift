import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct SnippetExpansionEngineTests {
    @Test func testExpandsEnabledSnippetWithWordBoundaries() {
        let id = UUID()
        let snippet = MemorySnippet(
            id: id,
            trigger: "my signature",
            expansion: "Best,\nWasim"
        )

        let result = SnippetExpansionEngine.apply(
            [snippet],
            to: "Please add my signature.",
            language: .auto
        )

        #expect(result.text == "Please add Best,\nWasim.")
        #expect(result.appliedSnippetIDs == [id])
    }

    @Test func testDoesNotExpandInsideWordsOrDisabledSnippets() {
        let enabled = MemorySnippet(trigger: "sig", expansion: "signature")
        let disabled = MemorySnippet(trigger: "addr", expansion: "123 Main", isEnabled: false)

        let result = SnippetExpansionEngine.apply(
            [enabled, disabled],
            to: "signal addr",
            language: .auto
        )

        #expect(result.text == "signal addr")
        #expect(result.appliedSnippetIDs.isEmpty)
    }

    @Test func testFiltersByPinnedLanguage() {
        let english = MemorySnippet(trigger: "address", expansion: "123 Main", language: .en)
        let german = MemorySnippet(trigger: "adresse", expansion: "Hauptstrasse 1", language: .de)

        let result = SnippetExpansionEngine.apply(
            [english, german],
            to: "address adresse",
            language: .en
        )

        #expect(result.text == "123 Main adresse")
        #expect(result.appliedSnippetIDs == [english.id])
    }
}
