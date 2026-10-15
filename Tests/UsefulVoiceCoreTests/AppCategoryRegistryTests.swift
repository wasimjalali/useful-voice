import Testing
import Foundation
@testable import UsefulVoiceCore

/// The same cases drive `windows/tests/appCategory.test.ts`, so the two platforms cannot drift.
/// The fixture lives in `Tests/Fixtures/app-awareness/registry-cases.json`.
@Suite struct AppCategoryRegistryTests {
    private struct AppCase: Decodable {
        let id: String
        let appID: String?
        let url: String?
        let overrides: [String: String]?
        let expected: String
    }
    private struct URLCase: Decodable {
        let url: String
        let expected: String?
    }
    private struct ParseCase: Decodable {
        let url: String
        let host: String?
        let path: String?
    }
    private struct NormalizeCase: Decodable {
        let raw: String
        let expected: String
    }
    private struct DecodeCase: Decodable {
        let id: String
        let settings: String
        let expected: [String: String]
    }
    private struct Fixture: Decodable {
        let apps: [AppCase]
        let urls: [URLCase]
        let parse: [ParseCase]
        let normalize: [NormalizeCase]
        let overrideDecode: [DecodeCase]
    }
    /// Stands in for a settings file that may or may not hold overrides.
    private struct SettingsHolder: Decodable {
        let overrides: AppCategoryOverrides
        enum CodingKeys: String, CodingKey { case categoryOverrides }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            overrides = container.decodeAppCategoryOverrides(forKey: .categoryOverrides)
        }
    }

    private func fixture() throws -> Fixture {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: tests.appendingPathComponent("Fixtures/app-awareness/registry-cases.json"))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    @Test func fixtureHasTheCasesItShould() throws {
        let f = try fixture()
        let ids = f.apps.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate app case ids")
        let urls = f.urls.map(\.url)
        #expect(Set(urls).count == urls.count, "duplicate address cases")
        #expect(Set(f.apps.map(\.expected)) == Set(AppCategory.allCases.map(\.rawValue)))
        #expect(!f.parse.isEmpty && !f.normalize.isEmpty && !f.overrideDecode.isEmpty)
    }

    @Test func readsStoredOverridesLeniently() throws {
        for c in try fixture().overrideDecode {
            let holder = try JSONDecoder().decode(SettingsHolder.self, from: Data(c.settings.utf8))
            #expect(holder.overrides.byApp.mapValues(\.rawValue) == c.expected, "\(c.id)")
        }
        let encoded = try JSONEncoder().encode(AppCategoryOverrides(["slack.exe": .coding]))
        let back = try JSONDecoder().decode(AppCategoryOverrides.self, from: encoded)
        #expect(back.byApp == ["slack.exe": .coding])
    }

    @Test func resolvesEverySharedAppCase() throws {
        var failures: [String] = []
        for c in try fixture().apps {
            // Unknown categories in an override map are dropped, as the TypeScript side ignores them.
            let overrides = (c.overrides ?? [:]).compactMapValues { AppCategory(rawValue: $0) }
            let got = AppCategoryRegistry.resolve(appID: c.appID, url: c.url, overrides: overrides)
            if got.rawValue != c.expected { failures.append("\(c.id): got \(got.rawValue), want \(c.expected)") }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func matchesEverySharedAddressCase() throws {
        var failures: [String] = []
        for c in try fixture().urls {
            let got = AppCategoryRegistry.category(forURL: c.url)?.rawValue
            if got != c.expected { failures.append("\(c.url): got \(got ?? "nil"), want \(c.expected ?? "nil")") }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func parsesAddressesIntoHostAndPath() throws {
        for c in try fixture().parse {
            let got = AppCategoryRegistry.parseWebURL(c.url)
            if let host = c.host {
                #expect(got == AppCategoryRegistry.ParsedWebURL(host: host, path: c.path ?? ""), "\(c.url)")
            } else {
                #expect(got == nil, "\(c.url)")
            }
        }
    }

    @Test func normalizesAppIDs() throws {
        for c in try fixture().normalize {
            #expect(AppCategoryRegistry.normalizeAppID(c.raw) == c.expected, "\(c.raw)")
        }
    }

    // MARK: resolution order

    @Test func overrideBeatsAddressBeatsSeedBeatsOther() {
        let app = "com.apple.mail"
        #expect(AppCategoryRegistry.resolve(appID: app, url: nil) == .email)
        #expect(AppCategoryRegistry.resolve(appID: app, url: "https://claude.ai/code") == .coding)
        #expect(AppCategoryRegistry.resolve(appID: app, url: "https://claude.ai/code",
                                            overrides: [app: .docsNotes]) == .docsNotes)
        #expect(AppCategoryRegistry.resolve(appID: "com.example.none", url: nil) == .other)
    }

    @Test func neverFailsOnOddInput() {
        #expect(AppCategoryRegistry.resolve(appID: nil, url: nil) == .other)
        #expect(AppCategoryRegistry.resolve(appID: "\u{0}", url: "\u{0}://") == .other)
        #expect(AppCategoryRegistry.resolve(appID: String(repeating: "x", count: 10000),
                                            url: String(repeating: "a", count: 10000)) == .other)
    }

    // MARK: seed tables

    @Test func noIDIsInTwoCategories() {
        var seen: [String: AppCategory] = [:]
        var clashes: [String] = []
        for seed in AppCategorySeeds.appSeeds {
            for id in seed.ids {
                let key = AppCategoryRegistry.normalizeAppID(id)
                if let prior = seen[key] { clashes.append("\(key): \(prior) and \(seed.category)") }
                seen[key] = seed.category
            }
        }
        #expect(clashes.isEmpty, "\(clashes.joined(separator: "\n"))")
    }

    @Test func browsersAreNotAppSeeds() {
        for id in AppCategorySeeds.browserBundleIDs + AppCategorySeeds.browserExecutables {
            #expect(AppCategoryRegistry.seededCategory(for: id) == nil, "\(id)")
            #expect(AppCategoryRegistry.isBrowser(id), "\(id)")
        }
        #expect(!AppCategoryRegistry.isBrowser("com.apple.mail"))
        #expect(!AppCategoryRegistry.isBrowser(""))
    }

    @Test func listsTheBrowsersTheSpecNames() {
        for id in [
            "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac",
            "com.brave.Browser", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
            "chrome.exe", "msedge.exe", "brave.exe", "firefox.exe", "opera.exe", "vivaldi.exe",
        ] {
            #expect(AppCategoryRegistry.isBrowser(id), "\(id)")
        }
        #expect(AppCategoryRegistry.isBrowser("C:\\Program Files\\Google\\Chrome\\Application\\CHROME.EXE"))
    }

    @Test func listsEverySeedIDOnce() {
        let ids = AppCategorySeeds.appSeeds.flatMap { $0.ids.map(AppCategoryRegistry.normalizeAppID) }
        #expect(Set(ids).count == ids.count, "duplicate seed ids")
        for seed in AppCategorySeeds.appSeeds {
            for id in seed.ids { #expect(AppCategoryRegistry.seededCategory(for: id) == seed.category, "\(id)") }
        }
    }

    @Test func seedsCoverEveryCategoryButOther() {
        let covered = Set(AppCategorySeeds.appSeeds.map { $0.category })
        #expect(covered == Set(AppCategory.allCases).subtracting([.other]))
    }

    // MARK: categories, styles, auto-send

    @Test func namesEveryCategory() {
        #expect(AppCategory.allCases.map { $0.displayName } == [
            "Email", "Work chat", "Personal chat", "Coding", "Docs and notes", "Other",
        ])
    }

    @Test func hasTheDefaultStylesFromTheSpec() {
        #expect(AppCategory.email.defaultStyle == .formal)
        #expect(AppCategory.workChat.defaultStyle == .casual)
        #expect(AppCategory.personalChat.defaultStyle == .casual)
        #expect(AppCategory.docsNotes.defaultStyle == .formal)
        #expect(AppCategory.other.defaultStyle == .formal)
        #expect(AppCategory.coding.defaultStyle == .formal)
    }

    @Test func offersVeryCasualForPersonalChatOnly() {
        for c in AppCategory.allCases {
            #expect(c.allowedStyles.contains(.veryCasual) == (c == .personalChat), "\(c)")
        }
    }

    @Test func fallsBackFromVeryCasualOutsidePersonalChat() {
        #expect(FormattingStyle.effective(requested: .veryCasual, category: .personalChat) == .veryCasual)
        for c in AppCategory.allCases where c != .personalChat {
            #expect(FormattingStyle.effective(requested: .veryCasual, category: c) == .casual, "\(c)")
        }
        #expect(FormattingStyle.effective(requested: nil, category: .workChat) == .casual)
        #expect(FormattingStyle.effective(requested: nil, category: .email) == .formal)
        #expect(FormattingStyle.effective(requested: .formal, category: .workChat) == .formal)
    }

    @Test func mapsAutoSendToTheKeyToSend() {
        #expect(AutoSendKey.off.chord(for: .macOS) == nil)
        #expect(AutoSendKey.off.chord(for: .windows) == nil)
        for p in AppPlatform.allCases {
            #expect(AutoSendKey.return.chord(for: p) == SendKeyChord())
            #expect(AutoSendKey.shiftReturn.chord(for: p) == SendKeyChord(shift: true))
        }
        #expect(AutoSendKey.modReturn.chord(for: .macOS) == SendKeyChord(command: true))
        #expect(AutoSendKey.modReturn.chord(for: .windows) == SendKeyChord(control: true))
    }

    @Test func autoSendDefaultsToOffAndListsEveryKey() {
        #expect(AutoSendKey.allCases.first == .off)
        #expect(AutoSendKey.allCases.count == 4)
        #expect(AutoSendKey(rawValue: "off") == .off)
        #expect(AutoSendKey(rawValue: "return") == .return)
    }
}
