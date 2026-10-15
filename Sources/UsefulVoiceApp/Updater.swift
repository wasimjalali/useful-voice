import AppKit
import Sparkle

/// In-app updates through Sparkle. Only a release build carries `SUFeedURL` and
/// `SUPublicEDKey` (scripts/release-mac.mjs passes them to `make bundle`), so a
/// local `make bundle` never offers to replace itself with a published release.
///
/// A scheduled check never opens Sparkle's window on its own: it would take focus
/// from the app the user is dictating into, and Return would press its default
/// button. The menu bar offers the update instead, and Sparkle's window opens
/// only when the user picks it.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?

    /// The version a check found and the user has not installed or skipped yet.
    private(set) var pendingVersion: String?

    /// False in a local build, which has no feed: the menu hides the update item.
    var isAvailable: Bool { controller != nil }

    /// Starts Sparkle's scheduled checks. Called once at launch, after the
    /// single-instance check, so a copy that yields never starts an updater.
    func start() {
        guard controller == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        guard !feed.isEmpty, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    /// The menu's item: shows a found update, or checks for one.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.pendingVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.pendingVersion = nil }
    }

    /// Skip This Version ends the offer; Remind Me Later keeps it.
    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard choice == .skip else { return }
        Task { @MainActor in self.pendingVersion = nil }
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// Gentle reminders: Sparkle leaves a scheduled update to the menu.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Never, not even right after launch: a login launch must not take focus.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }
}
