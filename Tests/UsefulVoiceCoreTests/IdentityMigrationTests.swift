import Foundation
import Testing
@testable import UsefulVoiceCore

// MARK: - How the identity migration can fail (written before the code)
//
// The app changed identity: bundle id, data folder, Keychain service and
// defaults domain. A one-time migration carries a user's history, dictionary,
// settings and Deepgram key across. Getting it wrong loses user data or locks
// the user out of their key, so every way it can go wrong is listed here first,
// and each line names the test that covers it.
//
// FILES (old data folder -> new data folder)
//  F1  Happy path: every top-level entry moves, the old folder is removed.
//      -> movesEveryEntryAndRemovesTheEmptyLegacyFolder
//  F2  The new folder already exists and holds `models/` (LocalModelStore
//      created it first): the entries move in, `models/` is untouched.
//      -> existingNewFolderWithModelsKeepsModelsAndReceivesTheRest
//  F3  The same file name exists in both: the new one wins, the old one stays
//      byte for byte, the conflict is reported and logged, the old folder stays.
//      -> aNameClashLeavesBothCopiesAndReportsIt
//  F4  The same directory name exists in both: directories are not merged.
//      -> aDirectoryClashIsNotMerged
//  F5  The old folder is empty: nothing moves, the folder is removed.
//      -> anEmptyLegacyFolderIsJustRemoved
//  F6  There is no old folder (a new install): a no-op that touches nothing.
//      -> noLegacyFolderIsANoOp
//  F7  An interrupted run (some entries already moved): the next run moves the
//      rest and reports no conflict for the ones already gone.
//      -> aSecondRunFinishesAnInterruptedMigration
//  F8  A second launch after success: nothing to do, no error.
//      -> runningTwiceIsIdempotent
//  F9  One move fails (permissions, a busy file): the others still move, the
//      failure is reported, nothing is deleted, the old folder stays.
//      -> aFailedMoveIsReportedAndNothingElseIsLost
//  F10 Another launch moves an entry between our listing and our move: that is
//      not a failure and not a conflict.
//      -> losingARaceToAnotherLaunchIsNotAFailure
//  F11 A plain file where the old folder should be: left alone.
//      -> aRegularFileNamedLikeTheLegacyFolderIsLeftAlone
//  F12 Hidden files (.DS_Store) travel too, so the old folder can be removed.
//      -> hiddenEntriesMoveToo
//  F13 Moved data ends up owner-only (0700 / 0600), as the rest of the app does.
//      -> movedDataIsRestrictedToTheOwner
//  F14 The old folder is never removed while anything is left in it.
//      -> aSecondRunFinishesAnInterruptedMigration, aNameClashLeavesBothCopiesAndReportsIt
//
// DEFAULTS (old domain -> new domain)
//  D1  Every key the new domain lacks is copied, then the flag is set.
//      -> copiesEveryKeyTheNewDomainLacks
//  D2  A key in both domains keeps the NEW value, including a stored `false`.
//      -> aKeyAlreadyInTheNewDomainWins
//  D3  The flag is already set: nothing is copied, even if the old domain has
//      keys the new one lacks (a user who changed a setting since).
//      -> doesNotCopyAgainOnceFlagged
//  D4  No old domain at all: nothing to copy, still flagged.
//      -> aMissingLegacyDomainStillSetsTheFlag
//  D5  Value types survive: bool, int, double, string, data, date, array, dict.
//      -> valueTypesSurviveTheCopy
//  D6  The settings that matter survive and AppSettings reads them back:
//      uv.firstRunCompleted, uv.languageDefaultResolved, languagePin.
//      -> firstRunAndLanguageSettingsSurvive
//  D7  The old domain is only read, never changed or deleted.
//      -> theLegacyDomainIsLeftUntouched
//  D8  A key held only in the global domain / registered defaults must not
//      stop a legacy value being copied (the check is the domain, not lookup).
//      -> aRegisteredDefaultDoesNotBlockTheCopy
//  D9  Preview runs (snapshot, forced first run) apply the old values in memory
//      only: nothing persisted, no flag, and an already migrated user is not
//      shadowed by stale old values.
//      -> previewRegistersLegacyDefaultsInMemoryOnly, previewDoesNothingOnceMigrated
//
// KEYCHAIN (old service -> new service)
//  K1  New item missing, old item present: copied, read back, old deleted.
//      -> copiesVerifiesThenDeletesTheLegacyItem
//  K2  New item already present: the old item is never read (no prompt) and
//      never deleted.
//      -> neverReadsTheLegacyItemWhenTheNewOneExists
//  K3  Neither exists: nothing happens, nothing is recorded.
//      -> nothingStoredAnywhereIsAbsent
//  K4  Reading the old item is denied or fails: nothing is written or deleted,
//      the attempt is recorded, and the next launch never asks again.
//      -> aDeniedReadDeletesNothingAndIsNeverRetried
//  K5  The read works but writing the new item fails: the old item stays, the
//      attempt is recorded.
//      -> aFailedWriteLeavesTheLegacyItemAlone
//  K6  The new item reads back differently (or not at all): it is removed
//      again, the old item stays.
//      -> aFailedVerifyRemovesTheCopyAndKeepsTheLegacyItem
//  K7  Deleting the old item fails after a verified copy: the key is migrated,
//      the leftover is reported, the next launch sees the new item and stops.
//      -> aLeftoverLegacyItemDoesNotUndoAGoodMigration
//  K8  The value is copied exactly (whitespace, unicode).
//      -> copiesVerifiesThenDeletesTheLegacyItem
//  K9  Presence checks never decrypt: they use `exists`, not `lookup`.
//      -> nothingStoredAnywhereIsAbsent, neverReadsTheLegacyItemWhenTheNewOneExists
//  K10 "Is a key stored" counts the old item only while the migration has not
//      been tried (snapshot runs and the moment before migration); after a
//      denial the first-run gate must ask for a key.
//      -> keyPresenceCountsTheLegacyItemOnlyUntilTheAttempt
//
// MODES AND NAMES
//  M1  Snapshot and forced first-run runs never migrate; both together with
//      migrate-only is refused; migrate-only needs exactly "1".
//      -> launchModeFollowsTheEnvironment
//  M2  The test prefix applies only with migrate-only, and only to the defaults
//      domains and Keychain services (never the folders).
//      -> thePrefixOnlyAppliesToMigrateOnly
//  M3  Preview runs read the old folder only while it still holds something
//      the new folder lacks, and never create or change anything.
//      -> previewReadsTheLegacyFolderOnlyWhileItHoldsData, resolvingTheFolderChangesNothing
//  M4  The previous run's launch-at-login state is read from the old
//      diagnostics log before it moves, once, even if the log clashes.
//      -> theLegacyLaunchLineSaysWhetherLoginWasOn, theLoginSignalIsReadOnce
//
// Not covered here (needs a live Keychain / launch): the end-to-end run with
// UV_MIGRATE_ONLY and UV_MIGRATION_TEST_PREFIX, done against the built bundle.

// MARK: - Fixtures

private final class FakeMigrationKeychain: MigrationKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    var lookupOverride: [String: Keychain.Lookup] = [:]   // by service
    var failWrites = false
    var failDeletes: Set<String> = []                      // services
    var corruptWrites = false                              // stored value differs from the written one
    private(set) var lookups: [String] = []
    private(set) var existsCalls: [String] = []
    private(set) var deletes: [String] = []

    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func seed(_ value: String, service: String, account: String = DeepgramKeyStore.account) {
        lock.lock(); defer { lock.unlock() }
        items[key(service, account)] = value
    }

    func value(service: String, account: String = DeepgramKeyStore.account) -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[key(service, account)]
    }

    func exists(service: String, account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        existsCalls.append(service)
        return items[key(service, account)] != nil
    }

    func lookup(service: String, account: String) -> Keychain.Lookup {
        lock.lock(); defer { lock.unlock() }
        lookups.append(service)
        if let forced = lookupOverride[service] { return forced }
        guard let value = items[key(service, account)] else { return .absent }
        return .found(value)
    }

    func write(_ value: String, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw KeychainError.unexpectedStatus(-25308) }
        items[key(service, account)] = corruptWrites ? value + "-corrupt" : value
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        deletes.append(service)
        if failDeletes.contains(service) { throw KeychainError.unexpectedStatus(-25308) }
        items[key(service, account)] = nil
    }
}

/// A file manager whose moves can be made to fail, or to lose a race.
private final class ScriptedFileManager: FileManager {
    var failMovesOfNames: Set<String> = []
    /// Names another "launch" moves first, so our own move finds the source gone.
    var movedByRivalFirst: Set<String> = []

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        let name = srcURL.lastPathComponent
        if failMovesOfNames.contains(name) {
            throw CocoaError(.fileWriteNoPermission)
        }
        if movedByRivalFirst.contains(name) {
            try super.moveItem(at: srcURL, to: dstURL)   // the rival's move
            // ours now fails: the source is gone
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private struct Harness {
    let root: URL
    let appSupport: URL
    let legacyFolder: URL
    let newFolder: URL
    let names: IdentityMigration.Names
    let defaults: UserDefaults
    let keychain: FakeMigrationKeychain
    var legacyDefaults: [String: Any]?
    let fileManager: FileManager

    init(fileManager: FileManager = .default, legacyDefaults: [String: Any]? = nil) {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent("uv-migration-\(id)")
        appSupport = root.appendingPathComponent("Application Support")
        names = IdentityMigration.Names(
            legacyDefaultsDomain: "uv.test.legacy.\(id)",
            newDefaultsDomain: "uv.test.new.\(id)",
            legacyKeychainService: "uv.test.legacy.service.\(id)",
            newKeychainService: "uv.test.new.service.\(id)",
            legacyFolderName: "LegacyFolder",
            newFolderName: "NewFolder")
        legacyFolder = appSupport.appendingPathComponent(names.legacyFolderName)
        newFolder = appSupport.appendingPathComponent(names.newFolderName)
        defaults = UserDefaults(suiteName: names.newDefaultsDomain)!
        keychain = FakeMigrationKeychain()
        self.legacyDefaults = legacyDefaults
        self.fileManager = fileManager
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    func migration() -> IdentityMigration {
        let legacy = legacyDefaults
        let legacyName = names.legacyDefaultsDomain
        return IdentityMigration(
            fileManager: fileManager,
            appSupport: appSupport,
            names: names,
            readLegacyDefaults: { domain in domain == legacyName ? legacy : nil },
            defaults: defaults,
            keychain: keychain)
    }

    func cleanUp() {
        Self.removeDomain(names.newDefaultsDomain)
        try? FileManager.default.removeItem(at: root)
    }

    /// Removes a throwaway preferences domain and the empty plist it leaves behind,
    /// so the suite does not litter `~/Library/Preferences`.
    static func removeDomain(_ name: String) {
        let suite = UserDefaults(suiteName: name)
        suite?.removePersistentDomain(forName: name)
        suite?.synchronize()   // flush before deleting the file, or the daemon rewrites it
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(
                at: library.appendingPathComponent("Preferences/\(name).plist"))
        }
    }

    func legacy(_ name: String, _ text: String) {
        put(legacyFolder.appendingPathComponent(name), text)
    }

    func new(_ name: String, _ text: String) {
        put(newFolder.appendingPathComponent(name), text)
    }

    func put(_ url: URL, _ text: String) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func silentDiagnostics() -> Diagnostics { Diagnostics(directory: nil) }
}

// MARK: - Files

@Suite("Identity migration: files")
struct IdentityMigrationFileTests {
    @Test func movesEveryEntryAndRemovesTheEmptyLegacyFolder() {
        let h = Harness(); defer { h.cleanUp() }
        h.legacy("history.json", "[1]")
        h.legacy("dictionary.json", "[2]")
        h.legacy("Recordings/a.wav", "audio")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(Set(report.moved) == ["history.json", "dictionary.json", "Recordings"])
        #expect(report.conflicts.isEmpty)
        #expect(report.failed.isEmpty)
        #expect(report.legacyFolderRemoved)
        #expect(!h.exists(h.legacyFolder))
        #expect(h.text(h.newFolder.appendingPathComponent("history.json")) == "[1]")
        #expect(h.text(h.newFolder.appendingPathComponent("Recordings/a.wav")) == "audio")
    }

    @Test func existingNewFolderWithModelsKeepsModelsAndReceivesTheRest() {
        let h = Harness(); defer { h.cleanUp() }
        h.new("models/ggml.bin", "weights")
        h.legacy("history.json", "[1]")
        h.legacy("notes.json", "[2]")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(Set(report.moved) == ["history.json", "notes.json"])
        #expect(report.conflicts.isEmpty)
        #expect(h.text(h.newFolder.appendingPathComponent("models/ggml.bin")) == "weights")
        #expect(h.text(h.newFolder.appendingPathComponent("notes.json")) == "[2]")
        #expect(!h.exists(h.legacyFolder))
    }

    @Test func aNameClashLeavesBothCopiesAndReportsIt() {
        let h = Harness(); defer { h.cleanUp() }
        h.new("diagnostics.log", "new log")
        h.legacy("diagnostics.log", "old log")
        h.legacy("history.json", "[1]")
        let sink = h.silentDiagnostics()

        let report = h.migration().run(diagnostics: sink)

        #expect(report.conflicts == ["diagnostics.log"])
        #expect(report.moved == ["history.json"])
        #expect(h.text(h.newFolder.appendingPathComponent("diagnostics.log")) == "new log")
        #expect(h.text(h.legacyFolder.appendingPathComponent("diagnostics.log")) == "old log")
        #expect(!report.legacyFolderRemoved)
        #expect(h.exists(h.legacyFolder))
        // Logged after the migration, naming the entry.
        let lines = sink.entries(level: .warning).map(\.message)
        #expect(lines.contains { $0.contains("diagnostics.log") })
    }

    @Test func aDirectoryClashIsNotMerged() {
        let h = Harness(); defer { h.cleanUp() }
        h.new("Recordings/new.wav", "new")
        h.legacy("Recordings/old.wav", "old")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.conflicts == ["Recordings"])
        #expect(h.exists(h.newFolder.appendingPathComponent("Recordings/new.wav")))
        #expect(!h.exists(h.newFolder.appendingPathComponent("Recordings/old.wav")))
        #expect(h.exists(h.legacyFolder.appendingPathComponent("Recordings/old.wav")))
    }

    @Test func anEmptyLegacyFolderIsJustRemoved() throws {
        let h = Harness(); defer { h.cleanUp() }
        try FileManager.default.createDirectory(at: h.legacyFolder, withIntermediateDirectories: true)

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.moved.isEmpty)
        #expect(report.legacyFolderRemoved)
        #expect(!h.exists(h.legacyFolder))
    }

    @Test func noLegacyFolderIsANoOp() {
        let h = Harness(); defer { h.cleanUp() }
        let before = (try? FileManager.default.contentsOfDirectory(atPath: h.appSupport.path)) ?? []

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.moved.isEmpty && report.conflicts.isEmpty && report.failed.isEmpty)
        #expect(!report.legacyFolderRemoved)
        let after = (try? FileManager.default.contentsOfDirectory(atPath: h.appSupport.path)) ?? []
        #expect(before == after)   // the new folder is not even created
    }

    @Test func aSecondRunFinishesAnInterruptedMigration() {
        let h = Harness(); defer { h.cleanUp() }
        // The first run moved `history.json` and was killed before the rest.
        h.new("history.json", "[1]")
        h.legacy("dictionary.json", "[2]")
        h.legacy("notes.json", "[3]")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(Set(report.moved) == ["dictionary.json", "notes.json"])
        #expect(report.conflicts.isEmpty)
        #expect(report.legacyFolderRemoved)
        #expect(h.text(h.newFolder.appendingPathComponent("history.json")) == "[1]")
    }

    @Test func runningTwiceIsIdempotent() {
        let h = Harness(legacyDefaults: ["languagePin": "de"]); defer { h.cleanUp() }
        h.legacy("history.json", "[1]")
        _ = h.migration().run(diagnostics: h.silentDiagnostics())

        let second = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(second.moved.isEmpty && second.conflicts.isEmpty && second.failed.isEmpty)
        #expect(second.defaultsAlreadyMigrated)
        #expect(h.text(h.newFolder.appendingPathComponent("history.json")) == "[1]")
    }

    @Test func aFailedMoveIsReportedAndNothingElseIsLost() {
        let files = ScriptedFileManager()
        files.failMovesOfNames = ["history.json"]
        let h = Harness(fileManager: files); defer { h.cleanUp() }
        h.legacy("history.json", "[1]")
        h.legacy("notes.json", "[2]")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.moved == ["notes.json"])
        #expect(report.failed.count == 1)
        #expect(report.failed[0].hasPrefix("history.json"))
        #expect(!report.legacyFolderRemoved)
        #expect(h.text(h.legacyFolder.appendingPathComponent("history.json")) == "[1]")
        #expect(h.text(h.newFolder.appendingPathComponent("notes.json")) == "[2]")
    }

    @Test func losingARaceToAnotherLaunchIsNotAFailure() {
        let files = ScriptedFileManager()
        files.movedByRivalFirst = ["history.json"]
        let h = Harness(fileManager: files); defer { h.cleanUp() }
        h.legacy("history.json", "[1]")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.failed.isEmpty)
        #expect(report.conflicts.isEmpty)
        #expect(h.text(h.newFolder.appendingPathComponent("history.json")) == "[1]")
        #expect(!h.exists(h.legacyFolder))
    }

    @Test func aRegularFileNamedLikeTheLegacyFolderIsLeftAlone() {
        let h = Harness(); defer { h.cleanUp() }
        h.put(h.legacyFolder, "not a folder")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.moved.isEmpty && report.failed.isEmpty)
        #expect(!report.legacyFolderRemoved)
        #expect(h.text(h.legacyFolder) == "not a folder")
    }

    @Test func hiddenEntriesMoveToo() {
        let h = Harness(); defer { h.cleanUp() }
        h.legacy(".DS_Store", "finder")
        h.legacy("history.json", "[1]")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(Set(report.moved) == [".DS_Store", "history.json"])
        #expect(report.legacyFolderRemoved)
    }

    @Test func movedDataIsRestrictedToTheOwner() throws {
        let h = Harness(); defer { h.cleanUp() }
        h.legacy("history.json", "[1]")
        h.legacy("Recordings/a.wav", "audio")
        for url in [h.legacyFolder.appendingPathComponent("history.json"),
                    h.legacyFolder.appendingPathComponent("Recordings/a.wav")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.legacyFolder.path)

        _ = h.migration().run(diagnostics: h.silentDiagnostics())

        func mode(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        #expect(mode(h.newFolder) == 0o700)
        #expect(mode(h.newFolder.appendingPathComponent("history.json")) == 0o600)
        #expect(mode(h.newFolder.appendingPathComponent("Recordings")) == 0o700)
        #expect(mode(h.newFolder.appendingPathComponent("Recordings/a.wav")) == 0o600)
    }
}

// MARK: - Defaults

@Suite("Identity migration: defaults")
struct IdentityMigrationDefaultsTests {
    @Test func copiesEveryKeyTheNewDomainLacks() {
        let h = Harness(legacyDefaults: [
            "uv.firstRunCompleted": true, "silenceTimeout": 12.5, "appearance": "dark",
        ]); defer { h.cleanUp() }

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.defaultsCopied == 3)
        #expect(!report.defaultsAlreadyMigrated)
        #expect(h.defaults.bool(forKey: "uv.firstRunCompleted"))
        #expect(h.defaults.double(forKey: "silenceTimeout") == 12.5)
        #expect(h.defaults.string(forKey: "appearance") == "dark")
        #expect(h.defaults.bool(forKey: IdentityMigration.migratedFlag))
    }

    @Test func aKeyAlreadyInTheNewDomainWins() {
        let h = Harness(legacyDefaults: ["appearance": "dark", "soundEffectsEnabled": true, "extra": 1])
        defer { h.cleanUp() }
        h.defaults.set("light", forKey: "appearance")
        h.defaults.set(false, forKey: "soundEffectsEnabled")   // a stored false still counts as set

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(h.defaults.string(forKey: "appearance") == "light")
        #expect(h.defaults.bool(forKey: "soundEffectsEnabled") == false)
        #expect(h.defaults.integer(forKey: "extra") == 1)
        #expect(report.defaultsCopied == 1)
    }

    @Test func doesNotCopyAgainOnceFlagged() {
        let h = Harness(legacyDefaults: ["appearance": "dark"]); defer { h.cleanUp() }
        _ = h.migration().run(diagnostics: h.silentDiagnostics())
        h.defaults.removeObject(forKey: "appearance")        // the user reset it afterwards
        var again = h
        again.legacyDefaults = ["appearance": "dark", "newKey": "x"]

        let report = again.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.defaultsAlreadyMigrated)
        #expect(report.defaultsCopied == 0)
        #expect(h.defaults.string(forKey: "appearance") == nil)
        #expect(h.defaults.string(forKey: "newKey") == nil)
    }

    @Test func aMissingLegacyDomainStillSetsTheFlag() {
        let h = Harness(legacyDefaults: nil); defer { h.cleanUp() }

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.defaultsCopied == 0)
        #expect(h.defaults.bool(forKey: IdentityMigration.migratedFlag))
    }

    @Test func valueTypesSurviveTheCopy() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let h = Harness(legacyDefaults: [
            "b": true, "i": 42, "d": 3.25, "s": "text", "data": Data([1, 2, 3]), "date": date,
            "array": ["a", "b"], "dict": ["k": "v", "n": 1],
        ]); defer { h.cleanUp() }

        _ = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(h.defaults.bool(forKey: "b"))
        #expect(h.defaults.integer(forKey: "i") == 42)
        #expect(h.defaults.double(forKey: "d") == 3.25)
        #expect(h.defaults.string(forKey: "s") == "text")
        #expect(h.defaults.data(forKey: "data") == Data([1, 2, 3]))
        #expect(h.defaults.object(forKey: "date") as? Date == date)
        #expect(h.defaults.stringArray(forKey: "array") == ["a", "b"])
        #expect(h.defaults.dictionary(forKey: "dict")?["k"] as? String == "v")
    }

    @Test func firstRunAndLanguageSettingsSurvive() {
        let h = Harness(legacyDefaults: [
            FirstRunGate.completedKey: true,
            LanguageDefault.resolvedKey: true,
            "languagePin": "de",
        ]); defer { h.cleanUp() }

        _ = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(h.defaults.bool(forKey: FirstRunGate.completedKey))
        #expect(h.defaults.bool(forKey: LanguageDefault.resolvedKey))
        let settings = AppSettings(defaults: h.defaults)
        #expect(settings.languagePin == .de)
        // And the language default is not re-decided for a migrated install.
        settings.resolveLanguageDefault(hasPriorData: false)
        #expect(settings.languagePin == .de)
    }

    @Test func theLegacyDomainIsLeftUntouched() {
        let legacyName = "uv.test.legacy.real.\(UUID().uuidString)"
        let legacySuite = UserDefaults(suiteName: legacyName)!
        defer { Harness.removeDomain(legacyName) }
        legacySuite.set("dark", forKey: "appearance")
        legacySuite.set(true, forKey: "uv.firstRunCompleted")

        let h = Harness(); defer { h.cleanUp() }
        let migration = IdentityMigration(
            fileManager: .default, appSupport: h.appSupport,
            names: IdentityMigration.Names(
                legacyDefaultsDomain: legacyName, newDefaultsDomain: h.names.newDefaultsDomain,
                legacyKeychainService: h.names.legacyKeychainService,
                newKeychainService: h.names.newKeychainService,
                legacyFolderName: h.names.legacyFolderName, newFolderName: h.names.newFolderName),
            readLegacyDefaults: { UserDefaults.standard.persistentDomain(forName: $0) },
            defaults: h.defaults, keychain: h.keychain)

        let report = migration.run(diagnostics: h.silentDiagnostics())

        #expect(report.defaultsCopied == 2)
        let remaining = UserDefaults.standard.persistentDomain(forName: legacyName)
        #expect(remaining?["appearance"] as? String == "dark")
        #expect(remaining?["uv.firstRunCompleted"] as? Bool == true)
        #expect(remaining?[IdentityMigration.migratedFlag] == nil)   // the flag lives in the new domain only
        #expect(h.defaults.string(forKey: "appearance") == "dark")
    }

    @Test func aRegisteredDefaultDoesNotBlockTheCopy() {
        // A key nothing else reads: registering is process-wide (see below).
        let key = "uv.test.registered.\(UUID().uuidString)"
        let h = Harness(legacyDefaults: [key: 30.0]); defer { h.cleanUp() }
        h.defaults.register(defaults: [key: 60.0])   // visible to object(forKey:), not in the domain

        _ = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(h.defaults.double(forKey: key) == 30.0)
    }

    // `register(defaults:)` writes the process-wide registration domain, which every
    // `UserDefaults` in the process sees, including other suites' tests. These two
    // tests therefore use keys nothing else reads.
    @Test func previewRegistersLegacyDefaultsInMemoryOnly() {
        let key = "uv.test.preview.\(UUID().uuidString)"
        let h = Harness(legacyDefaults: [key: "de"]); defer { h.cleanUp() }

        h.migration().registerLegacyDefaultsInMemory()

        #expect(h.defaults.string(forKey: key) == "de")
        // Nothing persisted: the new domain still has no keys and no flag.
        let persisted = h.defaults.persistentDomain(forName: h.names.newDefaultsDomain) ?? [:]
        #expect(persisted[key] == nil)
        #expect(persisted[IdentityMigration.migratedFlag] == nil)
        #expect(!h.defaults.bool(forKey: IdentityMigration.migratedFlag))
    }

    @Test func previewDoesNothingOnceMigrated() {
        let key = "uv.test.preview.\(UUID().uuidString)"
        let h = Harness(legacyDefaults: [key: "de"]); defer { h.cleanUp() }
        h.defaults.set(true, forKey: IdentityMigration.migratedFlag)

        h.migration().registerLegacyDefaultsInMemory()

        #expect(h.defaults.string(forKey: key) == nil)
    }
}

// MARK: - Keychain

@Suite("Identity migration: Keychain")
struct IdentityMigrationKeychainTests {
    private let account = DeepgramKeyStore.account

    @Test func copiesVerifiesThenDeletesTheLegacyItem() {
        let h = Harness(); defer { h.cleanUp() }
        let secret = "  dg-\u{00E9}\u{1F511} key with spaces \n"
        h.keychain.seed(secret, service: h.names.legacyKeychainService)

        let outcome = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(outcome == .migrated)
        #expect(h.keychain.value(service: h.names.newKeychainService) == secret)
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == nil)
        // Order: the new item was read back before the old one was deleted.
        #expect(h.keychain.lookups == [h.names.legacyKeychainService, h.names.newKeychainService])
        #expect(!h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
    }

    @Test func neverReadsTheLegacyItemWhenTheNewOneExists() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("new-key", service: h.names.newKeychainService)
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)

        let outcome = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(outcome == .alreadyPresent)
        #expect(h.keychain.lookups.isEmpty)               // no decrypting read, so no prompt
        #expect(h.keychain.deletes.isEmpty)
        #expect(h.keychain.value(service: h.names.newKeychainService) == "new-key")
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == "old-key")
    }

    @Test func nothingStoredAnywhereIsAbsent() {
        let h = Harness(); defer { h.cleanUp() }

        let outcome = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(outcome == .absent)
        #expect(h.keychain.lookups.isEmpty)               // presence is attribute-only
        #expect(!h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
    }

    @Test func aDeniedReadDeletesNothingAndIsNeverRetried() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.lookupOverride[h.names.legacyKeychainService] = .unavailable("keychain access was denied")

        let first = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(first == .readDenied)
        #expect(h.keychain.deletes.isEmpty)
        #expect(h.keychain.value(service: h.names.newKeychainService) == nil)
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == "old-key")
        #expect(h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))

        let readsAfterFirst = h.keychain.lookups.count
        let second = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())
        #expect(second == .skippedAfterAttempt)
        #expect(h.keychain.lookups.count == readsAfterFirst)   // no second prompt
    }

    @Test func aFailedWriteLeavesTheLegacyItemAlone() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.failWrites = true

        let outcome = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(outcome == .writeFailed)
        #expect(h.keychain.deletes.isEmpty)
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == "old-key")
        #expect(h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
    }

    @Test func aFailedVerifyRemovesTheCopyAndKeepsTheLegacyItem() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.corruptWrites = true

        let outcome = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(outcome == .verifyFailed)
        #expect(h.keychain.value(service: h.names.newKeychainService) == nil)   // the bad copy is gone
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == "old-key")
        #expect(h.keychain.deletes == [h.names.newKeychainService])
        #expect(h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
    }

    @Test func aLeftoverLegacyItemDoesNotUndoAGoodMigration() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.failDeletes = [h.names.legacyKeychainService]

        let first = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(first == .migratedLegacyRemains)
        #expect(h.keychain.value(service: h.names.newKeychainService) == "old-key")

        let second = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())
        #expect(second == .alreadyPresent)
    }

    /// The same steps against the real Keychain, under throwaway service names. The
    /// legacy item is created by this process, so no authorization prompt appears.
    @Test(.serialized) func movesAKeyBetweenRealKeychainServices() throws {
        let h = Harness(); defer { h.cleanUp() }
        let id = UUID().uuidString
        let legacyService = "uv.test.legacy.keychain.\(id)"
        let newService = "uv.test.new.keychain.\(id)"
        let names = IdentityMigration.Names(
            legacyDefaultsDomain: h.names.legacyDefaultsDomain, newDefaultsDomain: h.names.newDefaultsDomain,
            legacyKeychainService: legacyService, newKeychainService: newService,
            legacyFolderName: h.names.legacyFolderName, newFolderName: h.names.newFolderName)
        defer {
            try? Keychain.delete(account: account, service: legacyService)
            try? Keychain.delete(account: account, service: newService)
        }
        try Keychain.set("real-keychain-secret", account: account, service: legacyService)
        let migration = IdentityMigration(
            appSupport: h.appSupport, names: names,
            readLegacyDefaults: { _ in nil }, defaults: h.defaults,
            keychain: SystemMigrationKeychain())

        #expect(migration.keyIsStored())
        let outcome = migration.migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(outcome == .migrated)
        #expect(Keychain.lookup(account: account, service: newService) == .found("real-keychain-secret"))
        #expect(!Keychain.exists(account: account, service: legacyService))
        #expect(migration.keyIsStored())
        #expect(migration.migrateKeychain(diagnostics: h.silentDiagnostics()) == .alreadyPresent)
    }

    @Test func keyPresenceCountsTheLegacyItemOnlyUntilTheAttempt() {
        let h = Harness(); defer { h.cleanUp() }
        #expect(!h.migration().keyIsStored())

        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        #expect(h.migration().keyIsStored())               // pending: the old item counts

        h.defaults.set(true, forKey: IdentityMigration.keychainAttemptedFlag)
        #expect(!h.migration().keyIsStored())              // denied: ask for a key

        h.keychain.seed("new-key", service: h.names.newKeychainService)
        #expect(h.migration().keyIsStored())
        #expect(h.keychain.lookups.isEmpty)                // never decrypted to answer
    }
}

// MARK: - Modes, names, folder resolution, login signal

@Suite("Identity migration: modes and names")
struct IdentityMigrationModeTests {
    @Test func launchModeFollowsTheEnvironment() {
        #expect(LaunchMode.current(environment: [:]) == .normal)
        #expect(LaunchMode.current(environment: ["UV_SNAPSHOT": "/tmp/a.png@10x10"]) == .preview)
        #expect(LaunchMode.current(environment: ["UV_FIRST_RUN": "force"]) == .preview)
        #expect(LaunchMode.current(environment: ["UV_FIRST_RUN": "1"]) == .normal)
        #expect(LaunchMode.current(environment: ["UV_MIGRATE_ONLY": "1"]) == .migrateOnly)
        #expect(LaunchMode.current(environment: ["UV_MIGRATE_ONLY": "true"]) == .normal)
        #expect(LaunchMode.current(environment: ["UV_MIGRATE_ONLY": "0"]) == .normal)
        // Preview wins: a render must never migrate, whatever else is set.
        #expect(LaunchMode.current(environment: ["UV_MIGRATE_ONLY": "1", "UV_SNAPSHOT": "x"]) == .preview)
        #expect(LaunchMode.current(environment: ["UV_MIGRATE_ONLY": "1", "UV_FIRST_RUN": "force"]) == .preview)
        #expect(LaunchMode.migrateOnlyConflictsWithPreview(
            environment: ["UV_MIGRATE_ONLY": "1", "UV_SNAPSHOT": "x"]))
        #expect(!LaunchMode.migrateOnlyConflictsWithPreview(environment: ["UV_MIGRATE_ONLY": "1"]))
        #expect(!LaunchMode.migrateOnlyConflictsWithPreview(environment: ["UV_SNAPSHOT": "x"]))
    }

    @Test func thePrefixOnlyAppliesToMigrateOnly() {
        let production = IdentityMigration.Names.production
        #expect(IdentityMigration.Names.forLaunch(environment: [:]) == production)
        #expect(IdentityMigration.Names.forLaunch(
            environment: ["UV_MIGRATION_TEST_PREFIX": "t1."]) == production)
        #expect(IdentityMigration.Names.forLaunch(
            environment: ["UV_MIGRATE_ONLY": "1", "UV_MIGRATION_TEST_PREFIX": ""]) == production)

        let prefixed = IdentityMigration.Names.forLaunch(
            environment: ["UV_MIGRATE_ONLY": "1", "UV_MIGRATION_TEST_PREFIX": "t1."])
        #expect(prefixed.legacyDefaultsDomain == "t1." + production.legacyDefaultsDomain)
        #expect(prefixed.newDefaultsDomain == "t1." + production.newDefaultsDomain)
        #expect(prefixed.legacyKeychainService == "t1." + production.legacyKeychainService)
        #expect(prefixed.newKeychainService == "t1." + production.newKeychainService)
        // Files follow HOME, so the folder names are never prefixed.
        #expect(prefixed.legacyFolderName == production.legacyFolderName)
        #expect(prefixed.newFolderName == production.newFolderName)
    }

    @Test func productionNamesAreTheDocumentedIdentity() {
        let names = IdentityMigration.Names.production
        #expect(names.newDefaultsDomain == "ai.useful.voice")
        #expect(names.newKeychainService == Keychain.service)
        #expect(names.newKeychainService == "ai.useful.voice")
        #expect(names.newFolderName == "UsefulVoice")
        #expect(names.legacyDefaultsDomain == IdentityMigration.Legacy.bundleID)
        #expect(names.legacyKeychainService == IdentityMigration.Legacy.keychainService)
        #expect(names.legacyFolderName == IdentityMigration.Legacy.dataFolderName)
    }
}

@Suite("Identity migration: data folder")
struct DataFolderTests {
    private func makeSupport() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-datafolder-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func put(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: url)
    }

    private func listing(_ root: URL) -> [String] {
        let walker = FileManager.default.enumerator(atPath: root.path)
        return (walker?.allObjects as? [String] ?? []).sorted()
    }

    @Test func normalRunsAlwaysUseTheNewFolder() {
        let support = makeSupport(); defer { try? FileManager.default.removeItem(at: support) }
        put(support.appendingPathComponent("Sadaa/history.json"))

        let url = DataFolder.resolve(appSupport: support, preview: false)

        #expect(url.lastPathComponent == "UsefulVoice")
    }

    @Test func previewReadsTheLegacyFolderOnlyWhileItHoldsData() {
        let support = makeSupport(); defer { try? FileManager.default.removeItem(at: support) }

        // Nothing anywhere.
        #expect(DataFolder.resolve(appSupport: support, preview: true).lastPathComponent == "UsefulVoice")

        // An empty legacy folder holds nothing.
        try? FileManager.default.createDirectory(
            at: support.appendingPathComponent("Sadaa"), withIntermediateDirectories: true)
        #expect(DataFolder.resolve(appSupport: support, preview: true).lastPathComponent == "UsefulVoice")

        // Data that has not moved yet; the new folder only holds models/.
        put(support.appendingPathComponent("Sadaa/history.json"))
        put(support.appendingPathComponent("UsefulVoice/models/m.bin"))
        #expect(DataFolder.resolve(appSupport: support, preview: true).lastPathComponent == "Sadaa")

        // Only a clash is left: that data has been migrated, the new folder is the truth.
        put(support.appendingPathComponent("UsefulVoice/history.json"))
        #expect(DataFolder.resolve(appSupport: support, preview: true).lastPathComponent == "UsefulVoice")
    }

    @Test func resolvingTheFolderChangesNothing() {
        let support = makeSupport(); defer { try? FileManager.default.removeItem(at: support) }
        put(support.appendingPathComponent("Sadaa/history.json"))
        put(support.appendingPathComponent("UsefulVoice/models/m.bin"))
        let before = listing(support)

        _ = DataFolder.resolve(appSupport: support, preview: true)
        _ = DataFolder.resolve(appSupport: support, preview: false)

        #expect(listing(support) == before)
    }
}

@Suite("Identity migration: launch-at-login signal")
struct LoginSignalTests {
    private func line(_ tail: String) -> String {
        "2026-10-01T09:00:00Z [INFO] launch: Useful Voice 0.1.0 (12) on macOS Version 15.0 (Build 24A); \(tail)"
    }

    @Test func theLegacyLaunchLineSaysWhetherLoginWasOn() {
        #expect(IdentityMigration.launchedAtLogin(inDiagnosticsLog: line("starts at login")) == true)
        #expect(IdentityMigration.launchedAtLogin(inDiagnosticsLog: line("manual start")) == false)
        // The LAST launch line wins.
        let both = [line("starts at login"), "2026-10-02T09:00:00Z [ERROR] keychain: x", line("manual start")]
            .joined(separator: "\n") + "\n"
        #expect(IdentityMigration.launchedAtLogin(inDiagnosticsLog: both) == false)
        // No launch line, or one we cannot read: no signal rather than a guess.
        #expect(IdentityMigration.launchedAtLogin(inDiagnosticsLog: "") == nil)
        #expect(IdentityMigration.launchedAtLogin(inDiagnosticsLog: "garbage\nmore garbage") == nil)
        #expect(IdentityMigration.launchedAtLogin(inDiagnosticsLog: line("something else")) == nil)
    }

    @Test func theLoginSignalIsReadOnce() throws {
        let h = Harness(); defer { h.cleanUp() }
        h.legacy("diagnostics.log", line("starts at login") + "\n")
        h.legacy("history.json", "[1]")

        let first = h.migration().run(diagnostics: h.silentDiagnostics())
        #expect(first.legacyLaunchedAtLogin == true)

        // A clash keeps the old log in the old folder; the signal must not fire again.
        h.legacy("diagnostics.log", line("starts at login") + "\n")
        h.new("diagnostics.log", "new")
        let second = h.migration().run(diagnostics: h.silentDiagnostics())
        #expect(second.legacyLaunchedAtLogin == nil)
    }

    @Test func theSignalIsReadEvenWhenTheLogClashes() {
        let h = Harness(); defer { h.cleanUp() }
        h.new("diagnostics.log", "new log without a launch line")
        h.legacy("diagnostics.log", line("starts at login") + "\n")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.conflicts == ["diagnostics.log"])
        #expect(report.legacyLaunchedAtLogin == true)
    }

    @Test func noLegacyLogMeansNoSignal() {
        let h = Harness(); defer { h.cleanUp() }
        h.legacy("history.json", "[1]")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.legacyLaunchedAtLogin == nil)
    }
}
