import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct ReplacementEngineTests {
    @Test func testCaseInsensitiveReplacementApplies() {
        let id = UUID()
        let rule = ReplacementRule(
            id: id,
            match: "cloud code",
            replacement: "Claude Code",
            matchMode: .caseInsensitivePhrase,
            language: .auto,
            isEnabled: true
        )
        let result = ReplacementEngine.apply([rule], to: "I use cloud code.", language: .en)
        #expect(result.text == "I use Claude Code.")
        #expect(result.appliedRuleIDs == [id])
    }

    @Test func testWordBoundaryDoesNotReplaceInsideWord() {
        let rule = ReplacementRule(match: "cloud", replacement: "Claude",
                                   matchMode: .wordBoundaryPhrase)
        let result = ReplacementEngine.apply([rule], to: "cloud cloudflare", language: .en)
        #expect(result.text == "Claude cloudflare")
    }

    @Test func testWordBoundaryReplacesTechnicalPunctuationTerms() {
        let rule = ReplacementRule(match: "C++", replacement: "Cpp",
                                   matchMode: .wordBoundaryPhrase)
        let result = ReplacementEngine.apply([rule], to: "Use C++ today.", language: .en)

        #expect(result.text == "Use Cpp today.")
        #expect(result.appliedRuleIDs == [rule.id])
    }

    @Test func testRegexReplacementIsLiteral() {
        let rule = ReplacementRule(match: "price", replacement: "$1.00",
                                   matchMode: .wordBoundaryPhrase)
        let result = ReplacementEngine.apply([rule], to: "price", language: .en)
        #expect(result.text == "$1.00")
    }

    @Test func testDisabledRuleDoesNotApply() {
        let rule = ReplacementRule(match: "x", replacement: "y",
                                   matchMode: .exactPhrase, isEnabled: false)
        #expect(ReplacementEngine.apply([rule], to: "x", language: .en).text == "x")
    }

    @Test func testLanguageSpecificRuleFilters() {
        let rule = ReplacementRule(match: "hallo", replacement: "Hallo",
                                   language: .de)
        #expect(ReplacementEngine.apply([rule], to: "hallo", language: .en).text == "hallo")
        #expect(ReplacementEngine.apply([rule], to: "hallo", language: .de).text == "Hallo")
    }
}
