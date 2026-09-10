import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct LanguageMemoryCSVTests {
    @Test func testExportsAndImportsTermsWithQuotedFields() {
        let now = Date(timeIntervalSince1970: 1)
        let terms = [
            MemoryTerm(
                phrase: "Karko, AI",
                pronunciations: ["car co"],
                aliases: ["Karko"],
                language: .auto,
                priority: .always,
                notes: "Founder \"term\"",
                createdAt: now,
                updatedAt: now
            )
        ]

        let csv = LanguageMemoryCSV.exportTerms(terms)
        let imported = LanguageMemoryCSV.importTerms(csv, now: now)

        #expect(imported.invalid.isEmpty)
        #expect(imported.terms.count == 1)
        #expect(imported.terms.first?.phrase == "Karko, AI")
        #expect(imported.terms.first?.pronunciations == ["car co"])
        #expect(imported.terms.first?.aliases == ["Karko"])
        #expect(imported.terms.first?.priority == .always)
        #expect(imported.terms.first?.notes == "Founder \"term\"")
    }

    @Test func testExportsAndImportsReplacements() {
        let rule = ReplacementRule(
            match: "cloud code",
            replacement: "Claude Code",
            matchMode: .wordBoundaryPhrase,
            language: .en,
            isEnabled: true
        )

        let csv = LanguageMemoryCSV.exportReplacements([rule])
        let imported = LanguageMemoryCSV.importReplacements(csv)

        #expect(imported.invalid.isEmpty)
        #expect(imported.replacements.count == 1)
        #expect(imported.replacements.first?.match == "cloud code")
        #expect(imported.replacements.first?.replacement == "Claude Code")
        #expect(imported.replacements.first?.matchMode == .wordBoundaryPhrase)
        #expect(imported.replacements.first?.language == .en)
        #expect(imported.replacements.first?.isEnabled == true)
    }

    @Test func testInvalidRowsAreReported() {
        let imported = LanguageMemoryCSV.importReplacements("""
        match,replacement,matchMode,language,isEnabled
        ,Claude Code,wordBoundaryPhrase,auto,true
        cloud code,,wordBoundaryPhrase,auto,true
        """)

        #expect(imported.replacements.isEmpty)
        #expect(imported.invalid.count == 2)
    }

    /// An imported language column used to be coerced with `?? .auto`, which was
    /// correct while `MemoryLanguage` was a failable enum. It is a struct over a
    /// string now, so that initialiser never returns nil and the coercion became
    /// dead — meaning an unrecognised cell would be stored verbatim and sent to the
    /// provider. Validation has to be explicit.
    @Test func testImportRejectsAnUnknownLanguageCode() throws {
        let csv = """
        phrase,pronunciations,aliases,language,priority
        Kubernetes,kubernetes,,klingon,high
        """
        let imported = LanguageMemoryCSV.importTerms(csv, now: Date())
        #expect(imported.terms.count == 1)
        #expect(imported.terms.first?.language == .auto)
    }

    @Test func testImportKeepsAKnownLanguageCode() throws {
        let csv = """
        phrase,pronunciations,aliases,language,priority
        Kubernetes,kubernetes,,ja,high
        """
        let imported = LanguageMemoryCSV.importTerms(csv, now: Date())
        #expect(imported.terms.first?.language.rawValue == "ja")
    }

    /// Codes with a meaningful uppercase region subtag must survive import. A
    /// case-folding normaliser turned `zh-HK` into `zh-hk`, matched nothing, and
    /// silently demoted it to auto.
    @Test func testImportPreservesRegionCasing() throws {
        let csv = """
        phrase,pronunciations,aliases,language,priority
        Foo,foo,,zh-HK,high
        """
        let imported = LanguageMemoryCSV.importTerms(csv, now: Date())
        #expect(imported.terms.first?.language.rawValue == "zh-HK")
    }
}
