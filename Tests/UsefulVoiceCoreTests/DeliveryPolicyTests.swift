import Testing
@testable import UsefulVoiceCore

/// Guards the clipboard-loss fix: delivery may restore the user's clipboard ONLY
/// when the text is proven to have landed (the focused element grew, or a direct
/// AX insert grew it). Every uncertain path must keep the dictation on the
/// clipboard so a missed insert is always pasteable.
@Suite struct DeliveryPolicyTests {
    // MARK: - The regression that caused the bug

    @Test func testAXBlindPostedPasteKeepsDictationAndDoesNotRestore() {
        // Electron/web/terminal: the paste was posted and almost certainly
        // landed, but we can't prove it. The old code would have restored the
        // user's clipboard here on a third-party pasteboard read and wiped the
        // dictation. The decision must NOT restore.
        let decision = DeliveryPolicy.finalDecision(
            pastePosted: true, axVisible: false, axInsertGrew: false)
        #expect(decision == .keepDictationPasted)
        #expect(decision.restoresUserClipboard == false)
        #expect(decision.needsManualPasteHint == false)
    }

    @Test func testAXVisibleMissKeepsDictationWithManualHint() {
        // Native target we can measure, but neither the paste nor an AX insert
        // grew it: a genuine miss. Keep the dictation and tell the user to paste.
        let decision = DeliveryPolicy.finalDecision(
            pastePosted: true, axVisible: true, axInsertGrew: false)
        #expect(decision == .keepDictationManual)
        #expect(decision.restoresUserClipboard == false)
        #expect(decision.needsManualPasteHint)
    }

    @Test func testMeasuredTargetThatChangedOffByOneCountsAsPasted() {
        // Claude's composer: the paste landed, but the count moved by one less than
        // the payload (or the field was re-created). That read as a miss and showed
        // "Copied. Press ⌘V" with an Accessibility button although the text was in.
        let decision = DeliveryPolicy.finalDecision(
            pastePosted: true, axVisible: true, axInsertGrew: false, targetChanged: true)
        #expect(decision == .keepDictationPasted)
        #expect(decision.restoresUserClipboard == false)
        #expect(decision.needsManualPasteHint == false)
    }

    @Test func testChangedTargetWithoutAPostedPasteIsStillAMiss() {
        // The paste never went out; a change in the field was the user typing.
        let decision = DeliveryPolicy.finalDecision(
            pastePosted: false, axVisible: true, axInsertGrew: false, targetChanged: true)
        #expect(decision == .keepDictationManual)
    }

    // MARK: - The happy paths that DO restore

    @Test func testAXInsertThatGrewRestoresClipboard() {
        let decision = DeliveryPolicy.finalDecision(
            pastePosted: true, axVisible: true, axInsertGrew: true)
        #expect(decision == .insertedViaAXRestore)
        #expect(decision.restoresUserClipboard)
        #expect(decision.needsManualPasteHint == false)
    }

    @Test func testPastedRestoreRestoresClipboard() {
        // Reached directly by deliver() when the element grew after the paste.
        #expect(DeliveryDecision.pastedRestore.restoresUserClipboard)
        #expect(DeliveryDecision.pastedRestore.needsManualPasteHint == false)
    }

    // MARK: - Nothing could be posted

    @Test func testNoPasteNoAXFallsBackToManual() {
        // No Accessibility trust: the Cmd-V never went out and the target is
        // unmeasurable. Ask for a manual paste.
        let decision = DeliveryPolicy.finalDecision(
            pastePosted: false, axVisible: false, axInsertGrew: false)
        #expect(decision == .keepDictationManual)
        #expect(decision.restoresUserClipboard == false)
        #expect(decision.needsManualPasteHint)
    }

    @Test func testNoPasteButAXInsertGrewRestores() {
        // Cmd-V couldn't post, but a direct AX insert landed and grew the field.
        let decision = DeliveryPolicy.finalDecision(
            pastePosted: false, axVisible: true, axInsertGrew: true)
        #expect(decision == .insertedViaAXRestore)
        #expect(decision.restoresUserClipboard)
    }

    // MARK: - The invariant that actually fixes the bug

    @Test func testRestoreOnlyEverHappensWhenSomethingGrew() {
        // Restoring the user's clipboard is the destructive step. It must be
        // reachable ONLY through a decision tied to observed growth, never from
        // an AX-blind / unproven outcome.
        let proven: [DeliveryDecision] = [.pastedRestore, .insertedViaAXRestore]
        let unproven: [DeliveryDecision] = [.keepDictationPasted, .keepDictationManual]
        #expect(proven.allSatisfy { $0.restoresUserClipboard })
        #expect(unproven.allSatisfy { !$0.restoresUserClipboard })
    }

    // MARK: - The clipboard setting

    @Test func testProvenSafeRestoreHappensWithTheDefaultSetting() {
        #expect(DeliveryPolicy.shouldRestoreClipboard(
            proven: true, canRestoreSafely: true, restorePreviousClipboard: true))
    }

    @Test func testSettingOffLeavesTheDictationEvenAfterAProvenPaste() {
        #expect(!DeliveryPolicy.shouldRestoreClipboard(
            proven: true, canRestoreSafely: true, restorePreviousClipboard: false))
    }

    @Test func testUnprovenOrUnsafeNeverRestoresWhateverTheSetting() {
        for setting in [true, false] {
            #expect(!DeliveryPolicy.shouldRestoreClipboard(
                proven: false, canRestoreSafely: true, restorePreviousClipboard: setting))
            #expect(!DeliveryPolicy.shouldRestoreClipboard(
                proven: true, canRestoreSafely: false, restorePreviousClipboard: setting))
        }
    }
}
