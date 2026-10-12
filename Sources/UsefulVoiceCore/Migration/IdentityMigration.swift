import Foundation

/// Keychain operations the identity migration needs, by service. The app uses
/// the real Keychain; tests inject an in-memory fake.
public protocol MigrationKeychain: Sendable {
    /// Attributes only: must never decrypt, so it never prompts.
    func exists(service: String, account: String) -> Bool
    func lookup(service: String, account: String) -> Keychain.Lookup
    func write(_ value: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public struct SystemMigrationKeychain: MigrationKeychain {
    public init() {}

    public func exists(service: String, account: String) -> Bool {
        Keychain.exists(account: account, service: service)
    }

    public func lookup(service: String, account: String) -> Keychain.Lookup {
        Keychain.lookup(account: account, service: service)
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
///    only then deleted from the old one. A read that fails or is denied deletes
///    nothing and is never retried, so the user is asked for at most one prompt.
///
/// This type is the only place the previous identity's names live.
public struct IdentityMigration {
    /// The previous identity. Nothing else in the app may name these.
    public enum Legacy {
        public static let bundleID = "ai.karko.sadaa"
        public static let dataFolderName = "Sadaa"
        public static let keychainService = "ai.karko.sadaa"
    }

    /// `UserDefaults` flag in the new domain: the preferences were copied.
    public static let migratedFlag = "uv.identityMigrated"
    /// Flag: the old Keychain item was tried and failed, so it is not tried again.
    public static let keychainAttemptedFlag = "uv.keychainMigrationAttempted"
    /// Flag: the old build's launch-at-login state was read.
    public static let loginSignalReadFlag = "uv.loginItemSignalRead"

    /// The two phrases the launch record in `diagnostics.log` ends with. The app
    /// writes them; the migration reads the old build's last one to learn whether
    /// launch at login was on.
    public enum LaunchLine {
        public static let startsAtLogin = "starts at login"
        public static let manualStart = "manual start"
        static let category = "launch"
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
        /// Entries that could not be moved, with the reason.
        public var failed: [String] = []
        public var legacyFolderRemoved = false
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
        /// The old item could not be read (denied, locked, unreadable).
        case readDenied
        /// The old item was read but the new one could not be written.
        case writeFailed
        /// The new item did not read back as written; it was removed again.
        case verifyFailed
        /// An earlier launch already failed; the user is not asked again.
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
    @discardableResult
    public func run(diagnostics: Diagnostics = .shared) -> Report {
        var report = Report()
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
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        // Before anything moves, so a name clash on the log cannot hide it.
        readLoginSignal(into: &report)

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
                report.conflicts.append(name)
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
        if present(new) { FileProtection.restrictRecursively(new) }
    }

    private func readLoginSignal(into report: inout Report) {
        guard !defaults.bool(forKey: Self.loginSignalReadFlag) else { return }
        let log = legacyFolder.appendingPathComponent("diagnostics.log")
        guard let text = Self.readTail(of: log),
              let signal = Self.launchedAtLogin(inDiagnosticsLog: text) else { return }
        report.legacyLaunchedAtLogin = signal
        defaults.set(true, forKey: Self.loginSignalReadFlag)
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
        for name in report.conflicts {
            diagnostics.warning("identity-migration",
                                "left \(name) in the \(from) folder: \(to) already has one")
        }
        for failure in report.failed {
            diagnostics.error("identity-migration", "could not move \(failure)")
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
        for line in text.split(whereSeparator: \.isNewline).reversed() where line.contains(marker) {
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

    // MARK: - Keychain

    /// Whether a key is stored, without decrypting anything (so it never prompts).
    /// The old item counts only until the migration has failed once: a denied
    /// read must send the user to the key prompt, not pretend a key is set up.
    public func keyIsStored() -> Bool {
        let account = DeepgramKeyStore.account
        if keychain.exists(service: names.newKeychainService, account: account) { return true }
        if defaults.bool(forKey: Self.keychainAttemptedFlag) { return false }
        return keychain.exists(service: names.legacyKeychainService, account: account)
    }

    /// Moves the key from the old service to the new one. Call it on
    /// `DeepgramKeyStore`'s queue (`migrateLegacyKey(with:)`), before its first read.
    public func migrateKeychain(diagnostics: Diagnostics = .shared) -> KeychainOutcome {
        let account = DeepgramKeyStore.account
        let legacyService = names.legacyKeychainService
        let newService = names.newKeychainService

        if keychain.exists(service: newService, account: account) { return .alreadyPresent }
        if defaults.bool(forKey: Self.keychainAttemptedFlag) { return .skippedAfterAttempt }
        guard keychain.exists(service: legacyService, account: account) else { return .absent }

        // Reading the old item is the one step that may show a Keychain prompt:
        // the item trusts the old app, not this one.
        let value: String
        switch keychain.lookup(service: legacyService, account: account) {
        case .absent:
            return .absent
        case .unavailable(let reason):
            defaults.set(true, forKey: Self.keychainAttemptedFlag)
            diagnostics.warning("identity-migration",
                                "could not read the Deepgram key from the old Keychain item (\(reason)); it was left in place and the app will ask for a key")
            return .readDenied
        case .found(let found):
            value = found
        }

        do {
            try keychain.write(value, service: newService, account: account)
        } catch {
            defaults.set(true, forKey: Self.keychainAttemptedFlag)
            diagnostics.failure("identity-migration", error,
                                context: "could not save the Deepgram key under the new Keychain service; the old item was left in place")
            return .writeFailed
        }

        guard keychain.lookup(service: newService, account: account) == .found(value) else {
            try? keychain.delete(service: newService, account: account)
            defaults.set(true, forKey: Self.keychainAttemptedFlag)
            diagnostics.error("identity-migration",
                              "the copied Deepgram key did not read back as written; the copy was removed and the old item left in place")
            return .verifyFailed
        }

        do {
            try keychain.delete(service: legacyService, account: account)
        } catch {
            diagnostics.failure("identity-migration", error,
                                context: "the Deepgram key was copied but the old Keychain item could not be deleted")
            return .migratedLegacyRemains
        }
        diagnostics.info("identity-migration", "the Deepgram key was moved to the new Keychain service")
        return .migrated
    }
}

/// Runs the migration at process start, from `main.swift`.
public enum LaunchMigration {
    /// Before anything touches the data folder, the preferences or the key store.
    ///
    /// - A normal launch migrates files and preferences and returns the report.
    /// - A render or forced first run migrates nothing; it applies the old
    ///   preferences in memory so the screen shows the user's real settings.
    /// - Migrate-only returns `nil` here (`migrateOnlySummary` runs it).
    public static func runAtLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> IdentityMigration.Report? {
        let migration = IdentityMigration.live(environment: environment)
        switch LaunchMode.current(environment: environment) {
        case .normal:
            return migration.run()
        case .preview:
            migration.registerLegacyDefaultsInMemory()
            return nil
        case .migrateOnly:
            return nil
        }
    }

    /// `UV_MIGRATE_ONLY=1`: runs every step, including the Keychain one on the key
    /// store's queue, and returns a one-line JSON summary. Never contains the key.
    public static func migrateOnlySummary(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let migration = IdentityMigration.live(environment: environment)
        let report = migration.run()
        let keychain = DeepgramKeyStore.shared.migrateLegacyKey(with: migration)
        migration.defaults.synchronize()

        let signal: String
        switch report.legacyLaunchedAtLogin {
        case true?: signal = "on"
        case false?: signal = "off"
        case nil: signal = "none"
        }
        let summary: [String: Any] = [
            "moved": report.moved,
            "conflicts": report.conflicts,
            "failed": report.failed,
            "legacyFolderRemoved": report.legacyFolderRemoved,
            "defaultsCopied": report.defaultsCopied,
            "defaultsAlreadyMigrated": report.defaultsAlreadyMigrated,
            "keychain": keychain.rawValue,
            "loginItemSignal": signal,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"could not encode the summary\"}"
        }
        return line
    }
}
