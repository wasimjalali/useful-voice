import AppKit
import Sparkle

/// In-app updates through Sparkle. Only a release build carries `SUFeedURL` and
/// `SUPublicEDKey` (scripts/release-mac.mjs passes them to `make bundle`), so a
/// local `make bundle` never offers to replace itself with a published release.
@MainActor
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?

    /// False in a local build, which has no feed: the menu hides Check for Updates.
    var isAvailable: Bool { controller != nil }

    /// Starts Sparkle's scheduled checks. Called once at launch, after the
    /// single-instance check, so a copy that yields never starts an updater.
    func start() {
        guard controller == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = info["SUFeedURL"] as? String ?? ""
        let key = info["SUPublicEDKey"] as? String ?? ""
        guard !feed.isEmpty, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
