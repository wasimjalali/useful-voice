import Testing
import Foundation
@testable import UsefulVoiceCore

/// The language catalogue is a large hand-transcribed data set, and every way it
/// can be wrong is silent: a mistyped code still sends, Deepgram still answers, and
/// the user just gets worse transcription in a language they thought they picked.
/// These tests pin the properties that matter, taken from Deepgram's published
/// Nova-3 language table.
@Suite("Deepgram language catalogue")
struct DeepgramLanguageCatalogTests {

    @Test func testCatalogueIsNotEmptyAndHasTheFullNova3Set() {
        // Deepgram documents 63 named languages for Nova-3. The catalogue collapses
        // regional variants, so it holds fewer entries than the 105 code strings —
        // but far more than the ten it started with.
        #expect(DeepgramLanguageCatalog.all.count >= 60)
    }

    @Test func testEveryLanguageIsWellFormed() {
        for language in DeepgramLanguageCatalog.all {
            #expect(!language.code.isEmpty, "empty code")
            #expect(!language.name.isEmpty, "empty name for \(language.code)")
            #expect(!language.nativeName.isEmpty, "empty native name for \(language.code)")
            // Codes are BCP-47-ish: lowercase language, optional region suffix.
            // `zh-HK` is the only two-part form kept, and it keeps its case.
            #expect(!language.code.contains(" "), "code with a space: \(language.code)")
            #expect(language.code == language.code.trimmingCharacters(in: .whitespaces))
        }
    }

    @Test func testCodesAreUnique() {
        // A duplicate would make one of the two rows unselectable, since selection
        // is by code.
        let codes = DeepgramLanguageCatalog.all.map(\.code)
        #expect(Set(codes).count == codes.count)
        let names = DeepgramLanguageCatalog.all.map(\.name)
        #expect(Set(names).count == names.count, "duplicate display name")
    }

    @Test func testCatalogueIsSortedByDisplayName() {
        // The picker renders in catalogue order, so an unsorted list reads as if it
        // were randomly ordered.
        let names = DeepgramLanguageCatalog.all.map(\.name)
        #expect(names == names.sorted())
    }

    /// The languages that were in the original ten-entry catalogue must survive:
    /// existing users have terms and replacements scoped to them.
    @Test func testPreviouslyOfferedLanguagesAreStillPresent() {
        for code in ["nl", "en", "fr", "de", "hi", "it", "ja", "pt", "ru", "es"] {
            #expect(DeepgramLanguageCatalog.isSupported(code), "\(code) was dropped")
        }
    }

    /// Collapsing regional variants is only safe where the docs say output is
    /// normalised. English spelling is; Cantonese is not Mandarin.
    @Test func testRegionalVariantsAreCollapsedOnlyWhereLossless() {
        // English variants collapse to `en` — spelling is standardised regardless
        // of which English code is sent.
        #expect(!DeepgramLanguageCatalog.isSupported("en-US"))
        #expect(!DeepgramLanguageCatalog.isSupported("en-GB"))
        #expect(DeepgramLanguageCatalog.isSupported("en"))
        // Cantonese and Mandarin are different spoken languages.
        #expect(DeepgramLanguageCatalog.isSupported("zh-HK"))
        #expect(DeepgramLanguageCatalog.isSupported("zh"))
        #expect(DeepgramLanguageCatalog.isSupported("zh-TW"))
        // Swiss German and Flemish are named separately by Deepgram.
        #expect(DeepgramLanguageCatalog.isSupported("de-CH"))
        #expect(DeepgramLanguageCatalog.isSupported("nl-BE"))
    }

    @Test func testMultilingualIsSelectableButNotALanguageRow() {
        // `multi` is a mode, so it resolves through `language(for:)` but is not in
        // the language list the picker renders under its divider.
        #expect(DeepgramLanguageCatalog.isSupported("multi"))
        #expect(DeepgramLanguageCatalog.language(for: "multi")?.code == "multi")
        #expect(!DeepgramLanguageCatalog.all.contains { $0.code == "multi" })
    }

    // MARK: - Detection

    /// `detect_language` supports a smaller set than Nova-3 speaks, and mixing the
    /// two up is the documented route to a silent model downgrade.
    @Test func testDetectionCodesAreExactlyTheDocumentedSet() {
        #expect(DeepgramLanguageCatalog.detectionCodes.count == 35)
        let expected = Set(["bg", "ca", "cs", "da", "de", "de-CH", "el", "en", "es",
                            "et", "fi", "fr", "hi", "hu", "id", "it", "ja", "ko",
                            "lt", "lv", "ms", "nl", "nl-BE", "no", "pl", "pt", "ro",
                            "ru", "sk", "sv", "th", "tr", "uk", "vi", "zh"])
        #expect(Set(DeepgramLanguageCatalog.detectionCodes) == expected)
    }

    @Test func testDetectionCodesAreASubsetOfTheCatalogue() {
        // A detection code the picker cannot offer would be unreachable: the user
        // could never pin the language that detection keeps returning.
        for code in DeepgramLanguageCatalog.detectionCodes {
            #expect(DeepgramLanguageCatalog.isSupported(code),
                    "detection code \(code) is not in the pinned-language catalogue")
        }
    }

    @Test func testDetectionCodesAreNotTheWholeCatalogue() {
        // If these ever become equal, the "smaller detection set" reasoning has
        // stopped being true and the request would start asking detection for
        // codes it cannot return.
        #expect(DeepgramLanguageCatalog.detectionCodes.count
                < DeepgramLanguageCatalog.all.count)
    }

    /// A detected language outside Nova-3 means the provider fell back to a lower
    /// model and `keyterm` was dropped — the dictionary silently stopped working.
    @Test func testDetectedLanguageIsCheckedAgainstNova3Coverage() {
        #expect(DeepgramLanguageCatalog.detectionStayedOnNova3("en"))
        #expect(DeepgramLanguageCatalog.detectionStayedOnNova3("de"))
        #expect(DeepgramLanguageCatalog.detectionStayedOnNova3("zh-HK"))
        #expect(DeepgramLanguageCatalog.detectionStayedOnNova3("en-US"))
    }

    // MARK: - Spoken punctuation

    /// Deepgram documents Dictation as "English (all available regions)" only.
    @Test func testSpokenPunctuationIsEnglishOnly() {
        #expect(DeepgramLanguageCatalog.supportsSpokenPunctuation("en"))
        #expect(DeepgramLanguageCatalog.supportsSpokenPunctuation("en-US"))
        #expect(!DeepgramLanguageCatalog.supportsSpokenPunctuation("de"))
        #expect(!DeepgramLanguageCatalog.supportsSpokenPunctuation("es"))
        #expect(!DeepgramLanguageCatalog.supportsSpokenPunctuation("zh-HK"))
        #expect(!DeepgramLanguageCatalog.supportsSpokenPunctuation("multi"))
        #expect(!DeepgramLanguageCatalog.supportsSpokenPunctuation("auto"))
    }
}

/// `LanguagePin` is stored in `UserDefaults` as a plain string, so its behaviour
/// around unknown values decides whether an upgrade can leave a user stroking a
/// language the catalogue no longer offers.
@Suite("Language pin")
struct LanguagePinTests {

    @Test func testKnownCodesRoundTrip() {
        for pin in LanguagePin.allCases {
            #expect(LanguagePin(code: pin.rawValue) == pin, "\(pin.rawValue) did not round-trip")
        }
    }

    @Test func testUnknownAndEmptyCodesFallBackToDetection() {
        // Sending an unsupported language would fail at the provider, so an
        // unrecognised stored value degrades to detection instead.
        #expect(LanguagePin(code: "") == .auto)
        #expect(LanguagePin(code: "   ") == .auto)
        #expect(LanguagePin(code: "klingon") == .auto)
        // A code that used to be offered and no longer is.
        #expect(LanguagePin(code: "xx-YY") == .auto)
    }

    @Test func testCodesAreNormalised() {
        #expect(LanguagePin(code: "DE") == .de)
        #expect(LanguagePin(code: " de ") == .de)
        #expect(LanguagePin(code: "AUTO") == .auto)
    }

    @Test func testModesComeFirstAndAreNotLanguages() {
        #expect(LanguagePin.allCases.prefix(2) == [.auto, .multilingual])
        #expect(LanguagePin.auto.isAuto)
        #expect(LanguagePin.multilingual.isMultilingual)
        #expect(!LanguagePin.de.isAuto)
        #expect(!LanguagePin.de.isMultilingual)
    }

    @Test func testDisplayNamesNeverLeakRawCodes() {
        // Every offered value has to be describable in a menu.
        for pin in LanguagePin.allCases {
            #expect(!pin.displayName.isEmpty)
            #expect(pin.displayName != pin.rawValue, "\(pin.rawValue) shows its raw code")
        }
        #expect(LanguagePin.auto.displayName == "Detect automatically")
        #expect(LanguagePin.multilingual.displayName == "Multiple languages")
        #expect(LanguagePin.de.displayName == "German")
    }

    /// Spoken punctuation is English-only, and the two modes cannot promise it:
    /// detection has not identified a language yet, and code-switching may include
    /// non-English.
    @Test func testSpokenPunctuationIsOffForModesAndNonEnglish() {
        #expect(LanguagePin.en.supportsSpokenPunctuation)
        #expect(!LanguagePin.de.supportsSpokenPunctuation)
        #expect(!LanguagePin.auto.supportsSpokenPunctuation)
        #expect(!LanguagePin.multilingual.supportsSpokenPunctuation)
    }

    @Test func testOnlyAutoUsesDetection() {
        #expect(LanguagePin.auto.usesDetection)
        #expect(!LanguagePin.multilingual.usesDetection)
        #expect(!LanguagePin.de.usesDetection)
        // `multi` is sent as `language=multi`, which is valid on Nova-3 pre-recorded.
        #expect(LanguagePin.multilingual.sendsLanguageParameter)
    }

    @Test func testQuickToggledStillAlternatesEnglishAndGerman() {
        // Retained for the keyboard path even though the hotkey now opens a picker:
        // cycling cannot reach 60+ languages, but a "next" value is still defined.
        #expect(LanguagePin.en.quickToggled == .de)
        #expect(LanguagePin.de.quickToggled == .en)
        #expect(LanguagePin.auto.quickToggled == .en)
    }

    /// Existing installs have `"en"`/`"de"`/`"auto"` (and, on Windows, `"multi"`)
    /// stored. None of those may become invalid.
    @Test func testLegacyStoredValuesStillResolve() {
        #expect(LanguagePin(code: "auto") == .auto)
        #expect(LanguagePin(code: "en") == .en)
        #expect(LanguagePin(code: "de") == .de)
        #expect(LanguagePin(code: "multi") == .multilingual)
    }
}

/// `MemoryLanguage` is persisted inside `language-memory.json`, so it must decode
/// values it does not know rather than throwing — a throw would fail the store load
/// and make the whole dictionary unwritable.
@Suite("Memory language persistence")
struct MemoryLanguageTests {

    @Test func testDecodesKnownValues() {
        for raw in ["auto", "en", "de", "multi", "ja"] {
            let decoded = try? JSONDecoder().decode(
                MemoryLanguage.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded?.rawValue == raw)
        }
    }

    @Test func testDecodesAnUnknownCodeWithoutThrowing() throws {
        // A term scoped to a language a future build drops must not take the store
        // down with it.
        let decoded = try JSONDecoder().decode(
            MemoryLanguage.self, from: Data("\"klingon\"".utf8))
        #expect(decoded.rawValue == "klingon")
    }

    @Test func testDecodesGarbageWithoutThrowing() throws {
        // Numbers, nulls and objects all have to survive, because the alternative
        // is refusing to write the user's dictionary.
        for payload in ["123", "null", "{}", "[]"] {
            let decoded = try JSONDecoder().decode(
                MemoryLanguage.self, from: Data(payload.utf8))
            #expect(decoded == .auto, "\(payload) should fall back to auto")
        }
    }

    @Test func testRoundTripsThroughJSON() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for language in MemoryLanguage.allCases {
            let data = try encoder.encode(language)
            // Encoded as a bare string, matching the on-disk format.
            #expect(String(decoding: data, as: UTF8.self) == "\"\(language.rawValue)\"")
            #expect(try decoder.decode(MemoryLanguage.self, from: data) == language)
        }
    }

    @Test func testMapsToAndFromPin() {
        #expect(MemoryLanguage(languagePin: .auto) == .auto)
        #expect(MemoryLanguage(languagePin: .de).pin == .de)
        #expect(MemoryLanguage(languagePin: .multilingual).pin == .multilingual)
        #expect(MemoryLanguage(rawValue: "ja").pin == LanguagePin(rawValue: "ja"))
        // An unlisted value maps to detection, matching `LanguagePin(code:)`.
        #expect(MemoryLanguage(rawValue: "klingon").pin == .auto)
    }

    @Test func testCoversEveryPinnableLanguage() {
        // Every language a term can be scoped to must be one the user can pin.
        #expect(MemoryLanguage.allCases.count == LanguagePin.allCases.count)
    }
}

/// The user has real data on disk. `MemoryLanguage` changed from a failable enum to
/// a struct, and `language-memory.json` stores it as a bare JSON string — so the
/// encoding has to be unchanged, byte for byte, or existing stores stop decoding.
/// These tests pin the format rather than trusting it.
@Suite("Memory language on-disk compatibility")
struct MemoryLanguageCompatibilityTests {

    /// Every language value as the OLD enum would have written it. An enum with a
    /// `String` raw value and no custom `Codable` conformance encodes as a plain
    /// string, so the struct must do the same rather than switching to, say, a
    /// keyed container `{"rawValue": "en"}`.
    @Test func testEncodesAsABareJSONString() throws {
        let encoder = JSONEncoder()
        for raw in ["auto", "en", "de"] {
            let data = try encoder.encode(MemoryLanguage(rawValue: raw))
            #expect(String(decoding: data, as: UTF8.self) == "\"\(raw)\"")
        }
    }

    /// The dates in the store use ISO 8601, so decode with the store's exact
    /// strategies rather than defaults, or this would test the wrong thing.
    private static func storeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func storeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Decode the *live* store if it is present and prove a round trip preserves it.
    ///
    /// Skipped on CI and on any machine without the file; it exists to be run against
    /// a real install, which unit fixtures cannot substitute for.
    @Test func testLiveStoreSurvivesARoundTrip() throws {
        let path = ("~/Library/Application Support/Sadaa/language-memory.json" as NSString)
            .expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        guard let original = try? Data(contentsOf: url) else { return }

        // The live file is the versioned wrapper, not a bare snapshot; decoding the
        // wrapper is what the store itself does on load.
        let persisted = try Self.storeDecoder().decode(LanguageMemoryPersisted.self, from: original)
        let snapshot = persisted.snapshot
        let reencoded = try Self.storeEncoder().encode(persisted)
        let decodedAgain = try Self.storeDecoder()
            .decode(LanguageMemoryPersisted.self, from: reencoded).snapshot

        // Nothing lost: comparing the re-serialised forms normalises key ordering,
        // which JSONEncoder does not guarantee, without weakening the check.
        let normalise: (Data) throws -> String = { data in
            let object = try JSONSerialization.jsonObject(with: data)
            let sorted = try JSONSerialization.data(withJSONObject: object,
                                                    options: [.sortedKeys])
            return String(decoding: sorted, as: UTF8.self)
        }
        #expect(try normalise(reencoded) == normalise(original),
                "a round trip through the new MemoryLanguage changed the stored data")

        // And the contents still agree with what was read.
        #expect(decodedAgain.terms.count == snapshot.terms.count)
        #expect(decodedAgain.replacements.count == snapshot.replacements.count)
        for (before, after) in zip(snapshot.terms, decodedAgain.terms) {
            #expect(before.language == after.language)
            #expect(before.phrase == after.phrase)
        }
    }

    /// The enum accepted only three values, so a store written by an older build can
    /// only contain those. All three must still decode.
    @Test func testEveryValueTheOldEnumCouldWriteStillDecodes() throws {
        for raw in ["auto", "en", "de"] {
            let decoded = try Self.storeDecoder().decode(
                MemoryLanguage.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded.rawValue == raw)
            #expect(decoded == MemoryLanguage(rawValue: raw))
        }
    }

    /// A value the old enum could NOT write must still decode rather than throw.
    /// Throwing here would fail the store load, and a store that fails to load is
    /// refused for writing — so one unrecognised language would cost the user their
    /// entire dictionary.
    @Test func testUnrecognisedValuesDoNotFailTheStore() throws {
        for raw in ["", "multi", "klingon", "zh-HK"] {
            let decoded = try Self.storeDecoder().decode(
                MemoryLanguage.self, from: Data("\"\(raw)\"".utf8))
            #expect(decoded.rawValue == raw)
        }
    }
}
