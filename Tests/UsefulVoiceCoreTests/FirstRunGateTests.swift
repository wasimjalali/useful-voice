import Foundation
import Testing
@testable import UsefulVoiceCore

/// The decision rules behind the first-run flow. The failure these guard against
/// is an existing user, fully set up, being walked through setup again after an
/// update, or a new user never seeing it.
@Suite("First-run gate")
struct FirstRunGateTests {
    private func decide(completed: Bool = false, engine: Bool = false, mic: Bool = false,
                        ax: Bool = false, forced: Bool = false) -> FirstRunGate.Decision {
        FirstRunGate.decide(completed: completed, engineConfigured: engine,
                            microphoneAuthorized: mic, accessibilityTrusted: ax,
                            forced: forced)
    }

    @Test func freshInstallShowsFromWelcome() {
        #expect(decide() == .show)
    }

    @Test func completedAndNotForcedNeverShows() {
        #expect(decide(completed: true) == .skip)
        #expect(decide(completed: true, engine: true, mic: true, ax: true) == .skip)
    }

    /// A completed user who later revokes a permission is not sent back through
    /// setup: the app's own status line already says what is missing.
    @Test func completedWithRevokedPermissionStillSkips() {
        #expect(decide(completed: true, engine: true, mic: false, ax: false) == .skip)
    }

    // MARK: After the identity rename (WAS-30, UV-003)
    //
    // The renamed app has a new bundle id, so macOS has no Accessibility or
    // Microphone grant for it. The migration copies "setup finished" from the
    // old identity and sets the recheck flag; the gate then treats the install
    // as unfinished until the grants are back.

    private func decideAfterRename(engine: Bool = true, mic: Bool = false, ax: Bool = false,
                                   forced: Bool = false) -> FirstRunGate.Decision {
        FirstRunGate.decide(completed: true, engineConfigured: engine,
                            microphoneAuthorized: mic, accessibilityTrusted: ax,
                            forced: forced, grantsNeedRecheck: true)
    }

    @Test func renamedInstallWithNoGrantsShowsTheFlow() {
        #expect(decideAfterRename() == .show)
    }

    @Test func renamedInstallMissingOnlyOneGrantShowsTheFlow() {
        #expect(decideAfterRename(mic: true, ax: false) == .show)
        #expect(decideAfterRename(mic: false, ax: true) == .show)
    }

    @Test func renamedInstallWithoutAnEngineShowsTheFlowEvenWithGrants() {
        #expect(decideAfterRename(engine: false, mic: true, ax: true) == .show)
    }

    /// Both grants came back by hand before the flow was ever seen: it stays out
    /// of the way and the install is marked done, which also clears the recheck.
    @Test func renamedInstallWithEverythingBackIsMarkedDoneSilently() {
        #expect(decideAfterRename(mic: true, ax: true) == .skipAndMarkCompleted)
    }

    @Test func theRecheckNeverHidesAForcedRun() {
        #expect(decideAfterRename(mic: true, ax: true, forced: true) == .show)
    }

    /// Without the recheck flag a completed install is left alone, grants or not.
    @Test func withoutTheRecheckACompletedInstallStillSkips() {
        #expect(FirstRunGate.decide(completed: true, engineConfigured: true,
                                    microphoneAuthorized: false, accessibilityTrusted: false,
                                    forced: false, grantsNeedRecheck: false) == .skip)
    }

    @Test func recheckFlagLivesUnderTheDocumentedKey() {
        #expect(FirstRunGate.recheckGrantsKey == "uv.firstRunRecheckGrants")
    }

    /// Done, Finish, "Set up later" and a silent mark all go through this. If the
    /// recheck survived it, the flow would come back on the next launch.
    @Test func completingSetupClearsTheRecheck() {
        let suite = "first-run-gate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: FirstRunGate.recheckGrantsKey)

        FirstRunGate.recordCompleted(in: defaults)

        #expect(defaults.bool(forKey: FirstRunGate.completedKey))
        #expect(defaults.object(forKey: FirstRunGate.recheckGrantsKey) == nil)
        // The next launch, grants still missing: a normal launch, no flow.
        #expect(FirstRunGate.decide(
            completed: defaults.bool(forKey: FirstRunGate.completedKey),
            engineConfigured: true, microphoneAuthorized: false, accessibilityTrusted: false,
            forced: false, grantsNeedRecheck: defaults.bool(forKey: FirstRunGate.recheckGrantsKey)) == .skip)
    }

    // MARK: Opening the window at launch

    @Test func onlyAFinishedSetupWithTheRecheckIsRecheckOnly() {
        #expect(FirstRunGate.isRecheckOnly(completed: true, grantsNeedRecheck: true, forced: false))
        #expect(!FirstRunGate.isRecheckOnly(completed: false, grantsNeedRecheck: true, forced: false))
        #expect(!FirstRunGate.isRecheckOnly(completed: true, grantsNeedRecheck: false, forced: false))
        #expect(!FirstRunGate.isRecheckOnly(completed: true, grantsNeedRecheck: true, forced: true))
    }

    /// A migrated user who never re-grants must not get a window in front of their
    /// work at every login. The flow stays up for the next time they open the window.
    @Test func aLoginLaunchLeavesTheWindowClosedForTheRecheck() {
        #expect(!FirstRunGate.opensWindowAtLaunch(flowActive: true, recheckOnly: true,
                                                  userInitiated: false))
    }

    @Test func aLoginLaunchStillOpensTheWindowForASetupNeverFinished() {
        #expect(FirstRunGate.opensWindowAtLaunch(flowActive: true, recheckOnly: false,
                                                 userInitiated: false))
    }

    @Test func aLoginLaunchWithNoFlowStaysInTheMenuBar() {
        #expect(!FirstRunGate.opensWindowAtLaunch(flowActive: false, recheckOnly: false,
                                                  userInitiated: false))
    }

    @Test func aLaunchTheUserAskedForAlwaysOpensTheWindow() {
        for active in [true, false] {
            for recheck in [true, false] {
                #expect(FirstRunGate.opensWindowAtLaunch(flowActive: active, recheckOnly: recheck,
                                                         userInitiated: true))
            }
        }
    }

    // MARK: Who asks for the permissions at launch

    /// The recheck at login keeps the window closed, so nothing on screen asks for
    /// Accessibility: the app must ask and show the pill.
    @Test func aRecheckKeptBehindAClosedWindowIsNotOnScreen() {
        #expect(!FirstRunGate.flowOnScreenAtLaunch(flowActive: true, recheckOnly: true,
                                                   userInitiated: false))
    }

    @Test func aRecheckTheUserOpenedIsOnScreen() {
        #expect(FirstRunGate.flowOnScreenAtLaunch(flowActive: true, recheckOnly: true,
                                                  userInitiated: true))
    }

    @Test func aSetupNeverFinishedIsOnScreenEvenAtLogin() {
        #expect(FirstRunGate.flowOnScreenAtLaunch(flowActive: true, recheckOnly: false,
                                                  userInitiated: false))
        #expect(FirstRunGate.flowOnScreenAtLaunch(flowActive: true, recheckOnly: false,
                                                  userInitiated: true))
    }

    /// The window opening for an ordinary launch does not mean a flow is showing.
    @Test func noFlowIsNeverOnScreen() {
        for recheck in [true, false] {
            for user in [true, false] {
                #expect(!FirstRunGate.flowOnScreenAtLaunch(flowActive: false, recheckOnly: recheck,
                                                           userInitiated: user))
            }
        }
    }

    @Test func completingSetupWithoutARecheckOnlyMarksItDone() {
        let suite = "first-run-gate-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        FirstRunGate.recordCompleted(in: defaults)

        #expect(defaults.bool(forKey: FirstRunGate.completedKey))
        #expect(defaults.object(forKey: FirstRunGate.recheckGrantsKey) == nil)
    }

    @Test func upgradingUserWhoIsFullyConfiguredIsMarkedDoneSilently() {
        #expect(decide(engine: true, mic: true, ax: true) == .skipAndMarkCompleted)
    }

    @Test func eachMissingPieceKeepsTheFlowOnScreen() {
        #expect(decide(engine: false, mic: true, ax: true) == .show)
        #expect(decide(engine: true, mic: false, ax: true) == .show)
        #expect(decide(engine: true, mic: true, ax: false) == .show)
    }

    @Test func forcedAlwaysShowsAndNeverMarksCompleted() {
        #expect(decide(forced: true) == .show)
        #expect(decide(completed: true, engine: true, mic: true, ax: true, forced: true) == .show)
        #expect(decide(engine: true, mic: true, ax: true, forced: true) == .show)
    }

    @Test func forceFlagReadsOnlyTheWordForce() {
        #expect(FirstRunGate.isForced(environment: ["UV_FIRST_RUN": "force"]))
        #expect(!FirstRunGate.isForced(environment: ["UV_FIRST_RUN": "1"]))
        #expect(!FirstRunGate.isForced(environment: [:]))
    }

    @Test func completedFlagLivesUnderTheDocumentedKey() {
        #expect(FirstRunGate.completedKey == "uv.firstRunCompleted")
    }

    /// Presence of a key or a usable model is enough, with no cache involved.
    @Test func engineConfiguredFromKeyPresenceOrUsableModel() {
        #expect(FirstRunGate.engineConfigured(keyStored: true, localModelUsable: false))
        #expect(FirstRunGate.engineConfigured(keyStored: false, localModelUsable: true))
        #expect(!FirstRunGate.engineConfigured(keyStored: false, localModelUsable: false))
    }

    /// The local engine is set, its active model is not usable, another model is
    /// downloaded, there is no key and the permissions are granted: dictation
    /// would fail, so the flow shows. Another downloaded model is not an input.
    @Test func unusableActiveModelWithAnotherDownloadedModelStillShows() {
        let configured = FirstRunGate.engineConfigured(
            engine: .whisperLocal, keyStored: false, activeModelUsable: false)
        #expect(!configured)
        #expect(decide(engine: configured, mic: true, ax: true) == .show)
        #expect(FirstRunGate.engineConfigured(
            engine: .whisperLocal, keyStored: false, activeModelUsable: true))
        #expect(FirstRunGate.engineConfigured(
            engine: .deepgram, keyStored: true, activeModelUsable: false))
        #expect(!FirstRunGate.engineConfigured(
            engine: .deepgram, keyStored: false, activeModelUsable: true))
    }

    private typealias Selection = FirstRunGate.EngineSelection
    private let before = Selection(engine: .deepgram, modelID: "turbo")
    private let after = Selection(engine: .whisperLocal, modelID: "large")

    /// Abandoning with a model that never became usable puts the app back.
    @Test func abandonedUnusableChoiceRestoresTheSnapshot() {
        #expect(FirstRunGate.selectionAfterAbandon(
            snapshot: before, current: after, currentUsable: false) == before)
    }

    /// A choice that can already dictate is kept.
    @Test func abandonedUsableChoiceIsKept() {
        #expect(FirstRunGate.selectionAfterAbandon(
            snapshot: before, current: after, currentUsable: true) == after)
    }
}
