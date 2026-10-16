import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite(.serialized) struct AppFormattingSettingsTests {
    private let defaults: UserDefaults
    private let settings: AppSettings

    init() {
        defaults = UserDefaults(suiteName: "ai.useful.voice.tests.appformatting")!
        defaults.removePersistentDomain(forName: "ai.useful.voice.tests.appformatting")
        settings = AppSettings(defaults: defaults)
    }

    private func decode(_ json: String) throws -> AppFormattingSettings {
        try JSONDecoder().decode(AppFormattingSettings.self, from: Data(json.utf8))
    }

    // MARK: defaults and old files

    @Test func aStoreWithNothingSavedGivesTheDefaults() {
        let s = settings.appFormatting
        #expect(s.enabled)
        #expect(s.userName == "")
        #expect(s.styles.isEmpty)
        #expect(s.overrides.byApp.isEmpty)
        for category in AppCategory.allCases {
            #expect(s.autoSendKey(for: category) == .off, "\(category)")
            #expect(s.style(for: category) == category.defaultStyle, "\(category)")
        }
    }

    @Test func anOldSettingsStoreLoadsUnchangedAndKeepsItsOwnValues() {
        // A store written before app-aware formatting existed: only the old keys.
        defaults.set("de", forKey: "languagePin")
        defaults.set(45.0, forKey: "silenceTimeout")
        defaults.set(false, forKey: "restorePreviousClipboard")
        defaults.set(["com.apple.Terminal"], forKey: "typeOutAppIDs")
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.appFormatting == .standard)
        #expect(reloaded.languagePin == .de)
        #expect(reloaded.silenceTimeout == 45)
        #expect(reloaded.restorePreviousClipboard == false)
        #expect(reloaded.typeOutAppIDs == ["com.apple.Terminal"])
    }

    @Test func savingTheNewKeyLeavesEveryOldKeyAlone() {
        defaults.set("de", forKey: "languagePin")
        defaults.set(["com.apple.Terminal"], forKey: "typeOutAppIDs")
        var s = settings.appFormatting
        s.enabled = false
        settings.appFormatting = s
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.languagePin == .de)
        #expect(reloaded.typeOutAppIDs == ["com.apple.Terminal"])
        #expect(reloaded.appFormatting.enabled == false)
    }

    @Test func everythingRoundTrips() {
        var s = AppFormattingSettings()
        s.enabled = false
        s.userName = "Wasim"
        s.setStyle(.formal, for: .workChat)
        s.setStyle(.veryCasual, for: .personalChat)
        s.setAutoSend(.shiftReturn, for: .workChat)
        s.setAutoSend(.modReturn, for: .coding)
        s.setCategory(.workChat, forAppID: "com.apple.MobileSMS")
        settings.appFormatting = s
        let back = AppSettings(defaults: defaults).appFormatting
        #expect(back == s)
        #expect(back.enabled == false)
        #expect(back.userName == "Wasim")
        #expect(back.style(for: .workChat) == .formal)
        #expect(back.style(for: .personalChat) == .veryCasual)
        #expect(back.autoSendKey(for: .workChat) == .shiftReturn)
        #expect(back.autoSendKey(for: .coding) == .modReturn)
        #expect(back.category(forAppID: "com.apple.MobileSMS", url: nil) == .workChat)
    }

    @Test func aValueThatCannotBeReadGivesTheDefaults() {
        defaults.set("this is not json", forKey: "appFormatting")
        #expect(AppSettings(defaults: defaults).appFormatting == .standard)
        defaults.set("[1, 2, 3]", forKey: "appFormatting")
        #expect(AppSettings(defaults: defaults).appFormatting == .standard)
        defaults.set(42, forKey: "appFormatting")   // a number where a string belongs
        #expect(AppSettings(defaults: defaults).appFormatting == .standard)
    }

    // MARK: lenient decoding

    @Test func everyKeyIsOptional() throws {
        #expect(try decode("{}") == .standard)
        #expect(try decode(#"{"enabled": false}"#).enabled == false)
        #expect(try decode(#"{"userName": "Sam"}"#).userName == "Sam")
    }

    @Test func wrongTypesReadAsNotSetInsteadOfFailingTheLoad() throws {
        let s = try decode(#"{"enabled": "yes", "userName": 7, "styles": [], "autoSend": "x", "overrides": 3}"#)
        #expect(s == .standard)
    }

    @Test func unknownCategoriesStylesAndKeysAreDroppedOneByOne() throws {
        let s = try decode("""
        {"styles": {"workChat": "formal", "mystery": "casual", "email": "shouting"},
         "autoSend": {"workChat": "return", "coding": "teleport", "nowhere": "return"},
         "overrides": {"a.b": "coding", "c.d": "alien"},
         "somethingNew": true}
        """)
        #expect(s.styles == ["workChat": .formal])
        #expect(s.autoSend == ["workChat": .return])
        #expect(s.overrides.byApp == ["a.b": .coding])
    }

    @Test func oneBadValueDropsOnlyItself() throws {
        let s = try decode("""
        {"styles": {"workChat": 5, "email": null, "personalChat": "veryCasual", "coding": ["x"]},
         "autoSend": {"workChat": {"a": 1}, "other": "shiftReturn", "coding": true}}
        """)
        #expect(s.styles == ["personalChat": .veryCasual])
        #expect(s.autoSend == ["other": .shiftReturn])
    }

    @Test func aStyleTheCategoryDoesNotAllowIsIgnored() throws {
        let s = try decode(#"{"styles": {"email": "veryCasual", "personalChat": "veryCasual"}}"#)
        #expect(s.requestedStyle(for: .email) == nil)
        #expect(s.style(for: .email) == .formal)
        #expect(s.requestedStyle(for: .personalChat) == .veryCasual)
    }

    @Test func aStoredStyleEqualToTheCategoryDefaultIsNoChoice() throws {
        let s = try decode(#"{"styles": {"email": "formal", "workChat": "formal"}}"#)
        #expect(AppCategory.email.defaultStyle == .formal)
        #expect(s.requestedStyle(for: .email) == nil)
        #expect(s.style(for: .email) == .formal)
        // A real choice is kept.
        #expect(AppCategory.workChat.defaultStyle != .formal)
        #expect(s.requestedStyle(for: .workChat) == .formal)
    }

    @Test func autoSendIsNeverOfferedForEmailOrDocsAndNotes() throws {
        let s = try decode(#"{"autoSend": {"email": "return", "docsNotes": "modReturn", "workChat": "return"}}"#)
        #expect(s.autoSendKey(for: .email) == .off)
        #expect(s.autoSendKey(for: .docsNotes) == .off)
        #expect(s.autoSendKey(for: .workChat) == .return)
        #expect(!AppFormattingSettings.offersAutoSend(.email))
        #expect(!AppFormattingSettings.offersAutoSend(.docsNotes))
        for category in [AppCategory.workChat, .personalChat, .coding, .other] {
            #expect(AppFormattingSettings.offersAutoSend(category))
        }
        var edited = AppFormattingSettings()
        edited.setAutoSend(.return, for: .email)
        #expect(edited.autoSend.isEmpty)
    }

    @Test func theNameIsTrimmedFlattenedAndCapped() throws {
        #expect(AppFormattingSettings.cleaned(name: "  Wasim \n") == "Wasim")
        #expect(AppFormattingSettings.cleaned(name: "Wasim\nJalali") == "Wasim Jalali")
        #expect(AppFormattingSettings.cleaned(name: "Wasim \t  \n Jalali") == "Wasim Jalali")
        #expect(AppFormattingSettings.cleaned(name: "Was\u{0}im\u{7}") == "Was im")
        #expect(AppFormattingSettings.cleaned(name: "ab\u{1}cd") == "ab cd")
        #expect(AppFormattingSettings.cleaned(name: "ab\u{7F}\u{85}cd") == "ab cd")      // DEL and C1
        #expect(AppFormattingSettings.cleaned(name: "ab\u{2028}\u{2029}cd") == "ab cd")
        // Format characters stay: the zero-width non-joiner is part of the name.
        #expect(AppFormattingSettings.cleaned(name: "فاطمه\u{200C}زهرا") == "فاطمه\u{200C}زهرا")
        #expect(AppFormattingSettings.cleaned(name: " \n\t ") == "")
        #expect(AppFormattingSettings.cleaned(name: String(repeating: "a", count: 500)).count == AppFormattingSettings.maxNameLength)
        #expect(try decode(#"{"userName": "  Sam  "}"#).userName == "Sam")
        var s = AppFormattingSettings()
        s.userName = "  Wasim  "
        settings.appFormatting = s
        #expect(settings.appFormatting.userName == "Wasim")
    }

    // MARK: styles and overrides

    @Test func choosingTheDefaultStyleStoresNothing() {
        var s = AppFormattingSettings()
        s.setStyle(.casual, for: .workChat)
        #expect(s.styles.isEmpty)
        s.setStyle(.formal, for: .workChat)
        #expect(s.style(for: .workChat) == .formal)
        s.setStyle(.veryCasual, for: .email)   // not allowed there
        #expect(s.styles["email"] == nil)
    }

    @Test func anOverrideBeatsTheSeedAndChoosingTheSeedClearsIt() {
        var s = AppFormattingSettings()
        #expect(s.category(forAppID: "com.apple.mail", url: nil) == .email)
        s.setCategory(.personalChat, forAppID: "com.apple.mail")
        #expect(s.category(forAppID: "com.apple.mail", url: nil) == .personalChat)
        // The override also beats the page address.
        #expect(s.category(forAppID: "com.apple.mail", url: "https://mail.google.com/") == .personalChat)
        s.setCategory(.email, forAppID: "com.apple.mail")
        #expect(s.overrides.byApp.isEmpty)
    }

    @Test func overridesMatchTheAppWithoutRegardToCaseAndKeepOneEntry() {
        var s = AppFormattingSettings()
        s.setCategory(.coding, forAppID: "com.Example.App")
        s.setCategory(.workChat, forAppID: "com.example.app")
        #expect(s.overrides.byApp.count == 1)
        #expect(s.category(forAppID: "COM.EXAMPLE.APP", url: nil) == .workChat)
    }

    @Test func resetForgetsEveryChoice() {
        var s = AppFormattingSettings()
        s.setCategory(.coding, forAppID: "a.b")
        s.setCategory(.workChat, forAppID: "c.d")
        s.resetOverrides()
        #expect(s.overrides.byApp.isEmpty)
        #expect(s.category(forAppID: "a.b", url: nil) == .other)
    }

    @Test func noAppIsOther() {
        #expect(AppFormattingSettings().category(forAppID: nil, url: nil) == .other)
    }

    // MARK: apps seen in History

    @Test func seenAppsAreNewestFirstWithoutDuplicatesOrBrowsers() {
        func record(_ app: String?, _ minutes: Int) -> DictationRecord {
            DictationRecord(text: "t", createdAt: Date(timeIntervalSince1970: Double(minutes) * 60),
                            language: "en", provider: "p", durationSeconds: 1, appID: app)
        }
        let records = [
            record("com.apple.mail", 5), record(nil, 9), record("com.tinyspeck.slackmacgap", 7),
            record("com.apple.Mail", 1), record("com.google.Chrome", 8), record("  ", 6),
            record("com.apple.Terminal", 3),
        ]
        #expect(SeenApps.ids(in: records) == ["com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.Terminal"])
        #expect(SeenApps.ids(in: records, limit: 2) == ["com.tinyspeck.slackmacgap", "com.apple.mail"])
        #expect(SeenApps.ids(in: []) == [])
    }
}

@Suite struct TextBeforeCursorTests {
    @Test func takesTheLastTwoHundredCharactersBeforeTheCaret() {
        let value = String(repeating: "a", count: 300) + "XYZ" + String(repeating: "b", count: 50)
        let before = TextBeforeCursor.extract(value: value, caretUTF16: 303)
        #expect(before?.count == 200)
        #expect(before?.hasSuffix("aXYZ") == true)
        #expect(before?.contains("b") == false)
    }

    @Test func aShortTextIsReturnedWhole() {
        #expect(TextBeforeCursor.extract(value: "Hello world", caretUTF16: 5) == "Hello")
        #expect(TextBeforeCursor.extract(value: "Hello", caretUTF16: 5) == "Hello")
        #expect(TextBeforeCursor.extract(value: "Hello", caretUTF16: 0) == "")
        #expect(TextBeforeCursor.extract(value: "", caretUTF16: 0) == "")
    }

    @Test func aCaretOutsideTheTextIsUnknownNotGuessed() {
        #expect(TextBeforeCursor.extract(value: "Hello", caretUTF16: 6) == nil)
        #expect(TextBeforeCursor.extract(value: "Hello", caretUTF16: -1) == nil)
        #expect(TextBeforeCursor.extract(value: "Hello", caretUTF16: 3, limit: 0) == nil)
    }

    @Test func offsetsAreUTF16SoAnEmojiBeforeTheCaretCountsAsTwo() {
        let value = "ab\u{1F600}cd"   // the emoji is two UTF-16 units
        #expect(TextBeforeCursor.extract(value: value, caretUTF16: 4) == "ab\u{1F600}")
        #expect(TextBeforeCursor.extract(value: value, caretUTF16: 5) == "ab\u{1F600}c")
    }

    @Test func aLongDocumentIsOnlyReadNearTheCaretAndCountsCharactersNotUnits() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"   // one character, eight UTF-16 units
        let value = String(repeating: family, count: 500)
        let before = TextBeforeCursor.extract(value: value, caretUTF16: value.utf16.count)
        #expect(before?.count == 200)
    }

    @Test func aLimitShorterThanTheTextKeepsTheEnd() {
        #expect(TextBeforeCursor.extract(value: "one two three", caretUTF16: 13, limit: 5) == "three")
    }
}

@Suite struct DictationRecordAppFieldsTests {
    private func decodeRecords(_ json: String) throws -> [DictationRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([DictationRecord].self, from: Data(json.utf8))
    }

    @Test func anOldHistoryRecordStillDecodesWithNoAppFields() throws {
        let json = """
        [{"id": "11111111-1111-1111-1111-111111111111", "text": "hello", "createdAt": "2026-10-01T10:00:00Z",
          "language": "en", "provider": "Deepgram", "durationSeconds": 2.5, "mode": "formatted"}]
        """
        let record = try #require(try decodeRecords(json).first)
        #expect(record.text == "hello")
        #expect(record.appID == nil)
        #expect(record.category == nil)
        #expect(record.appCategory == nil)
    }

    @Test func theAppFieldsRoundTrip() throws {
        let record = DictationRecord(text: "hi", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                     language: "en", provider: "p", durationSeconds: 1,
                                     appID: "com.apple.mail", category: AppCategory.email.rawValue)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([record])
        let back = try #require(try decodeRecords(String(decoding: data, as: UTF8.self)).first)
        #expect(back == record)
        #expect(back.appCategory == .email)
    }

    @Test func aCategoryThisBuildDoesNotKnowNeverFailsTheHistoryLoad() throws {
        let json = """
        [{"id": "11111111-1111-1111-1111-111111111111", "text": "a", "createdAt": "2026-10-01T10:00:00Z",
          "language": "en", "provider": "p", "category": "somethingNew", "appID": "x.y"},
         {"id": "22222222-2222-2222-2222-222222222222", "text": "b", "createdAt": "2026-10-01T11:00:00Z",
          "language": "en", "provider": "p", "category": "coding", "appID": "z"}]
        """
        let records = try decodeRecords(json)
        #expect(records.count == 2)
        #expect(records[0].appCategory == nil)
        #expect(records[0].category == "somethingNew")
        #expect(records[1].appCategory == .coding)
    }

    @Test func anOldHistoryFileLoadsThroughTheStoreAndKeepsItsRecords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        try """
        [{"id": "11111111-1111-1111-1111-111111111111", "text": "old one", "createdAt": "2026-10-01T10:00:00Z",
          "language": "en", "provider": "Deepgram", "durationSeconds": 2}]
        """.write(to: file, atomically: true, encoding: .utf8)
        let history = DictationHistory(fileURL: file, diagnostics: .memoryOnly)
        #expect(history.all().map(\.text) == ["old one"])
        history.append(DictationRecord(text: "new one", createdAt: Date(), language: "en", provider: "p",
                                       durationSeconds: 1, appID: "com.apple.mail", category: "email"))
        let reopened = DictationHistory(fileURL: file, diagnostics: .memoryOnly)
        #expect(reopened.all().map(\.text) == ["new one", "old one"])
        #expect(reopened.all().first?.category == "email")
        #expect(reopened.all().last?.appID == nil)
    }
}
