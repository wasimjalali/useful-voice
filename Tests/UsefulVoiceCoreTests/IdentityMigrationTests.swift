import Foundation
import Security
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
//  D10 A setup the old identity finished is checked against the grants again
//      (the rename drops Accessibility and Microphone): the recheck flag is set
//      only then, once.
//      -> aSetupTheOldIdentityFinishedIsCheckedAgainAfterTheRename and its siblings
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
    var deniedServices: Set<String> = []                   // overridden lookups that are user refusals
    var unusableServices: Set<String> = []                 // overridden lookups whose value can never be used
    var failWrites = false
    var failDeletes: Set<String> = []                      // services
    var denyDeletes: Set<String> = []                      // services whose delete the user refuses
    /// Runs after `exists` has computed its answer, to simulate another process.
    var afterExists: [String: () -> Void] = [:]
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
        let answer = items[key(service, account)] != nil
        let hook = afterExists[service]
        lock.unlock()
        hook?()
        lock.lock()
        return answer
    }

    func lookup(service: String, account: String) -> MigrationLookup {
        lock.lock(); defer { lock.unlock() }
        lookups.append(service)
        if let forced = lookupOverride[service] {
            return MigrationLookup(forced, userDenied: deniedServices.contains(service),
                                   unusable: unusableServices.contains(service))
        }
        guard let value = items[key(service, account)] else { return MigrationLookup(.absent) }
        return MigrationLookup(.found(value))
    }

    func write(_ value: String, service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw KeychainError.unexpectedStatus(-25308) }
        items[key(service, account)] = corruptWrites ? value + "-corrupt" : value
    }

    func delete(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        deletes.append(service)
        if denyDeletes.contains(service) { throw KeychainError.unexpectedStatus(errSecUserCanceled) }
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
            // An absolute path is a preferences domain stored at that path, so the
            // plist lives in this test's temp folder and is deleted with it, not in
            // ~/Library/Preferences.
            legacyDefaultsDomain: root.appendingPathComponent("legacy-defaults").path,
            newDefaultsDomain: root.appendingPathComponent("new-defaults").path,
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
        defaults.removePersistentDomain(forName: names.newDefaultsDomain)
        defaults.synchronize()
        try? FileManager.default.removeItem(at: root)
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

    // The renamed app has no Accessibility or Microphone grant (macOS keys them to the
    // bundle id), so a setup the old identity finished must be checked again (WAS-30).

    @Test func aSetupTheOldIdentityFinishedIsCheckedAgainAfterTheRename() {
        let h = Harness(legacyDefaults: [FirstRunGate.completedKey: true]); defer { h.cleanUp() }

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(h.defaults.bool(forKey: FirstRunGate.recheckGrantsKey))
        // The flag is not a copied preference.
        #expect(report.defaultsCopied == 1)
        // What the first-run model then asks the gate: setup counts as unfinished while
        // a grant is missing, and the flow shows.
        let decision = FirstRunGate.decide(
            completed: h.defaults.bool(forKey: FirstRunGate.completedKey),
            engineConfigured: true, microphoneAuthorized: false, accessibilityTrusted: false,
            forced: false, grantsNeedRecheck: h.defaults.bool(forKey: FirstRunGate.recheckGrantsKey))
        #expect(decision == .show)
    }

    @Test func aMigratedInstallWithBothGrantsBackIsNotShownTheFlow() {
        let h = Harness(legacyDefaults: [FirstRunGate.completedKey: true]); defer { h.cleanUp() }
        _ = h.migration().run(diagnostics: h.silentDiagnostics())

        let decision = FirstRunGate.decide(
            completed: h.defaults.bool(forKey: FirstRunGate.completedKey),
            engineConfigured: true, microphoneAuthorized: true, accessibilityTrusted: true,
            forced: false, grantsNeedRecheck: h.defaults.bool(forKey: FirstRunGate.recheckGrantsKey))
        #expect(decision == .skipAndMarkCompleted)
    }

    @Test func noRecheckWhenTheOldIdentityNeverFinishedSetup() {
        let legacies: [[String: Any]] = [[FirstRunGate.completedKey: false], ["appearance": "dark"]]
        for legacy in legacies {
            let h = Harness(legacyDefaults: legacy); defer { h.cleanUp() }
            _ = h.migration().run(diagnostics: h.silentDiagnostics())
            #expect(!h.defaults.bool(forKey: FirstRunGate.recheckGrantsKey))
        }
    }

    @Test func noRecheckForANewInstallWithNothingToMigrate() {
        let h = Harness(legacyDefaults: nil); defer { h.cleanUp() }
        _ = h.migration().run(diagnostics: h.silentDiagnostics())
        #expect(!h.defaults.bool(forKey: FirstRunGate.recheckGrantsKey))
    }

    /// The new identity already ran its own setup: that answer wins, as every key in both does.
    @Test func noRecheckWhenTheNewIdentityAlreadyAnsweredSetup() {
        let h = Harness(legacyDefaults: [FirstRunGate.completedKey: true]); defer { h.cleanUp() }
        h.defaults.set(true, forKey: FirstRunGate.completedKey)

        _ = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(!h.defaults.bool(forKey: FirstRunGate.recheckGrantsKey))
    }

    /// Once the user finishes setup the flag is cleared; a later launch must not bring it back.
    @Test func theRecheckIsSetOnceAndNotAgainOnTheNextLaunch() {
        let h = Harness(legacyDefaults: [FirstRunGate.completedKey: true]); defer { h.cleanUp() }
        _ = h.migration().run(diagnostics: h.silentDiagnostics())
        h.defaults.removeObject(forKey: FirstRunGate.recheckGrantsKey)   // setup finished

        _ = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(!h.defaults.bool(forKey: FirstRunGate.recheckGrantsKey))
        #expect(h.defaults.bool(forKey: FirstRunGate.completedKey))
    }

    @Test func theLegacyDomainIsLeftUntouched() {
        let legacyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-legacy-defaults-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        let legacyName = legacyRoot.appendingPathComponent("legacy").path
        let legacySuite = UserDefaults(suiteName: legacyName)!
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
        #expect(h.keychain.value(service: h.names.newKeychainService) == "new-key")
        // The leftover old copy is cleaned up without ever being read.
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == nil)
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
        h.keychain.deniedServices = [h.names.legacyKeychainService]

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
        // Not a refusal, so not remembered: the next launch tries again and works.
        #expect(!h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
        h.keychain.failWrites = false
        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .migrated)
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
        #expect(!h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
    }

    @Test func aLeftoverLegacyItemDoesNotUndoAGoodMigration() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.failDeletes = [h.names.legacyKeychainService]

        let first = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(first == .migratedLegacyRemains)
        #expect(h.keychain.value(service: h.names.newKeychainService) == "old-key")

        // The next launch finds the new item and retries removing the leftover.
        h.keychain.failDeletes = []
        let second = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())
        #expect(second == .alreadyPresent)
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == nil)
        #expect(h.keychain.lookups == [h.names.legacyKeychainService, h.names.newKeychainService])   // never re-read
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
        #expect(h.defaults.bool(forKey: IdentityMigration.loginRestorePendingFlag))

        // The restore happened. A clash then keeps an old log in the old folder; it
        // must not set the flag again behind the user's back.
        h.defaults.removeObject(forKey: IdentityMigration.loginRestorePendingFlag)
        h.legacy("diagnostics.log", line("starts at login") + "\n")
        h.new("diagnostics.log", "new")
        let second = h.migration().run(diagnostics: h.silentDiagnostics())
        #expect(second.legacyLaunchedAtLogin == nil)
        #expect(!h.defaults.bool(forKey: IdentityMigration.loginRestorePendingFlag))
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

// MARK: - Review round 1: more failure modes
//
//  R1  Stored absolute recording paths still point into the old folder after the
//      move: they must resolve inside today's Recordings folder, and only there.
//      -> RecordingLocatorTests
//  R2  An older copy of the app runs beside the new one: it is asked to quit,
//      waited for (bounded), and if it stays the migration is postponed.
//      -> LegacyInstancesTests, LaunchMigrationTests
//  R3  keyIsStored must not see both items missing while a migration swaps them.
//      -> keyPresenceChecksTheLegacyItemFirst
//  R4  A transient Keychain failure (locked at login, failed write, bad read-back)
//      is retried next launch; only a refusal is remembered.
//      -> aLockedKeychainIsRetriedNextLaunch, aFailedVerifyThatCannotReadBackIsRetried,
//         aFailedWriteLeavesTheLegacyItemAlone, aDeniedReadDeletesNothingAndIsNeverRetried
//  R5  A listed item that then reads as absent is "absent", not a crash.
//      -> anItemThatVanishesBetweenExistsAndReadIsAbsent
//  R6  Launch at login stays pending until confirmed on.
//      -> LoginRestoreTests
//  R7  Migrate-only is refused unless CFFIXED_USER_HOME is a scratch home.
//      -> MigrateOnlyRefusalTests
//  R8  Finder litter clashes vanish; a clash is logged once; models/ is not walked.
//      -> disposableClashesAreDropped, aClashIsLoggedOnce, onlyMovedEntriesAreRestricted
//  R9  Removing the key also removes the old identity's copy; a leftover is retried.
//      -> removingTheKeyAlsoRemovesTheLegacyCopy, aLeftoverIsCleanedUpOnALaterLaunch,
//         aRefusedLeftoverDeleteIsNotAskedAgain
//  R10 Log > 64 KB, a symlinked old folder, a regular file where the new folder
//      goes, a real Diagnostics launch line.
//      -> hugeLegacyLogOnlyItsTailIsRead, aSymlinkedLegacyFolderIsLeftAlone,
//         aRegularFileWhereTheNewFolderGoesFailsLoudly, theRealLaunchLineIsParsed
//  R11 A postponed launch (older copy still running) touches nothing.
//      -> runWithoutMovingFilesDoesNothing, LaunchMigrationTests

@Suite("Identity migration: recordings")
struct RecordingLocatorTests {
    private func makeRecordings() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uv-rec-\(UUID().uuidString)/Recordings")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aStoredPathThatStillExistsInTheFolderWins() throws {
        let dir = makeRecordings(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let file = dir.appendingPathComponent("keep.wav")
        try Data("a".utf8).write(to: file)

        let url = RecordingLocator.resolve(storedPath: file.path, recordingsDirectory: dir)

        #expect(url?.path == file.path)
    }

    @Test func aPathInTheOldFolderResolvesInsideTheNewRecordingsFolder() throws {
        let dir = makeRecordings(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try Data("a".utf8).write(to: dir.appendingPathComponent("20261001-090000.wav"))

        let url = RecordingLocator.resolve(
            storedPath: "/Users/someone/Library/Application Support/Sadaa/Recordings/20261001-090000.wav",
            recordingsDirectory: dir)

        #expect(url?.path == dir.appendingPathComponent("20261001-090000.wav").path)
    }

    @Test func aMissingFileOrAHostileNameResolvesToNothing() throws {
        let dir = makeRecordings(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        // A secret next to (not inside) the recordings folder.
        try Data("secret".utf8).write(to: dir.deletingLastPathComponent().appendingPathComponent("secret.txt"))

        #expect(RecordingLocator.resolve(storedPath: "/gone/Recordings/x.wav", recordingsDirectory: dir) == nil)
        #expect(RecordingLocator.resolve(storedPath: "/gone/Recordings/../secret.txt", recordingsDirectory: dir) == nil)
        #expect(RecordingLocator.resolve(storedPath: "/gone/Recordings/..", recordingsDirectory: dir) == nil)
        #expect(RecordingLocator.resolve(storedPath: "", recordingsDirectory: dir) == nil)
        #expect(RecordingLocator.resolve(storedPath: "/", recordingsDirectory: dir) == nil)
    }

    /// The real sequence: a record written by the old build, then the migration,
    /// then Retry looks the recording up.
    @Test func aSadaaPathRecordWorksAfterTheMigration() {
        let h = Harness(); defer { h.cleanUp() }
        let oldPath = h.legacyFolder.appendingPathComponent("Recordings/r1.wav").path
        h.legacy("Recordings/r1.wav", "audio")
        let record = DictationRecord(text: "hi", createdAt: Date(), language: "en",
                                     provider: "deepgram", durationSeconds: 1, audioPath: oldPath)
        _ = h.migration().run(diagnostics: h.silentDiagnostics())
        #expect(!h.exists(URL(fileURLWithPath: oldPath)))

        let url = RecordingLocator.resolve(
            storedPath: record.audioPath ?? "",
            recordingsDirectory: h.newFolder.appendingPathComponent("Recordings"))

        #expect(url?.path == h.newFolder.appendingPathComponent("Recordings/r1.wav").path)
        #expect(url.flatMap { h.text($0) } == "audio")
    }
}

private final class FakeLegacyCopies: @unchecked Sendable {
    var running: [Int32]
    let quitsWhenAsked: Bool
    private(set) var quitRequests = 0
    private(set) var sleeps: [TimeInterval] = []

    init(running: [Int32], quitsWhenAsked: Bool) {
        self.running = running
        self.quitsWhenAsked = quitsWhenAsked
    }

    var instances: LegacyInstances {
        LegacyInstances(
            runningPIDs: { self.running },
            requestQuit: {
                self.quitRequests += 1
                if self.quitsWhenAsked { self.running = [] }
            },
            sleep: { self.sleeps.append($0) })
    }
}

@Suite("Identity migration: older copies")
struct LegacyInstancesTests {
    @Test func nothingRunningMeansNothingAsked() {
        let fake = FakeLegacyCopies(running: [], quitsWhenAsked: true)
        let result = fake.instances.clear()
        #expect(result.found.isEmpty && result.remaining.isEmpty)
        #expect(fake.quitRequests == 0)
    }

    @Test func aCopyThatQuitsIsWaitedFor() {
        let fake = FakeLegacyCopies(running: [42], quitsWhenAsked: true)
        let result = fake.instances.clear()
        #expect(result.found == [42])
        #expect(result.remaining.isEmpty)
        #expect(fake.quitRequests == 1)
    }

    @Test func aCopyThatStaysIsReportedAfterABoundedWait() {
        let fake = FakeLegacyCopies(running: [42, 43], quitsWhenAsked: false)
        let result = fake.instances.clear(timeout: 1, poll: 0.25)
        #expect(result.remaining == [42, 43])
        #expect(fake.quitRequests == 1)             // asked politely once, never killed
        #expect(fake.sleeps.count == 4)             // bounded: timeout / poll
    }
}

@Suite("Identity migration: launch")
struct LaunchMigrationTests {
    private func seeded() -> Harness {
        let h = Harness(legacyDefaults: ["uv.test.launch.\(UUID().uuidString)": "x"])
        h.legacy("history.json", "[1]")
        return h
    }

    @Test func aNormalLaunchMigrates() {
        let h = seeded(); defer { h.cleanUp() }
        let outcome = LaunchMigration.runAtLaunch(
            environment: [:], makeMigration: { _ in h.migration() }, legacyInstances: .none)

        #expect(outcome.report?.moved == ["history.json"])
        #expect(outcome.legacyStillRunning.isEmpty)
        #expect(h.exists(h.newFolder.appendingPathComponent("history.json")))
    }

    @Test func aRenderOrForcedFirstRunMigratesNothing() {
        for environment in [["UV_SNAPSHOT": "/tmp/x.png@10x10"], ["UV_FIRST_RUN": "force"]] {
            let h = seeded(); defer { h.cleanUp() }
            let outcome = LaunchMigration.runAtLaunch(
                environment: environment, makeMigration: { _ in h.migration() }, legacyInstances: .none)

            #expect(outcome.report == nil)
            #expect(h.exists(h.legacyFolder.appendingPathComponent("history.json")))
            #expect(!h.exists(h.newFolder))
            #expect(!h.defaults.bool(forKey: IdentityMigration.migratedFlag))
        }
    }

    @Test func migrateOnlyIsNotRunByTheLaunchPath() {
        let h = seeded(); defer { h.cleanUp() }
        let outcome = LaunchMigration.runAtLaunch(
            environment: ["UV_MIGRATE_ONLY": "1"], makeMigration: { _ in h.migration() }, legacyInstances: .none)

        #expect(outcome.report == nil)
        #expect(h.exists(h.legacyFolder.appendingPathComponent("history.json")))
    }

    @Test func anOlderCopyThatQuitsLetsTheMigrationRun() {
        let h = seeded(); defer { h.cleanUp() }
        let fake = FakeLegacyCopies(running: [7], quitsWhenAsked: true)

        let outcome = LaunchMigration.runAtLaunch(
            environment: [:], makeMigration: { _ in h.migration() }, legacyInstances: fake.instances)

        #expect(outcome.legacyFound == [7])
        #expect(outcome.legacyStillRunning.isEmpty)
        #expect(outcome.report?.moved == ["history.json"])
    }

    @Test func anOlderCopyThatStaysPostponesTheMigrationAndTouchesNothing() {
        let key = "uv.test.launch.\(UUID().uuidString)"
        let h = Harness(legacyDefaults: [key: "x"]); defer { h.cleanUp() }
        h.legacy("history.json", "[1]")
        let fake = FakeLegacyCopies(running: [7], quitsWhenAsked: false)

        let outcome = LaunchMigration.runAtLaunch(
            environment: [:], makeMigration: { _ in h.migration() }, legacyInstances: fake.instances)

        #expect(outcome.report == nil)
        #expect(outcome.legacyStillRunning == [7])
        #expect(outcome.mustQuitForLegacyCopy)          // the app shows an alert and exits
        #expect(h.exists(h.legacyFolder.appendingPathComponent("history.json")))
        #expect(!h.exists(h.newFolder))
        #expect(!h.defaults.bool(forKey: IdentityMigration.migratedFlag))
        // Nothing is applied either: the process is about to exit.
        #expect(h.defaults.string(forKey: key) == nil)
        // And a later launch, with the old copy gone, finishes the job.
        let later = LaunchMigration.runAtLaunch(
            environment: [:], makeMigration: { _ in h.migration() }, legacyInstances: .none)
        #expect(later.report?.moved == ["history.json"])
    }

    @Test func migrationAllowedOnlyForARealLaunch() {
        #expect(LaunchMode.migrationAllowed(environment: [:]))
        #expect(!LaunchMode.migrationAllowed(environment: ["UV_SNAPSHOT": "x"]))
        #expect(!LaunchMode.migrationAllowed(environment: ["UV_FIRST_RUN": "force"]))
        #expect(!LaunchMode.migrationAllowed(environment: ["UV_MIGRATE_ONLY": "1"]))
    }

    @Test func aLaunchThatDoesNotExitHasNothingToQuitFor() {
        let h = seeded(); defer { h.cleanUp() }
        let outcome = LaunchMigration.runAtLaunch(
            environment: [:], makeMigration: { _ in h.migration() }, legacyInstances: .none)
        #expect(!outcome.mustQuitForLegacyCopy)
    }
}

@Suite("Identity migration: migrate-only guard")
struct MigrateOnlyRefusalTests {
    private let home = "/Users/real"
    private let hook = ["UV_MIGRATE_ONLY": "1"]

    private func env(_ extra: [String: String]) -> [String: String] {
        hook.merging(extra) { $1 }
    }

    @Test func refusedWithoutAScratchHome() {
        let prefix = ["UV_MIGRATION_TEST_PREFIX": "t."]
        #expect(LaunchMode.migrateOnlyRefusal(environment: env(prefix), realHome: home) != nil)
        #expect(LaunchMode.migrateOnlyRefusal(
            environment: env(prefix.merging(["CFFIXED_USER_HOME": ""]) { $1 }), realHome: home) != nil)
        #expect(LaunchMode.migrateOnlyRefusal(
            environment: env(prefix.merging(["CFFIXED_USER_HOME": home]) { $1 }), realHome: home) != nil)
        #expect(LaunchMode.migrateOnlyRefusal(
            environment: env(prefix.merging(["CFFIXED_USER_HOME": home + "/"]) { $1 }), realHome: home) != nil)
    }

    /// The production Keychain and preferences must never be touched from the hook.
    @Test func refusedWithoutATestPrefix() {
        let scratch = ["CFFIXED_USER_HOME": "/private/tmp/scratch"]
        #expect(LaunchMode.migrateOnlyRefusal(environment: env(scratch), realHome: home) != nil)
        #expect(LaunchMode.migrateOnlyRefusal(
            environment: env(scratch.merging(["UV_MIGRATION_TEST_PREFIX": ""]) { $1 }), realHome: home) != nil)
    }

    @Test func allowedWithAScratchHomeAndAPrefixAndIgnoredOtherwise() {
        #expect(LaunchMode.migrateOnlyRefusal(
            environment: env(["CFFIXED_USER_HOME": "/private/tmp/scratch", "UV_MIGRATION_TEST_PREFIX": "t."]),
            realHome: home) == nil)
        #expect(LaunchMode.migrateOnlyRefusal(environment: [:], realHome: home) == nil)
        #expect(LaunchMode.migrateOnlyRefusal(
            environment: env(["UV_SNAPSHOT": "x", "CFFIXED_USER_HOME": "/private/tmp/scratch",
                              "UV_MIGRATION_TEST_PREFIX": "t."]),
            realHome: home) != nil)
    }
}

@Suite("Identity migration: launch at login restore")
struct LoginRestoreTests {
    private func pendingHarness() -> Harness {
        let h = Harness()
        h.defaults.set(true, forKey: IdentityMigration.loginRestorePendingFlag)
        return h
    }

    @Test func nothingPendingDoesNothing() {
        let h = Harness(); defer { h.cleanUp() }
        var enabled = 0
        let result = h.migration().restoreLoginItemIfPending(
            isEnabled: { false }, enable: { enabled += 1 }, diagnostics: h.silentDiagnostics())
        #expect(result == nil)
        #expect(enabled == 0)
    }

    @Test func enablesThenClearsThePendingFlag() {
        let h = pendingHarness(); defer { h.cleanUp() }
        var on = false
        let sink = h.silentDiagnostics()
        let result = h.migration().restoreLoginItemIfPending(
            isEnabled: { on }, enable: { on = true }, diagnostics: sink)
        #expect(result == true)
        #expect(!h.defaults.bool(forKey: IdentityMigration.loginRestorePendingFlag))
        #expect(sink.entries().contains { $0.message.contains("launch at login turned back on") })
    }

    @Test func alreadyOnJustClearsTheFlag() {
        let h = pendingHarness(); defer { h.cleanUp() }
        var enabled = 0
        let result = h.migration().restoreLoginItemIfPending(
            isEnabled: { true }, enable: { enabled += 1 }, diagnostics: h.silentDiagnostics())
        #expect(result == true)
        #expect(enabled == 0)
        #expect(!h.defaults.bool(forKey: IdentityMigration.loginRestorePendingFlag))
    }

    @Test func aFailedRegistrationStaysPendingForTheNextLaunch() {
        let h = pendingHarness(); defer { h.cleanUp() }
        struct Boom: Error {}
        let first = h.migration().restoreLoginItemIfPending(
            isEnabled: { false }, enable: { throw Boom() }, diagnostics: h.silentDiagnostics())
        #expect(first == false)
        #expect(h.defaults.bool(forKey: IdentityMigration.loginRestorePendingFlag))

        var on = false
        let second = h.migration().restoreLoginItemIfPending(
            isEnabled: { on }, enable: { on = true }, diagnostics: h.silentDiagnostics())
        #expect(second == true)
        #expect(!h.defaults.bool(forKey: IdentityMigration.loginRestorePendingFlag))
    }

    @Test func aRegistrationThatDoesNotTakeStaysPending() {
        let h = pendingHarness(); defer { h.cleanUp() }
        let result = h.migration().restoreLoginItemIfPending(
            isEnabled: { false }, enable: {}, diagnostics: h.silentDiagnostics())
        #expect(result == false)
        #expect(h.defaults.bool(forKey: IdentityMigration.loginRestorePendingFlag))
    }

    /// The launch line the app really writes, through a real file-backed sink.
    @Test func theRealLaunchLineIsParsed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uv-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = Diagnostics(directory: dir)
        sink.info("launch", "Useful Voice 0.1.0 (12) on macOS Version 15.0; \(IdentityMigration.LaunchLine.startsAtLogin)")
        sink.flush()
        let on = try String(contentsOf: dir.appendingPathComponent("diagnostics.log"), encoding: .utf8)
        #expect(IdentityMigration.launchedAtLogin(inDiagnosticsLog: on) == true)

        sink.info("launch", "Useful Voice 0.1.0 (12) on macOS Version 15.0; \(IdentityMigration.LaunchLine.manualStart)")
        sink.flush()
        let off = try String(contentsOf: dir.appendingPathComponent("diagnostics.log"), encoding: .utf8)
        #expect(IdentityMigration.launchedAtLogin(inDiagnosticsLog: off) == false)
    }
}

@Suite("Identity migration: more files and Keychain cases")
struct IdentityMigrationReviewTests {
    private func line(_ tail: String) -> String {
        "2026-10-01T09:00:00Z [INFO] launch: Useful Voice 0.1.0 (12) on macOS Version 15.0; \(tail)"
    }

    @Test func hugeLegacyLogOnlyItsTailIsRead() {
        let junk = String(repeating: "2026-10-01T09:00:00Z [INFO] other: filler line\n", count: 3_000)   // > 64 KB
        #expect(junk.utf8.count > 64 * 1024)

        let tailCase = Harness(); defer { tailCase.cleanUp() }
        tailCase.legacy("diagnostics.log", junk + line("starts at login") + "\n")
        #expect(tailCase.migration().run(diagnostics: tailCase.silentDiagnostics()).legacyLaunchedAtLogin == true)

        let headCase = Harness(); defer { headCase.cleanUp() }
        headCase.legacy("diagnostics.log", line("starts at login") + "\n" + junk)
        #expect(headCase.migration().run(diagnostics: headCase.silentDiagnostics()).legacyLaunchedAtLogin == nil)
    }

    @Test func aSymlinkedLegacyFolderIsRenamedWhenTheNewFolderIsFree() throws {
        let h = Harness(); defer { h.cleanUp() }
        let target = h.root.appendingPathComponent("elsewhere")
        h.put(target.appendingPathComponent("history.json"), "[1]")
        h.put(target.appendingPathComponent("diagnostics.log"),
              "2026-10-01T09:00:00Z [INFO] launch: Useful Voice 0.1.0 (12) on macOS Version 15.0; starts at login\n")
        try FileManager.default.createSymbolicLink(at: h.legacyFolder, withDestinationURL: target)

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        // The link itself moved: the user's chosen location keeps holding the data.
        #expect(report.legacyLinkRenamed)
        #expect(report.failed.isEmpty)
        #expect(!h.exists(h.legacyFolder))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: h.newFolder.path)) == target.path)
        #expect(h.text(h.newFolder.appendingPathComponent("history.json")) == "[1]")
        #expect(h.text(target.appendingPathComponent("history.json")) == "[1]")
        // The login signal was read through the link before it moved.
        #expect(report.legacyLaunchedAtLogin == true)
    }

    @Test func aSymlinkedLegacyFolderStaysInUseWhenTheNewFolderIsTaken() throws {
        let h = Harness(); defer { h.cleanUp() }
        let target = h.root.appendingPathComponent("elsewhere")
        h.put(target.appendingPathComponent("history.json"), "[1]")
        h.new("models/m.bin", "weights")          // UsefulVoice/ exists, so the link cannot be renamed onto it
        try FileManager.default.createSymbolicLink(at: h.legacyFolder, withDestinationURL: target)
        let sink = h.silentDiagnostics()

        let first = h.migration().run(diagnostics: sink)
        let second = h.migration().run(diagnostics: sink)

        #expect(!first.legacyLinkRenamed)
        #expect(first.moved.isEmpty)
        #expect(first.failed.count == 1 && first.failed[0].contains("symbolic link"))
        #expect(second.failed.count == 1)                                   // still reported ...
        #expect(sink.entries(level: .error).filter { $0.message.contains("symbolic link") }.count == 1)   // ... logged once
        #expect(h.text(target.appendingPathComponent("history.json")) == "[1]")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: h.legacyFolder.path)) == target.path)
        // The app keeps using the linked folder, so the user never sees an empty app.
        #expect(DataFolder.resolve(appSupport: h.appSupport, preview: false, names: h.names).lastPathComponent
                == h.names.legacyFolderName)
    }

    /// An unmounted volume leaves a dangling link. New data must not start piling up in
    /// the new folder while the link is down, so the app stays on the link.
    @Test func aDanglingLinkStillKeepsTheAppOnTheLink() throws {
        let h = Harness(); defer { h.cleanUp() }
        h.new("models/m.bin", "weights")
        try FileManager.default.createSymbolicLink(
            at: h.legacyFolder, withDestinationURL: h.root.appendingPathComponent("not-mounted"))
        let sink = h.silentDiagnostics()

        let first = h.migration().run(diagnostics: sink)
        let second = h.migration().run(diagnostics: sink)

        #expect(DataFolder.resolve(appSupport: h.appSupport, preview: false, names: h.names).lastPathComponent
                == h.names.legacyFolderName)
        #expect(first.failed.count == 1 && first.failed[0].contains("cannot be reached"))
        #expect(second.failed.count == 1)
        let logged = sink.entries(level: .error).filter { $0.message.contains("cannot be reached") }
        #expect(logged.count == 1)                              // once
        #expect(logged[0].message.contains("keeps using"))      // and it says what the app does
    }

    @Test func aNormalLegacyFolderNeverKeepsTheAppOnTheOldPath() {
        let h = Harness(); defer { h.cleanUp() }
        h.legacy("history.json", "[1]")
        #expect(DataFolder.resolve(appSupport: h.appSupport, preview: false, names: h.names).lastPathComponent
                == h.names.newFolderName)
    }

    @Test func aRegularFileWhereTheNewFolderGoesFailsLoudly() {
        let h = Harness(); defer { h.cleanUp() }
        h.put(h.newFolder, "i am a file")
        h.legacy("history.json", "[1]")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.moved.isEmpty)
        #expect(!report.failed.isEmpty)
        #expect(h.text(h.legacyFolder.appendingPathComponent("history.json")) == "[1]")
        #expect(h.text(h.newFolder) == "i am a file")
    }

    @Test func disposableClashesAreDropped() {
        let h = Harness(); defer { h.cleanUp() }
        h.new(".DS_Store", "new finder")
        h.new("Icon\r", "new icon")
        h.legacy(".DS_Store", "old finder")
        h.legacy("Icon\r", "old icon")
        h.legacy("history.json", "[1]")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(Set(report.discarded) == [".DS_Store", "Icon\r"])
        #expect(report.conflicts.isEmpty)
        #expect(report.moved == ["history.json"])
        #expect(report.legacyFolderRemoved)
        #expect(h.text(h.newFolder.appendingPathComponent(".DS_Store")) == "new finder")
    }

    @Test func aClashIsLoggedOnce() {
        let h = Harness(); defer { h.cleanUp() }
        h.new("diagnostics.log", "new")
        h.legacy("diagnostics.log", "old")
        let sink = h.silentDiagnostics()

        _ = h.migration().run(diagnostics: sink)
        let second = h.migration().run(diagnostics: sink)

        #expect(second.conflicts == ["diagnostics.log"])   // still reported ...
        #expect(sink.entries(level: .warning).filter { $0.message.contains("diagnostics.log") }.count == 1)   // ... but logged once
    }

    @Test func onlyMovedEntriesAreRestricted() throws {
        let h = Harness(); defer { h.cleanUp() }
        h.new("models/m.bin", "weights")
        let model = h.newFolder.appendingPathComponent("models/m.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: model.path)
        h.legacy("history.json", "[1]")

        _ = h.migration().run(diagnostics: h.silentDiagnostics())

        let mode = (try? FileManager.default.attributesOfItem(atPath: model.path))?[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o644)   // not re-walked
    }

    @Test func runWithoutMovingFilesDoesNothing() {
        let h = Harness(legacyDefaults: ["a": 1]); defer { h.cleanUp() }
        h.legacy("history.json", "[1]")

        let report = h.migration().run(diagnostics: h.silentDiagnostics(), moveFiles: false)

        #expect(report == IdentityMigration.Report())
        #expect(h.exists(h.legacyFolder.appendingPathComponent("history.json")))
        #expect(!h.defaults.bool(forKey: IdentityMigration.migratedFlag))
    }

    // MARK: Keychain

    @Test func keyPresenceChecksTheLegacyItemFirst() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        // A migration finishing right after the check of the NEW item would make a
        // new-first order see both missing; legacy-first never gets that far.
        h.keychain.afterExists[h.names.newKeychainService] = {
            h.keychain.seed("old-key", service: h.names.newKeychainService)
            try? h.keychain.delete(service: h.names.legacyKeychainService, account: DeepgramKeyStore.account)
        }

        #expect(h.migration().keyIsStored())
        #expect(h.keychain.existsCalls.first == h.names.legacyKeychainService)
    }

    @Test func aLockedKeychainIsRetriedNextLaunch() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.lookupOverride[h.names.legacyKeychainService] = .unavailable("the keychain is locked")

        let first = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(first == .readFailed)
        #expect(!h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
        #expect(h.keychain.deletes.isEmpty)
        #expect(h.migration().keyIsStored())              // still counts: the key is there

        h.keychain.lookupOverride[h.names.legacyKeychainService] = nil
        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .migrated)
    }

    @Test func aFailedVerifyThatCannotReadBackIsRetried() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.lookupOverride[h.names.newKeychainService] = .unavailable("the keychain returned status -1")

        let outcome = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(outcome == .verifyFailed)
        #expect(h.keychain.value(service: h.names.newKeychainService) == nil)
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == "old-key")
        #expect(!h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
    }

    @Test func anItemThatVanishesBetweenExistsAndReadIsAbsent() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.lookupOverride[h.names.legacyKeychainService] = .absent

        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .absent)
        #expect(h.keychain.deletes.isEmpty)
        #expect(h.keychain.value(service: h.names.newKeychainService) == nil)
    }

    @Test func aRefusedLeftoverDeleteIsNotAskedAgain() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.denyDeletes = [h.names.legacyKeychainService]

        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .migratedLegacyRemains)
        #expect(h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
        let deletesSoFar = h.keychain.deletes.count

        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .alreadyPresent)
        #expect(h.keychain.deletes.count == deletesSoFar)   // no second prompt
    }

    @Test func aLeftoverIsCleanedUpOnALaterLaunch() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("new-key", service: h.names.newKeychainService)
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)

        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .alreadyPresent)
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == nil)
        #expect(h.keychain.value(service: h.names.newKeychainService) == "new-key")
        #expect(h.keychain.lookups.isEmpty)
    }

    @Test func removingTheLegacyKeyIgnoresAnEarlierRefusalWhenForced() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.defaults.set(true, forKey: IdentityMigration.keychainAttemptedFlag)

        #expect(!h.migration().removeLegacyKey(diagnostics: h.silentDiagnostics()))
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == "old-key")
        #expect(h.migration().removeLegacyKey(force: true, diagnostics: h.silentDiagnostics()))
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == nil)
    }
}

private final class RecordingKeyBackend: DeepgramKeyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var deletes = 0
    private(set) var legacyDeletes = 0
    func lookup() -> Keychain.Lookup { .absent }
    func write(_ value: String) throws {}
    func delete() throws { lock.lock(); deletes += 1; lock.unlock() }
    func exists() -> Bool { false }
    func deleteLegacyBestEffort() { lock.lock(); legacyDeletes += 1; lock.unlock() }
}

@Suite("Identity migration: removing the key")
struct RemoveKeyTests {
    @Test func removingTheKeyAlsoRemovesTheLegacyCopy() async throws {
        let backend = RecordingKeyBackend()
        let store = DeepgramKeyStore(backend: backend)

        try await store.remove()
        _ = store.peek()          // the legacy cleanup is queued behind remove, so this waits for it

        #expect(backend.deletes == 1)
        #expect(backend.legacyDeletes == 1)
    }
}

// MARK: - Review round 2

@Suite("Identity migration: round 2")
struct IdentityMigrationRound2Tests {
    private func line(_ tail: String) -> String {
        "2026-10-01T09:00:00Z [INFO] launch: Useful Voice 0.1.0 (12) on macOS Version 15.0; \(tail)"
    }

    // MARK: launch line

    /// A render or a refused launch must not turn "starts at login" into "manual
    /// start" in the old log: only lines the OLD build wrote count.
    @Test func newBuildLaunchLinesDoNotCountAsTheOldBuildsSignal() {
        let newLine = "2026-10-02T09:00:00Z [INFO] launch: "
            + IdentityMigration.LaunchLine.message(
                version: "0.2.0", build: "5", os: "Version 15.0", loginEnabled: false)
        let log = line("starts at login") + "\n" + newLine + "\n"

        #expect(IdentityMigration.launchedAtLogin(inDiagnosticsLog: log) == true)
        #expect(IdentityMigration.launchedAtLogin(inDiagnosticsLog: newLine + "\n") == nil)
    }

    @Test func theNewBuildsLaunchLineKeepsTheLoginPhraseAndCarriesTheTag() {
        let on = IdentityMigration.LaunchLine.message(
            version: "1", build: "2", os: "X", loginEnabled: true)
        let off = IdentityMigration.LaunchLine.message(
            version: "1", build: "2", os: "X", loginEnabled: false)
        #expect(on.hasSuffix(IdentityMigration.LaunchLine.startsAtLogin))
        #expect(off.hasSuffix(IdentityMigration.LaunchLine.manualStart))
        #expect(on.contains(IdentityMigration.LaunchLine.newBuildTag))
        #expect(on.contains("Useful Voice 1 (2)"))
    }

    @Test func aRenderLineAfterTheOldLogStillMigratesLoginAsOn() {
        let h = Harness(); defer { h.cleanUp() }
        let render = "2026-10-02T09:00:00Z [INFO] launch: "
            + IdentityMigration.LaunchLine.message(version: "0.2.0", build: "5", os: "15", loginEnabled: false)
        h.legacy("diagnostics.log", line("starts at login") + "\n" + render + "\n")

        let report = h.migration().run(diagnostics: h.silentDiagnostics())

        #expect(report.legacyLaunchedAtLogin == true)
        #expect(h.defaults.bool(forKey: IdentityMigration.loginRestorePendingFlag))
    }

    // MARK: Keychain

    @Test func aForcedLegacyDeleteThatFailsForAnyReasonStopsTheLeftoverCounting() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.failDeletes = [h.names.legacyKeychainService]   // not a refusal: a plain failure

        let gone = h.migration().removeLegacyKey(force: true, diagnostics: h.silentDiagnostics())

        #expect(!gone)
        #expect(h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
        // The user removed their key: the leftover must neither count as a key ...
        #expect(!h.migration().keyIsStored())
        // ... nor migrate back on the next launch.
        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .skippedAfterAttempt)
        #expect(h.keychain.value(service: h.names.newKeychainService) == nil)
    }

    @Test func anUnusableValueIsRememberedBecauseRetryingCannotHelp() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("x", service: h.names.legacyKeychainService)
        h.keychain.lookupOverride[h.names.legacyKeychainService] = .unavailable("the stored key is empty or not valid text")
        h.keychain.unusableServices = [h.names.legacyKeychainService]

        let first = h.migration().migrateKeychain(diagnostics: h.silentDiagnostics())

        #expect(first == .unusableValue)
        #expect(h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
        #expect(h.keychain.deletes.isEmpty)
        let reads = h.keychain.lookups.count
        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .skippedAfterAttempt)
        #expect(h.keychain.lookups.count == reads)
    }

    @Test func writeFailuresAreRetriedThenGivenUp() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.failWrites = true

        for attempt in 1...IdentityMigration.maxKeychainRetries {
            #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .writeFailed)
            #expect(h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag)
                    == (attempt == IdentityMigration.maxKeychainRetries))
        }
        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .skippedAfterAttempt)
        #expect(h.keychain.value(service: h.names.legacyKeychainService) == "old-key")   // never deleted
    }

    @Test func verifyFailuresCountTowardsTheSameCap() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.corruptWrites = true
        for _ in 1..<IdentityMigration.maxKeychainRetries {
            #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .verifyFailed)
        }
        #expect(!h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
        h.keychain.corruptWrites = false
        h.keychain.failWrites = true
        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .writeFailed)
        #expect(h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
    }

    @Test func aSuccessfulRetryNeedsNoCapReset() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        h.keychain.failWrites = true
        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .writeFailed)
        h.keychain.failWrites = false
        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .migrated)
    }

    // MARK: Key store ordering

    private final class SharedKeychainBackend: DeepgramKeyBackend, @unchecked Sendable {
        let keychain: FakeMigrationKeychain
        let service: String
        init(keychain: FakeMigrationKeychain, service: String) {
            self.keychain = keychain
            self.service = service
        }
        func lookup() -> Keychain.Lookup {
            keychain.lookup(service: service, account: DeepgramKeyStore.account).result
        }
        func write(_ value: String) throws {
            try keychain.write(value, service: service, account: DeepgramKeyStore.account)
        }
        func delete() throws {
            try keychain.delete(service: service, account: DeepgramKeyStore.account)
        }
        func exists() -> Bool { keychain.exists(service: service, account: DeepgramKeyStore.account) }
    }

    @Test func aLoadRightAfterTheMigrationSeesTheMigratedKey() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)
        let store = DeepgramKeyStore(
            backend: SharedKeychainBackend(keychain: h.keychain, service: h.names.newKeychainService))

        #expect(store.migrateLegacyKey(with: h.migration(), diagnostics: h.silentDiagnostics()) == .migrated)
        #expect(store.load() == "old-key")
        #expect(store.current == "old-key")
    }

    private final class SlowLegacyBackend: DeepgramKeyBackend, @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _legacyDeleted = false
        var legacyDeleted: Bool { lock.lock(); defer { lock.unlock() }; return _legacyDeleted }
        func lookup() -> Keychain.Lookup { .absent }
        func write(_ value: String) throws {}
        func delete() throws {}
        func exists() -> Bool { false }
        func deleteLegacyBestEffort() {
            gate.wait()                      // a Keychain prompt waiting for the user
            lock.lock(); _legacyDeleted = true; lock.unlock()
        }
    }

    @Test func removeDoesNotWaitOnALegacyPromptButStaysOrdered() async throws {
        let backend = SlowLegacyBackend()
        let store = DeepgramKeyStore(backend: backend)

        try await store.remove()                 // returns while the legacy delete is still blocked
        #expect(!backend.legacyDeleted)
        #expect(store.current == nil)

        backend.gate.signal()
        _ = store.peek()                          // queued behind the legacy delete
        #expect(backend.legacyDeleted)
    }

    // MARK: Recordings

    @Test func aStoredPathOutsideTheAppFoldersIsNotTrusted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uv-rec2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("UsefulVoice/Recordings")
        let legacyRecordings = root.appendingPathComponent("Sadaa/Recordings")
        let outside = root.appendingPathComponent("Documents")
        for dir in [recordings, legacyRecordings, outside] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("x.wav"))
        try Data("old".utf8).write(to: legacyRecordings.appendingPathComponent("old.wav"))
        try Data("new".utf8).write(to: recordings.appendingPathComponent("new.wav"))

        func resolve(_ path: String) -> String? {
            RecordingLocator.resolve(storedPath: path, recordingsDirectory: recordings,
                                     legacyRecordingsDirectory: legacyRecordings)?.path
        }
        // Inside either app folder: accepted as stored.
        #expect(resolve(recordings.appendingPathComponent("new.wav").path) == recordings.appendingPathComponent("new.wav").path)
        #expect(resolve(legacyRecordings.appendingPathComponent("old.wav").path) == legacyRecordings.appendingPathComponent("old.wav").path)
        // Outside: not read, and with no same-named file in the folder, nothing.
        #expect(resolve(outside.appendingPathComponent("x.wav").path) == nil)
        // A .. path that lands outside is outside.
        #expect(resolve(recordings.path + "/../../Documents/x.wav") == nil)
        // Outside but with a same-named file in the recordings folder: that file.
        try Data("mine".utf8).write(to: recordings.appendingPathComponent("x.wav"))
        #expect(resolve(outside.appendingPathComponent("x.wav").path) == recordings.appendingPathComponent("x.wav").path)
    }

    @Test func forgettingTheLegacyKeyStopsItCountingOrMigratingBack() {
        let h = Harness(); defer { h.cleanUp() }
        h.keychain.seed("old-key", service: h.names.legacyKeychainService)

        h.migration().forgetLegacyKey()

        #expect(h.defaults.bool(forKey: IdentityMigration.keychainAttemptedFlag))
        #expect(!h.migration().keyIsStored())
        #expect(h.migration().migrateKeychain(diagnostics: h.silentDiagnostics()) == .skippedAfterAttempt)
        #expect(h.keychain.lookups.isEmpty)
    }

    private final class OrderRecordingBackend: DeepgramKeyBackend, @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _events: [String] = []
        var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
        private func note(_ e: String) { lock.lock(); _events.append(e); lock.unlock() }
        func lookup() -> Keychain.Lookup { .absent }
        func write(_ value: String) throws {}
        func delete() throws { note("delete") }
        func exists() -> Bool { false }
        func forgetLegacyKey() { note("forget") }
        func deleteLegacyBestEffort() { gate.wait(); note("legacyDelete") }
    }

    /// If the app quits before the queued legacy delete runs, the flag is already set.
    @Test func removeMarksTheLegacyKeyForgottenBeforeTheQueuedDelete() async throws {
        let backend = OrderRecordingBackend()
        let store = DeepgramKeyStore(backend: backend)

        try await store.remove()

        #expect(backend.events == ["delete", "forget"])         // legacyDelete is still blocked
        backend.gate.signal()
        _ = store.peek()
        #expect(backend.events == ["delete", "forget", "legacyDelete"])
    }

    // MARK: Pasteboard markers

    @Test func deliveryMarkersOfBothIdentitiesAreOurs() {
        #expect(DeliveryMarker.marks(types: ["public.utf8-plain-text", DeliveryMarker.current]))
        #expect(DeliveryMarker.marks(types: [IdentityMigration.Legacy.deliveryMarker]))
        #expect(!DeliveryMarker.marks(types: ["public.utf8-plain-text", "public.html"]))
        #expect(!DeliveryMarker.marks(types: []))
        #expect(DeliveryMarker.current == "ai.useful.voice.delivery")
    }
}
