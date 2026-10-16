import Foundation

/// The numbers and gates that decide whether the local cleanup model runs.
/// `windows/src/core/formatting/cleanupModelPolicy.ts` mirrors this file rule for rule.
public enum CleanupModelPolicy {
    /// How long the pipeline waits for the model before it uses the rules-only text.
    public static let defaultDeadline: Duration = .milliseconds(1500)

    /// How long the model stays loaded after the last dictation. Configurable by passing
    /// another value to `LocalCleanupModel`.
    public static let defaultIdleUnload: Duration = .seconds(60)

    /// AI cleanup stays off below 8 GB of RAM. The check is "at least 7 GiB reported": Windows'
    /// total memory leaves out hardware-reserved memory, so 8 GB PCs report 7.0 to 7.9 GiB,
    /// and an 8 GB Mac reports 8 GiB. A 6 GB machine reports under 6 GiB and stays off.
    public static let minimumMemoryBytes: UInt64 = 7 * 1_073_741_824

    public static func memoryAllowsModel(physicalMemoryBytes: UInt64) -> Bool {
        physicalMemoryBytes >= minimumMemoryBytes
    }

    public enum SkipReason: String, Equatable, Sendable, CaseIterable {
        case flagOff, modelNotDownloaded, notEnoughMemory, notEnglish, noModel
    }

    public enum Decision: Equatable, Sendable {
        case run
        case skip(SkipReason)
    }

    /// Whether the model step runs. Checked in this order, so the reason reported is the first
    /// one that applies. The model is English only, like the rules.
    public static func decide(
        flagOn: Bool, modelInstalled: Bool, physicalMemoryBytes: UInt64, language: String?
    ) -> Decision {
        if !flagOn { return .skip(.flagOff) }
        if !modelInstalled { return .skip(.modelNotDownloaded) }
        if !memoryAllowsModel(physicalMemoryBytes: physicalMemoryBytes) { return .skip(.notEnoughMemory) }
        guard let code = language?.lowercased(), code == "en" || code.hasPrefix("en-") else {
            return .skip(.notEnglish)
        }
        return .run
    }
}

/// The hidden flag. There is no visible control in this phase: it is read once at launch
/// from the `UV_CLEANUP_MODEL` environment variable or the `uvCleanupModel` defaults key
/// (`defaults write ai.useful.voice uvCleanupModel -bool YES`), and it is off by default.
public enum CleanupModelFlag {
    public static let environmentKey = "UV_CLEANUP_MODEL"
    public static let defaultsKey = "uvCleanupModel"

    public static func resolve(environment: [String: String], defaults: UserDefaults?) -> Bool {
        if let raw = environment[environmentKey] {
            return isTruthy(raw)
        }
        return defaults?.bool(forKey: defaultsKey) ?? false
    }

    /// The value at first use, which is launch. Changing the variable later changes nothing.
    public static let isOn: Bool = resolve(
        environment: ProcessInfo.processInfo.environment, defaults: .standard)

    private static func isTruthy(_ raw: String) -> Bool {
        ["1", "true", "yes", "on"].contains(raw.trimmingCharacters(in: .whitespaces).lowercased())
    }
}
