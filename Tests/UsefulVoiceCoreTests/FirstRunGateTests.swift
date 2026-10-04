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
