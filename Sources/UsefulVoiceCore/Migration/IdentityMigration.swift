import Foundation

/// Keychain operations the identity migration needs, by service. The app uses
/// the real Keychain; tests inject an in-memory fake.
/// A read of an item, with whether a failure was the user refusing access (as
/// opposed to a transient state such as a locked keychain, which is retried).
public struct MigrationLookup: Equatable, Sendable {
    public var result: Keychain.Lookup
    public var userDenied: Bool
    /// The item was read but its value can never be used (empty or not text), so
    /// reading it again cannot help.
    public var unusable: Bool

    public init(_ result: Keychain.Lookup, userDenied: Bool = false, unusable: Bool = false) {
        self.result = result
        self.userDenied = userDenied
        self.unusable = unusable
    }
}

public protocol MigrationKeychain: Sendable {
    /// Attributes only: must never decrypt, so it never prompts.
    func exists(service: String, account: String) -> Bool
    func lookup(service: String, account: String) -> MigrationLookup
    func write(_ value: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public struct SystemMigrationKeychain: MigrationKeychain {
    public init() {}

    public func exists(service: String, account: String) -> Bool {
        Keychain.exists(account: account, service: service)
    }

    public func lookup(service: String, account: String) -> MigrationLookup {
        let read = Keychain.lookupWithStatus(account: account, service: service)
        var unusable = false
        if read.status == errSecSuccess, case .unavailable = read.lookup { unusable = true }
        return MigrationLookup(read.lookup, userDenied: Keychain.isUserDenial(status: read.status),
                               unusable: unusable)
    }

    public func write(_ value: String, service: String, account: String) throws {
        try Keychain.set(value, account: account, service: service)
    }

    public func delete(service: String, account: String) throws {
        try Keychain.delete(account: account, service: service)
    }
}

/// The one-time move from the app's previous identity (bundle id `ai.karko.sadaa`,
/// data folder `Sadaa`) to Useful Voice (`ai.useful.voice`, `UsefulVoice`).
///
/// Three things carry over, each with its own rule:
///
///  * **Files**: every top-level entry of the old data folder moves to the new
///    one by rename, unless the new folder already has that name (then both stay
///    and the clash is logged). The old folder is removed only once it is empty.
///    It runs at every launch while the old folder exists, so an interrupted
///    run finishes on the next launch.
///  * **Preferences**: every key the new defaults domain lacks is copied from the
///    old domain, once. The old domain is never changed.
///  * **The Deepgram key**: copied to the new Keychain service, read back, and
///    only then deleted from the old one. Reading the old item may show one
///    Keychain prompt and deleting it may show another (the item trusts the old
///    app). A refused read deletes nothing and is never retried; a transient
///    failure (a locked keychain at login, a failed write) is retried next launch.
///
/// This type is the only place the previous identity's names live.
public struct IdentityMigration {
    /// The previous identity. Nothing else in the app may name these.
    public enum Legacy {
        public static let bundleID = "ai.karko.sadaa"
        public static let dataFolderName = "Sadaa"
        public static let keychainService = "ai.karko.sadaa"
        /// Pasteboard marker the old build put on its own paste, still ours.
        public static let deliveryMarker = "ai.karko.sadaa.delivery"
        /// Names that mean nothing on a clash and are simply dropped.
        static let disposableNames: Set<String> = [".DS_Store", "Icon\r"]
    }

    /// `UserDefaults` flag in the new domain: the preferences were copied.
    public static let migratedFlag = "uv.identityMigrated"
    /// Flag: the user refused access to the old Keychain item, so it is not asked again.
    public static let keychainAttemptedFlag = "uv.keychainMigrationAttempted"
    /// Flag: the old build had launch at login on and it is not yet back on. Set
    /// once, when the old log is first read; cleared only when the login item is
    /// confirmed on, so a crash or a failed registration retries on the next launch.
    public static let loginRestorePendingFlag = "uv.loginItemRestorePending"
    /// Preference: the clashes already written to the log, so each is logged once.
    public static let loggedConflictsKey = "uv.identityConflictsLogged"
    /// Preference: the move failures already written to the log, so each is logged once.
    public static let loggedFailuresKey = "uv.identityFailuresLogged"
    /// Preference: how many times copying the key failed (write or read-back).
    public static let keychainFailuresKey = "uv.keychainMigrationFailures"
    /// After this many failed copies the key is no longer retried.
    public static let maxKeychainRetries = 3

    /// The two phrases the launch record in `diagnostics.log` ends with. The app
    /// writes them; the migration reads the old build's last one to learn whether
    /// launch at login was on.
    ///
    /// Known limitation: the old build wrote "starts at login" for
    /// `.requiresApproval` too (registered, but switched off in System Settings),
    /// so that state is restored as on.
    public enum LaunchLine {
        public static let startsAtLogin = "starts at login"
        public static let manualStart = "manual start"
        static let category = "launch"
        /// Present in every launch line the NEW build writes and absent from the old
        /// build's, so a render or refused launch of the new build appending its own
        /// line to the old log can never be mistaken for the old build's last launch.
        public static let newBuildTag = "[ai.useful.voice]"

        /// The launch record's text, ending in the login phrase.
        public static func message(version: String, build: String, os: String,
                                   loginEnabled: Bool) -> String {
            "Useful Voice \(version) (\(build)) \(newBuildTag) on macOS \(os); "
                + (loginEnabled ? startsAtLogin : manualStart)
        }
    }

    /// Everything that differs between the real run and a test run.
    public struct Names: Equatable, Sendable {
        public var legacyDefaultsDomain: String
        public var newDefaultsDomain: String
        public var legacyKeychainService: String
        public var newKeychainService: String
        public var legacyFolderName: String
        public var newFolderName: String

        public init(legacyDefaultsDomain: String, newDefaultsDomain: String,
                    legacyKeychainService: String, newKeychainService: String,
                    legacyFolderName: String, newFolderName: String) {
            self.legacyDefaultsDomain = legacyDefaultsDomain
            self.newDefaultsDomain = newDefaultsDomain
            self.legacyKeychainService = legacyKeychainService
            self.newKeychainService = newKeychainService
            self.legacyFolderName = legacyFolderName
            self.newFolderName = newFolderName
        }

        public static let production = Names(
            legacyDefaultsDomain: Legacy.bundleID,
            newDefaultsDomain: "ai.useful.voice",
            legacyKeychainService: Legacy.keychainService,
            newKeychainService: Keychain.service,
            legacyFolderName: Legacy.dataFolderName,
            newFolderName: "UsefulVoice")

        /// Prefixes the defaults domains and Keychain services, so a test run
        /// never touches the real preferences or Keychain items. The folders are
        /// not prefixed: files follow `HOME`.
        public func prefixed(_ prefix: String) -> Names {
            Names(legacyDefaultsDomain: prefix + legacyDefaultsDomain,
                  newDefaultsDomain: prefix + newDefaultsDomain,
                  legacyKeychainService: prefix + legacyKeychainService,
                  newKeychainService: prefix + newKeychainService,
                  legacyFolderName: legacyFolderName,
                  newFolderName: newFolderName)
        }

        /// The prefix is honoured only together with `UV_MIGRATE_ONLY=1`.
        public static func forLaunch(environment: [String: String]) -> Names {
            guard LaunchMode.current(environment: environment) == .migrateOnly,
                  let prefix = environment[LaunchMode.testPrefixVariable], !prefix.isEmpty
            else { return .production }
            return Names.production.prefixed(prefix)
        }
    }

    /// What the file and preference steps did.
    public struct Report: Equatable, Sendable {
        /// Entries renamed into the new folder.
        public var moved: [String] = []
        /// Entries left in the old folder because the new folder has the name.
        public var conflicts: [String] = []
        /// Disposable entries (`.DS_Store`, `Icon\r`) dropped from the old folder
        /// because the new folder had its own.
        public var discarded: [String] = []
        /// Entries that could not be moved, with the reason.
        public var failed: [String] = []
        public var legacyFolderRemoved = false
        /// The old folder was a symbolic link and was renamed to the new name, so
        /// the data stays wherever the link points.
        public var legacyLinkRenamed = false
        /// Preference keys copied from the old domain.
        public var defaultsCopied = 0
        /// The preferences had already been copied by an earlier launch.
        public var defaultsAlreadyMigrated = false
        /// Whether the old build's last launch had launch at login on. `nil` when
        /// there is no old log, no launch line in it, or it was read before.
        public var legacyLaunchedAtLogin: Bool?

        public init() {}
    }

    public enum KeychainOutcome: String, Equatable, Sendable {
        /// Copied, verified and the old item deleted.
        case migrated
        /// Copied and verified, but the old item could not be deleted.
        case migratedLegacyRemains
        /// The new item already exists; the old one was not read.
        case alreadyPresent
        /// Neither item exists.
        case absent
        /// The user refused access to the old item; it is never asked again.
        case readDenied
        /// The old item's value is empty or not text; retrying cannot help, so it is
        /// not tried again.
        case unusableValue
        /// The old item could not be read for another reason (locked keychain,
        /// unreadable value); tried again next launch.
        case readFailed
        /// The old item was read but the new one could not be written; retried
        /// next launch.
        case writeFailed
        /// The new item did not read back as written; it was removed again and the
        /// migration is retried next launch.
        case verifyFailed
        /// The user refused access on an earlier launch; they are not asked again.
        case skippedAfterAttempt
    }

    let fileManager: FileManager
    let appSupport: URL
    let names: Names
    let readLegacyDefaults: @Sendable (String) -> [String: Any]?
    let defaults: UserDefaults
    let keychain: MigrationKeychain

    public init(
        fileManager: FileManager = .default,
        appSupport: URL,
        names: Names = .production,
        readLegacyDefaults: @escaping @Sendable (String) -> [String: Any]?,
        defaults: UserDefaults,
        keychain: MigrationKeychain
    ) {
        self.fileManager = fileManager
        self.appSupport = appSupport
        self.names = names
        self.readLegacyDefaults = readLegacyDefaults
        self.defaults = defaults
        self.keychain = keychain
    }

    /// The real thing: the real file system, preferences and Keychain. Under
    /// `UV_MIGRATE_ONLY` with a test prefix, the prefixed names and a prefixed
    /// preferences suite.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> IdentityMigration {
        let names = Names.forLaunch(environment: environment)
        let defaults: UserDefaults
        if names == .production {
            defaults = .standard
        } else {
            guard let suite = UserDefaults(suiteName: names.newDefaultsDomain) else {
                preconditionFailure("cannot open the defaults suite \(names.newDefaultsDomain)")
            }
            defaults = suite
        }
        return IdentityMigration(
            appSupport: DataFolder.appSupport,
            names: names,
            readLegacyDefaults: { UserDefaults.standard.persistentDomain(forName: $0) },
            defaults: defaults,
            keychain: SystemMigrationKeychain())
    }

    // MARK: - Files and preferences

    /// Moves the files, copies the preferences and reads the old launch-at-login
    /// state, then logs what happened. Runs before anything else touches the data
    /// folder or the preferences.
    ///
    /// - Parameter moveFiles: `false` skips the files AND the preferences, for a
    ///   launch where an older copy of the app is still running and may still be
    ///   writing to its own folder; the next launch does both.
    @discardableResult
    public func run(diagnostics: Diagnostics = .shared, moveFiles: Bool = true) -> Report {
        var report = Report()
        guard moveFiles else { return report }
        migrateFiles(into: &report)
        migrateDefaults(into: &report)
        log(report, to: diagnostics)
        return report
    }

    private var legacyFolder: URL {
        appSupport.appendingPathComponent(names.legacyFolderName, isDirectory: true)
    }

    private var newFolder: URL {
        appSupport.appendingPathComponent(names.newFolderName, isDirectory: true)
    }

    /// Exists, counting a dangling symlink (`attributesOfItem` does not follow it).
    private func present(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func migrateFiles(into report: inout Report) {
        let legacy = legacyFolder
        let new = newFolder
        // lstat semantics: a symlink reports as a symlink, not as its target.
        guard let attributes = try? fileManager.attributesOfItem(atPath: legacy.path) else { return }
        let kind = attributes[.type] as? FileAttributeType
        guard kind == .typeSymbolicLink || kind == .typeDirectory else { return }

        // Before anything moves (and before the link check), so neither a name clash
        // on the log nor a link can hide it. Reads through a link.
        readLoginSignal(into: &report)

        if kind == .typeSymbolicLink {
            // The user pointed the folder somewhere on purpose, maybe another
            // volume. Moving its contents would copy across volumes, so the LINK is
            // renamed instead, which keeps the data where the user put it. That is
            // impossible when the new folder already exists (a rename cannot land
            // on it): the link then stays, and the app keeps using it
            // (`DataFolder.resolve`).
            if present(new) {
                report.failed.append("\(names.legacyFolderName): is a symbolic link and \(names.newFolderName) already exists, left alone")
            } else {
                do {
                    try fileManager.moveItem(at: legacy, to: new)
                    report.legacyLinkRenamed = true
                } catch {
                    report.failed.append("\(names.legacyFolderName): \(error.localizedDescription)")
                }
            }
            return
        }

        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: legacy.path).sorted()
        } catch {
            report.failed.append("\(names.legacyFolderName): \(error.localizedDescription)")
            return
        }
        if !entries.isEmpty {
            do {
                try fileManager.createDirectory(at: new, withIntermediateDirectories: true)
            } catch {
                report.failed.append("\(names.newFolderName): \(error.localizedDescription)")
                return
            }
        }

        for name in entries {
            let source = legacy.appendingPathComponent(name)
            let destination = new.appendingPathComponent(name)
            if present(destination) {
                if Legacy.disposableNames.contains(name) {
                    // Finder litter: the new folder has its own, drop the old one
                    // so the old folder can empty out.
                    if (try? fileManager.removeItem(at: source)) != nil {
                        report.discarded.append(name)
                    } else {
                        report.conflicts.append(name)
                    }
                } else {
                    report.conflicts.append(name)
                }
                continue
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
                report.moved.append(name)
            } catch {
                // Another launch got there first: the entry is where it should be.
                if !present(source) && present(destination) { continue }
                report.failed.append("\(name): \(error.localizedDescription)")
            }
        }

        // rmdir, not removeItem: it refuses a folder that is not empty, so
        // nothing that appeared in the meantime can be deleted with it.
        if (try? fileManager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true,
           rmdir(legacy.path) == 0 {
            report.legacyFolderRemoved = true
        }
        // Only what arrived: the rest (`models/`, earlier files) was restricted
        // by whoever put it there, and walking it again every launch is wasted work.
        if !report.moved.isEmpty {
            FileProtection.restrict(new, isDirectory: true)
            for name in report.moved {
                FileProtection.restrictRecursively(new.appendingPathComponent(name))
            }
        }
    }

    /// The old build's last launch line says whether launch at login was on. Read
    /// once, on the first migration, and turned into a pending flag that stays set
    /// until the login item is confirmed on (`restoreLoginItemIfPending`).
    private func readLoginSignal(into report: inout Report) {
        guard !defaults.bool(forKey: Self.migratedFlag) else { return }
        let log = legacyFolder.appendingPathComponent("diagnostics.log")
        guard let text = Self.readTail(of: log),
              let signal = Self.launchedAtLogin(inDiagnosticsLog: text) else { return }
        report.legacyLaunchedAtLogin = signal
        if signal { defaults.set(true, forKey: Self.loginRestorePendingFlag) }
    }

    private func migrateDefaults(into report: inout Report) {
        if defaults.bool(forKey: Self.migratedFlag) {
            report.defaultsAlreadyMigrated = true
            return
        }
        // The domain itself, not `object(forKey:)`: a registered default or a
        // global-domain value must not stop a stored legacy setting being copied.
        let existing = defaults.persistentDomain(forName: names.newDefaultsDomain) ?? [:]
        if let legacy = readLegacyDefaults(names.legacyDefaultsDomain) {
            for (key, value) in legacy where existing[key] == nil {
                defaults.set(value, forKey: key)
                report.defaultsCopied += 1
            }
        }
        defaults.set(true, forKey: Self.migratedFlag)
    }

    /// For a render or a forced first run: apply the old preferences in memory so
    /// the screen shows what the user has set, and write nothing.
    public func registerLegacyDefaultsInMemory() {
        guard !defaults.bool(forKey: Self.migratedFlag),
              let legacy = readLegacyDefaults(names.legacyDefaultsDomain) else { return }
        defaults.register(defaults: legacy)
    }

    private func log(_ report: Report, to diagnostics: Diagnostics) {
        let from = names.legacyFolderName
        let to = names.newFolderName
        if !report.moved.isEmpty {
            diagnostics.info("identity-migration",
                             "moved \(report.moved.count) item(s) from the \(from) folder to \(to)")
        }
        // Each clash once: the same clash would otherwise repeat at every launch.
        let alreadyLogged = Set(defaults.stringArray(forKey: Self.loggedConflictsKey) ?? [])
        let fresh = report.conflicts.filter { !alreadyLogged.contains($0) }
        for name in fresh {
            diagnostics.warning("identity-migration",
                                "left \(name) in the \(from) folder: \(to) already has one")
        }
        if !fresh.isEmpty {
            defaults.set(alreadyLogged.union(fresh).sorted(), forKey: Self.loggedConflictsKey)
        }
        let failuresLogged = Set(defaults.stringArray(forKey: Self.loggedFailuresKey) ?? [])
        let freshFailures = report.failed.filter { !failuresLogged.contains($0) }
        for failure in freshFailures {
            diagnostics.error("identity-migration", "could not move \(failure)")
        }
        if !freshFailures.isEmpty {
            defaults.set(failuresLogged.union(freshFailures).sorted(), forKey: Self.loggedFailuresKey)
        }
        if report.legacyLinkRenamed {
            diagnostics.info("identity-migration",
                             "renamed the \(from) folder link to \(to); the data stays where the link points")
        }
        if report.defaultsCopied > 0 {
            diagnostics.info("identity-migration", "copied \(report.defaultsCopied) preference(s)")
        }
    }

    // MARK: - Launch at login

    /// Whether the last launch record in an old `diagnostics.log` says launch at
    /// login was on. `nil` when there is no launch record or it is unreadable:
    /// no signal rather than a guess.
    public static func launchedAtLogin(inDiagnosticsLog text: String) -> Bool? {
        let marker = "] \(LaunchLine.category): "
        for line in text.split(whereSeparator: \.isNewline).reversed()
        where line.contains(marker) && !line.contains(LaunchLine.newBuildTag) {
            if line.hasSuffix(LaunchLine.startsAtLogin) { return true }
            if line.hasSuffix(LaunchLine.manualStart) { return false }
            return nil
        }
        return nil
    }

    private static func readTail(of url: URL, maxBytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether the old build had launch at login on and it is not yet confirmed
    /// back on under the new identity.
    public var loginRestorePending: Bool { defaults.bool(forKey: Self.loginRestorePendingFlag) }

    /// Turns launch at login back on if the old build had it on. The pending flag
    /// is cleared only once the login item is confirmed on (or already was), so a
    /// failed registration is tried again next launch.
    ///
    /// - Returns: `nil` when nothing was pending, otherwise whether it is now on.
    @discardableResult
    public func restoreLoginItemIfPending(
        isEnabled: () -> Bool,
        enable: () throws -> Void,
        diagnostics: Diagnostics = .shared
    ) -> Bool? {
        guard loginRestorePending else { return nil }
        if isEnabled() {
            defaults.removeObject(forKey: Self.loginRestorePendingFlag)
            return true
        }
        do {
            try enable()
        } catch {
            diagnostics.failure("identity-migration", error,
                                context: "could not turn launch at login back on after the rename; will try again next launch")
            return false
        }
        guard isEnabled() else {
            diagnostics.warning("identity-migration",
                                "launch at login did not turn back on after the rename; will try again next launch")
            return false
        }
        defaults.removeObject(forKey: Self.loginRestorePendingFlag)
        diagnostics.info("identity-migration", "launch at login turned back on under the new app identity")
        return true
    }

    // MARK: - Keychain

    /// Whether a key is stored, without decrypting anything (so it never prompts).
    /// The old item counts only until the user has refused access to it: a refusal
    /// must send them to the key prompt, not pretend a key is set up.
    ///
    /// The old item is checked FIRST. A migration running at the same moment writes
    /// the new item before it deletes the old one, so checking in this order cannot
    /// see both missing mid-move.
    public func keyIsStored() -> Bool {
        let account = DeepgramKeyStore.account
        if !defaults.bool(forKey: Self.keychainAttemptedFlag),
           keychain.exists(service: names.legacyKeychainService, account: account) {
            return true
        }
        return keychain.exists(service: names.newKeychainService, account: account)
    }

    /// Deletes the old Keychain item. Tolerates refusal (it trusts the old app, so
    /// the delete may prompt or be refused): the failure is logged, and a refusal
    /// by the user is remembered so it is not asked again.
    ///
    /// - Parameter force: ignore that memory. For the user removing their key,
    ///   which must not leave a readable copy behind.
    /// - Returns: `true` when no old item is left.
    @discardableResult
    public func removeLegacyKey(force: Bool = false, diagnostics: Diagnostics = .shared) -> Bool {
        let account = DeepgramKeyStore.account
        let service = names.legacyKeychainService
        guard keychain.exists(service: service, account: account) else { return true }
        if !force && defaults.bool(forKey: Self.keychainAttemptedFlag) { return false }
        do {
            try keychain.delete(service: service, account: account)
            return true
        } catch {
            // A refusal is remembered so it is not asked again. A forced delete (the
            // user removed their key) is remembered whatever the reason: the leftover
            // must never count as a key or migrate back next launch.
            if force || Self.isUserDenial(error) { defaults.set(true, forKey: Self.keychainAttemptedFlag) }
            diagnostics.failure("identity-migration", error,
                                context: "the old Keychain item could not be deleted and was left in place")
            return false
        }
    }

    /// A failed copy is retried next launch, up to `maxKeychainRetries` times in total;
    /// then the old item is left alone and the app asks for a key.
    private func noteCopyFailure() {
        let failures = defaults.integer(forKey: Self.keychainFailuresKey) + 1
        defaults.set(failures, forKey: Self.keychainFailuresKey)
        if failures >= Self.maxKeychainRetries { defaults.set(true, forKey: Self.keychainAttemptedFlag) }
    }

    private static func isUserDenial(_ error: Error) -> Bool {
        if case KeychainError.unexpectedStatus(let status) = error {
            return Keychain.isUserDenial(status: status)
        }
        return false
    }

    /// Moves the key from the old service to the new one. Call it on
    /// `DeepgramKeyStore`'s queue (`migrateLegacyKey(with:)`), before its first read.
    public func migrateKeychain(diagnostics: Diagnostics = .shared) -> KeychainOutcome {
        let account = DeepgramKeyStore.account
        let legacyService = names.legacyKeychainService
        let newService = names.newKeychainService

        if keychain.exists(service: newService, account: account) {
            // Migrated earlier (or the user saved a key): retry removing any copy
            // an earlier launch could not delete. Never reads the old value.
            removeLegacyKey(diagnostics: diagnostics)
            return .alreadyPresent
        }
        if defaults.bool(forKey: Self.keychainAttemptedFlag) { return .skippedAfterAttempt }
        guard keychain.exists(service: legacyService, account: account) else { return .absent }

        // Reading the old item is the step that may show a Keychain prompt:
        // the item trusts the old app, not this one.
        let value: String
        let read = keychain.lookup(service: legacyService, account: account)
        switch read.result {
        case .absent:
            return .absent
        case .unavailable(let reason):
            if read.unusable {
                // The item was read; its value is empty or not text. Retrying cannot help.
                defaults.set(true, forKey: Self.keychainAttemptedFlag)
                diagnostics.warning("identity-migration",
                                    "the old Keychain item has no usable value (\(reason)); it was left in place and the app will ask for a key")
                return .unusableValue
            }
            if read.userDenied {
                // Remembered: the user said no, so they are not asked again.
                defaults.set(true, forKey: Self.keychainAttemptedFlag)
                diagnostics.warning("identity-migration",
                                    "access to the old Keychain item was refused (\(reason)); it was left in place and the app will ask for a key")
                return .readDenied
            }
            // A locked keychain at login, say: not a refusal, so not remembered.
            diagnostics.warning("identity-migration",
                                "could not read the old Keychain item (\(reason)); will try again next launch")
            return .readFailed
        case .found(let found):
            value = found
        }

        do {
            try keychain.write(value, service: newService, account: account)
        } catch {
            noteCopyFailure()
            diagnostics.failure("identity-migration", error,
                                context: "could not save the Deepgram key under the new Keychain service; the old item was left in place")
            return .writeFailed
        }

        guard keychain.lookup(service: newService, account: account).result == .found(value) else {
            try? keychain.delete(service: newService, account: account)
            noteCopyFailure()
            diagnostics.error("identity-migration",
                              "the copied Deepgram key did not read back as written; the copy was removed and the old item left in place")
            return .verifyFailed
        }

        do {
            try keychain.delete(service: legacyService, account: account)
        } catch {
            if Self.isUserDenial(error) { defaults.set(true, forKey: Self.keychainAttemptedFlag) }
            diagnostics.failure("identity-migration", error,
                                context: "the Deepgram key was copied but the old Keychain item could not be deleted")
            return .migratedLegacyRemains
        }
        diagnostics.info("identity-migration", "the Deepgram key was moved to the new Keychain service")
        return .migrated
    }
}

/// Finds, and asks to quit, copies of the previous app identity that are running.
/// The checks are injected so the logic is testable without AppKit.
public struct LegacyInstances {
    /// Process ids of running copies of the old bundle id.
    public var runningPIDs: () -> [Int32]
    /// Asks them to quit (a polite terminate, never a kill).
    public var requestQuit: () -> Void
    public var sleep: (TimeInterval) -> Void

    public init(runningPIDs: @escaping () -> [Int32],
                requestQuit: @escaping () -> Void,
                sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.runningPIDs = runningPIDs
        self.requestQuit = requestQuit
        self.sleep = sleep
    }

    public static let none = LegacyInstances(runningPIDs: { [] }, requestQuit: {})

    /// `found`: copies running at the start. `remaining`: still running after the
    /// bounded wait (`timeout` seconds in `poll` steps).
    public func clear(timeout: TimeInterval = 3, poll: TimeInterval = 0.1)
        -> (found: [Int32], remaining: [Int32]) {
        let found = runningPIDs()
        guard !found.isEmpty else { return ([], []) }
        requestQuit()
        var waited = 0.0
        var remaining = found
        while waited < timeout {
            sleep(poll)
            waited += poll
            remaining = runningPIDs()
            if remaining.isEmpty { break }
        }
        return (found, remaining)
    }
}

/// Runs the migration at process start, from `main.swift`.
public enum LaunchMigration {
    public struct Outcome: Equatable {
        /// What the migration did; `nil` when this launch must not (or could not) migrate.
        public var report: IdentityMigration.Report?
        /// Copies of the old app found running at launch.
        public var legacyFound: [Int32] = []
        /// Copies that did not quit in time. The migration was postponed.
        public var legacyStillRunning: [Int32] = []

        /// An old copy would not quit. The caller must show a message and exit
        /// before any store, hotkey tap or write: that copy still owns its folder.
        public var mustQuitForLegacyCopy: Bool { !legacyStillRunning.isEmpty }
    }

    /// Before anything touches the data folder, the preferences or the key store.
    ///
    /// - A normal launch first asks any running copy of the old app to quit. If
    ///   one is still running after a short wait, nothing is moved and the outcome
    ///   says so (`mustQuitForLegacyCopy`): that copy still owns its folder, so the
    ///   caller shows a message and exits rather than run beside it. Otherwise it
    ///   migrates files and preferences and returns the report.
    /// - A render or forced first run migrates nothing; it applies the old
    ///   preferences in memory so the screen shows the user's real settings.
    /// - Migrate-only returns no report here (`migrateOnlySummary` runs it).
    public static func runAtLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeMigration: ([String: String]) -> IdentityMigration = { IdentityMigration.live(environment: $0) },
        legacyInstances: LegacyInstances = .none
    ) -> Outcome {
        switch LaunchMode.current(environment: environment) {
        case .normal:
            let (found, remaining) = legacyInstances.clear()
            let migration = makeMigration(environment)
            if !remaining.isEmpty {
                // Nothing is moved, copied or applied: the caller exits.
                return Outcome(report: nil, legacyFound: found, legacyStillRunning: remaining)
            }
            return Outcome(report: migration.run(), legacyFound: found, legacyStillRunning: [])
        case .preview:
            makeMigration(environment).registerLegacyDefaultsInMemory()
            return Outcome(report: nil)
        case .migrateOnly:
            return Outcome(report: nil)
        }
    }

    /// `UV_MIGRATION_TEST_SEED_KEY=<dummy>` (migrate-only with a test prefix only)
    /// stores a dummy key under the PREFIXED old service, so a check has an item
    /// this process created and can read without a Keychain prompt. It never
    /// touches the real service.
    private static func seedTestKey(environment: [String: String], names: IdentityMigration.Names) {
        guard names != .production,
              let dummy = environment["UV_MIGRATION_TEST_SEED_KEY"], !dummy.isEmpty else { return }
        do {
            try Keychain.set(dummy, account: DeepgramKeyStore.account, service: names.legacyKeychainService)
        } catch {
            FileHandle.standardError.write(Data("could not seed the test key: \(error)\n".utf8))
        }
    }

    /// `UV_MIGRATE_ONLY=1`: runs every step, including the Keychain step on the key
    /// store's queue, and returns a one-line JSON summary. Never contains the key.
    public static func migrateOnlySummary(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let migration = IdentityMigration.live(environment: environment)
        seedTestKey(environment: environment, names: migration.names)
        let report = migration.run()
        let keychain = DeepgramKeyStore.shared.migrateLegacyKey(with: migration)
        migration.defaults.synchronize()
        // The log lines are written on a background queue; exit() would drop them.
        Diagnostics.shared.flush()

        let signal: String
        switch report.legacyLaunchedAtLogin {
        case true?: signal = "on"
        case false?: signal = "off"
        case nil: signal = "none"
        }
        var summary: [String: Any] = [
            "moved": report.moved,
            "conflicts": report.conflicts,
            "discarded": report.discarded,
            "failed": report.failed,
            "legacyFolderRemoved": report.legacyFolderRemoved,
            "legacyLinkRenamed": report.legacyLinkRenamed,
            "defaultsCopied": report.defaultsCopied,
            "defaultsAlreadyMigrated": report.defaultsAlreadyMigrated,
            "keychain": keychain.rawValue,
            "loginItemSignal": signal,
        ]
        // `UV_MIGRATION_TEST_EXPECT_KEY=<dummy>` (test prefix only): says whether the
        // new item holds that dummy, as a boolean. The value itself is never printed.
        if migration.names != .production,
           let expected = environment["UV_MIGRATION_TEST_EXPECT_KEY"], !expected.isEmpty {
            summary["newKeyMatches"] = Keychain.lookup(
                account: DeepgramKeyStore.account, service: migration.names.newKeychainService)
                == .found(expected)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"could not encode the summary\"}"
        }
        return line
    }
}
