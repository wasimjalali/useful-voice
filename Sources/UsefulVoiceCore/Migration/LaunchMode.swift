import Foundation

/// What kind of launch this is, from the environment alone.
///
/// The distinction exists for one reason: a render (`UV_SNAPSHOT`) or a forced
/// first run (`UV_FIRST_RUN=force`) is a look at the app, not a use of it, so
/// neither may migrate or write the user's data. `UV_MIGRATE_ONLY=1` is the
/// opposite, a test hook that runs the identity migration and exits.
public enum LaunchMode: Equatable, Sendable {
    /// A real launch: the identity migration runs.
    case normal
    /// A render or a forced first run: nothing is migrated or written.
    case preview
    /// `UV_MIGRATE_ONLY=1`: run the migration, print a summary, exit.
    case migrateOnly

    public static let migrateOnlyVariable = "UV_MIGRATE_ONLY"
    public static let testPrefixVariable = "UV_MIGRATION_TEST_PREFIX"
    public static let snapshotVariable = "UV_SNAPSHOT"

    /// A preview wins over migrate-only: a render must never migrate, whatever
    /// else is set.
    public static func current(environment: [String: String]) -> LaunchMode {
        if isPreview(environment: environment) { return .preview }
        if environment[migrateOnlyVariable] == "1" { return .migrateOnly }
        return .normal
    }

    /// A real launch that is allowed to migrate and to write preferences (and to
    /// add its launch line to the log).
    public static func migrationAllowed(environment: [String: String]) -> Bool {
        current(environment: environment) == .normal
    }

    /// Why migrate-only must not start, or `nil` when it may.
    ///
    /// The hook moves real files and consumes the real login-at-login signal, so it
    /// is refused unless `CFFIXED_USER_HOME` points somewhere other than the real
    /// home. It also needs a non-empty test prefix: without one its Keychain and
    /// preferences steps would run on the production names. (The prefix covers
    /// preferences and the Keychain only; files follow the home directory.)
    public static func migrateOnlyRefusal(
        environment: [String: String],
        realHome: String = realHomeDirectory
    ) -> String? {
        guard environment[migrateOnlyVariable] == "1" else { return nil }
        if migrateOnlyConflictsWithPreview(environment: environment) {
            return "UV_MIGRATE_ONLY cannot be combined with UV_SNAPSHOT or UV_FIRST_RUN=force"
        }
        guard let prefix = environment[testPrefixVariable], !prefix.isEmpty else {
            return "UV_MIGRATE_ONLY needs a non-empty UV_MIGRATION_TEST_PREFIX: it must never touch the real Keychain or preferences"
        }
        guard let fixed = environment["CFFIXED_USER_HOME"], !fixed.isEmpty else {
            return "UV_MIGRATE_ONLY moves real files: set CFFIXED_USER_HOME to a scratch home first"
        }
        func normal(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        }
        if normal(fixed) == normal(realHome) {
            return "UV_MIGRATE_ONLY moves real files: CFFIXED_USER_HOME is the real home, use a scratch home"
        }
        return nil
    }

    /// The account's home from the user database, which `HOME` and
    /// `CFFIXED_USER_HOME` cannot change.
    public static var realHomeDirectory: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// Both a render and migrate-only were asked for. The caller refuses to
    /// start rather than silently ignoring one of them.
    public static func migrateOnlyConflictsWithPreview(environment: [String: String]) -> Bool {
        environment[migrateOnlyVariable] == "1" && isPreview(environment: environment)
    }

    private static func isPreview(environment: [String: String]) -> Bool {
        environment[snapshotVariable] != nil || FirstRunGate.isForced(environment: environment)
    }
}

/// Where the app keeps its data files.
public enum DataFolder {
    /// `~/Library/Application Support`.
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// The data folder for this process.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        resolve(appSupport: appSupport,
                preview: LaunchMode.current(environment: environment) == .preview)
    }

    /// The previous identity's recordings folder, where history written by the old
    /// build still points.
    public static var legacyRecordingsDirectory: URL {
        appSupport
            .appendingPathComponent(IdentityMigration.Names.production.legacyFolderName, isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// The new folder, except:
    ///  * in a preview run that finds the previous identity's folder still holding
    ///    data the new one lacks: a render before the first real launch must show
    ///    the user's data exactly as the old build did;
    ///  * when the old folder is a symbolic link the migration could not rename
    ///    (the new folder was already taken), even a dangling one: the app keeps
    ///    using the link, so the user never sees an empty app and no data is
    ///    stranded in the new folder.
    /// Reads only; creates and changes nothing.
    public static func resolve(
        appSupport: URL,
        fileManager: FileManager = .default,
        preview: Bool,
        names: IdentityMigration.Names = .production
    ) -> URL {
        let new = appSupport.appendingPathComponent(names.newFolderName, isDirectory: true)
        let legacy = appSupport.appendingPathComponent(names.legacyFolderName, isDirectory: true)
        guard preview else { return isSymbolicLink(legacy, fileManager: fileManager) ? legacy : new }
        return holdsUnmigratedData(legacy: legacy, new: new, fileManager: fileManager) ? legacy : new
    }

    /// Any symbolic link at `url`, dangling or not (lstat, never following it): an
    /// unmounted target must not send new data to the new folder.
    static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            == .typeSymbolicLink
    }

    /// True while the old folder has at least one entry the new folder does not.
    /// An entry that exists in both is a clash the migration deliberately left
    /// behind, and the new folder is the truth for it.
    static func holdsUnmigratedData(legacy: URL, new: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacy.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let entries = try? fileManager.contentsOfDirectory(atPath: legacy.path)
        else { return false }
        return entries.contains { name in
            (try? fileManager.attributesOfItem(atPath: new.appendingPathComponent(name).path)) == nil
        }
    }
}
