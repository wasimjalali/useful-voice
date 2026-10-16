import Foundation
import Testing
@testable import UsefulVoiceCore

/// One paste-mode delivery with every effect faked and recorded. Mirrors
/// `windows/tests/deliveryFlow.test.ts`.
///
/// Ways it could fail, each pinned below:
/// - posting anything into a password field, or after the target lost focus;
/// - both pasting and typing, or running the AX insert after type-out (queued
///   keystrokes would land on top of it: the text twice);
/// - typing text with a line break (each one is an Enter key), or pasting it into an
///   app the user marked for typing, or calling that plain "copied";
/// - typing on after a password field appeared, focus moved, a key could not be
///   posted or time ran out, or calling such a stop plain "copied";
/// - blocking the main thread between batches instead of scheduling them;
/// - restoring the user's clipboard without proof, when it was not saved safely,
///   or when the user turned restoring off;
/// - losing the dictation when the clipboard write fails.
@Suite struct InsertionFlowTests {
    final class Fake {
        var calls: [String] = []
        var secure: [Bool] = [false]
        var saveSafe = true
        var writeOK = true
        var onTarget: [Bool] = [true]
        var pasteOK = true
        /// Whether batch `n` (0-based) can be posted.
        var keysOK: (Int) -> Bool = { _ in true }
        var probes: [FocusProbe?] = [nil]
        var axInsertOK = false
        var clock = Date(timeIntervalSince1970: 0)
        var delays: [TimeInterval] = []
        var keyBatches: [[UInt16]] = []
        var outcome: InsertionOutcome?
        private var secureCall = 0, targetCall = 0, probeCall = 0

        private func next<T>(_ values: [T], _ index: inout Int) -> T {
            defer { index += 1 }
            return values[min(index, values.count - 1)]
        }

        var effects: InsertionEffects {
            InsertionEffects(
                isSecureInput: { [unowned self] in calls.append("secure?"); return next(secure, &secureCall) },
                saveClipboard: { [unowned self] in calls.append("save"); return saveSafe },
                writeClipboard: { [unowned self] _ in calls.append("write"); return writeOK },
                recoverClipboard: { [unowned self] in calls.append("recover") },
                restoreClipboard: { [unowned self] in calls.append("restore"); return true },
                onTarget: { [unowned self] in calls.append("onTarget?"); return next(onTarget, &targetCall) },
                // The same answers as `onTarget`, in call order, under its own name.
                stillOnTarget: { [unowned self] in calls.append("stillOnTarget?"); return next(onTarget, &targetCall) },
                postPaste: { [unowned self] in calls.append("paste"); return pasteOK },
                postKeys: { [unowned self] batch in
                    calls.append("keys")
                    guard keysOK(keyBatches.count) else { return false }
                    keyBatches.append(batch)
                    return true
                },
                axInsert: { [unowned self] _ in calls.append("axInsert"); return axInsertOK },
                probe: { [unowned self] in next(probes, &probeCall) },
                schedule: { [unowned self] delay, work in
                    delays.append(delay)
                    clock = clock.addingTimeInterval(delay)
                    work()
                },
                now: { [unowned self] in clock },
                settled: { [unowned self] in calls.append("settled") })
        }

        func run(_ text: String = "hello world", appID: String? = "com.apple.TextEdit",
                 typeOut: [String] = ["com.apple.Terminal"], restore: Bool = true,
                 timing: InsertionTiming = InsertionTiming()) {
            InsertionFlow.run(InsertionRequest(text: text, appID: appID, typeOutApps: typeOut,
                                               restorePreviousClipboard: restore),
                              timing: timing, effects: effects) { [unowned self] in outcome = $0 }
        }

        var keystrokes: [String] { calls.filter { $0 == "paste" || $0 == "keys" } }
        var typedText: String { String(decoding: keyBatches.flatMap { $0 }, as: UTF16.self) }
    }

    private let field = "AXTextArea#1"
    private func probe(_ count: Int?) -> FocusProbe { FocusProbe(identifier: field, charCount: count) }
    private let terminal = "com.apple.Terminal"
    private let long = "a command line long enough to need several batches of keystrokes"

    // MARK: - Paste

    @Test func testAProvenPasteRestoresTheClipboard() {
        let fake = Fake()
        fake.probes = [probe(10), probe(21)]
        fake.run()
        #expect(fake.outcome == .pasted)
        #expect(fake.keystrokes == ["paste"])
        #expect(fake.calls.contains("restore"))
        #expect(fake.calls.last == "settled")
    }

    @Test func testRestoreOffKeepsTheDictationAfterAProvenPaste() {
        let fake = Fake()
        fake.probes = [probe(10), probe(21)]
        fake.run(restore: false)
        #expect(fake.outcome == .pasted)
        #expect(!fake.calls.contains("restore"))
    }

    @Test func testAClipboardThatWasNotSavedSafelyIsNeverRestored() {
        let fake = Fake()
        fake.saveSafe = false
        fake.probes = [probe(10), probe(21)]
        fake.run()
        #expect(fake.outcome == .pasted)
        #expect(!fake.calls.contains("restore"))
    }

    @Test func testAnUnprovenPasteIntoAMeasurableFieldTriesOneVerifiedAXInsert() {
        let fake = Fake()
        fake.probes = [probe(10), probe(10), probe(10), probe(21)]
        fake.axInsertOK = true
        fake.run()
        #expect(fake.outcome == .insertedViaAX)
        #expect(fake.calls.filter { $0 == "axInsert" }.count == 1)
        #expect(fake.calls.contains("restore"))
    }

    @Test func testGrowthByAnotherAmountThanThePayloadIsNotProofAndNeverRestores() {
        // "hello world" is 11 units; the field grew by 2.
        let fake = Fake()
        fake.probes = [probe(10), probe(12)]
        fake.run()
        #expect(fake.outcome == .pasted)
        #expect(!fake.calls.contains("restore"))
    }

    @Test func testGrowthReportedByAnotherElementIsNotProofAndNeverRestores() {
        let fake = Fake()
        fake.probes = [probe(10), FocusProbe(identifier: "AXTextArea#2", charCount: 21)]
        fake.run()
        #expect(fake.outcome == .pasted)
        #expect(!fake.calls.contains("restore"))
    }

    @Test func testAPasteThatChangedTheFieldGetsNoAXInsertOnTop() {
        // The paste landed somewhere we can't measure exactly: an AX insert would be the text twice.
        let fake = Fake()
        fake.probes = [probe(10), probe(12), probe(12)]
        fake.axInsertOK = true
        fake.run()
        #expect(!fake.calls.contains("axInsert"))
        #expect(fake.outcome == .pasted)
        #expect(!fake.calls.contains("restore"))
    }

    @Test func testAPostedPasteWhoseFieldCannotBeReadAfterwardsIsPastedNotManual() {
        // Measurable before, unreadable after: "Press Cmd-V" would put it in twice.
        let fake = Fake()
        fake.probes = [probe(10), nil]
        fake.axInsertOK = true
        fake.run()
        #expect(fake.outcome == .pasted)
        #expect(!fake.calls.contains("axInsert"))
        #expect(!fake.calls.contains("restore"))
    }

    @Test func testAPasteThatCouldNotBePostedInAnAXBlindAppAsksForAManualPaste() {
        let fake = Fake()
        fake.pasteOK = false
        fake.run()
        #expect(fake.outcome == .clipboardOnly)
        #expect(!fake.calls.contains("restore"))
    }

    // MARK: - Before anything is posted

    @Test func testASecureFieldGetsNothingAndNothingIsSavedAside() {
        for typeOut in [[], [terminal]] {
            let fake = Fake()
            fake.secure = [true]
            fake.run(appID: terminal, typeOut: typeOut)
            #expect(fake.outcome == .secureFieldCopied)
            #expect(fake.keystrokes.isEmpty)
            #expect(!fake.calls.contains("save"))
            #expect(fake.calls.contains("write"))
        }
    }

    @Test func testAFailedClipboardWriteReportsFailedAndPutsTheUsersClipboardBack() {
        let fake = Fake()
        fake.writeOK = false
        fake.run()
        #expect(fake.outcome == .failed)
        #expect(fake.keystrokes.isEmpty)
        #expect(fake.calls.contains("recover"))
    }

    @Test func testAMovedTargetGetsNothingWhicheverTheMethod() {
        for typeOut in [[], [terminal]] {
            let fake = Fake()
            fake.onTarget = [false]
            fake.run(appID: terminal, typeOut: typeOut)
            #expect(fake.outcome == .targetLost)
            #expect(fake.keystrokes.isEmpty)
            // The dictation was written before the look, so it's on the clipboard.
            #expect(fake.calls.firstIndex(of: "write")! < fake.calls.firstIndex(of: "onTarget?")!)
        }
    }

    // MARK: - Type-out

    @Test func testTypeOutTypesTheWholeTextInBatchesAndNeverPastes() {
        let fake = Fake()
        fake.run(long, appID: terminal)
        #expect(fake.typedText == long)
        #expect(fake.keyBatches.count > 1)
        #expect(!fake.calls.contains("paste"))
        #expect(fake.outcome == .pasted || fake.outcome == .clipboardOnly)
    }

    @Test func testBatchesAreScheduledNotSleptOn() {
        let fake = Fake()
        fake.run(long, appID: terminal)
        let gaps = fake.delays.prefix(fake.keyBatches.count - 1)
        #expect(gaps.count == fake.keyBatches.count - 1)
        #expect(gaps.allSatisfy { $0 == InsertionTiming().keyGap })
    }

    @Test func testTypeOutNeverRunsTheAXInsertEvenWhenUnproven() {
        let fake = Fake()
        fake.probes = [probe(10)]          // measurable, never grows
        fake.axInsertOK = true
        fake.run(long, appID: terminal)
        #expect(!fake.calls.contains("axInsert"))
        #expect(fake.outcome == .clipboardOnly)
        #expect(!fake.calls.contains("restore"))
    }

    @Test func testAProvenTypeOutRestoresOnlyWhenTheUserWantsIt() {
        let grown = probe(10 + long.utf16.count)
        let on = Fake()
        on.probes = [probe(10), grown]
        on.run(long, appID: terminal)
        #expect(on.outcome == .pasted)
        #expect(on.calls.contains("restore"))
        let off = Fake()
        off.probes = [probe(10), grown]
        off.run(long, appID: terminal, restore: false)
        #expect(off.outcome == .pasted)
        #expect(!off.calls.contains("restore"))
    }

    @Test func testAFullTypeOutWhoseFieldCannotBeReadAfterwardsIsPastedNotManual() {
        let fake = Fake()
        fake.probes = [probe(10), nil]
        fake.run(long, appID: terminal)
        #expect(fake.typedText == long)
        #expect(fake.outcome == .pasted)
        #expect(!fake.calls.contains("restore"))
    }

    @Test func testTextWithALineBreakIsCopyOnlyForATypeOutApp() {
        let fake = Fake()
        fake.probes = [probe(10)]
        fake.axInsertOK = true
        fake.run("git add .\ngit commit", appID: terminal)
        #expect(fake.keystrokes.isEmpty)
        #expect(!fake.calls.contains("axInsert"))
        #expect(fake.calls.contains("write"))
        #expect(!fake.calls.contains("restore"))
        #expect(fake.outcome == .copiedHasLineBreaks)
    }

    @Test func testTextWithALineBreakStillPastesInAPasteApp() {
        let fake = Fake()
        fake.probes = [probe(10), probe(10 + "one\ntwo".utf16.count)]
        fake.run("one\ntwo")
        #expect(fake.keystrokes == ["paste"])
        #expect(fake.outcome == .pasted)
    }

    @Test func testASecureFieldMidwayStopsTypingAsPartlyTyped() {
        let fake = Fake()
        // The first look (before saving), batch 0 and batch 1 are clear; batch 2 is not.
        fake.secure = [false, false, false, true]
        fake.run(long, appID: terminal)
        #expect(fake.keyBatches.count == 2)
        #expect(fake.outcome == .partlyTyped)
        #expect(!fake.calls.contains("restore"))
    }

    @Test func testASecureFieldBeforeTheFirstBatchIsTheSecureFieldNotice() {
        let fake = Fake()
        fake.secure = [false, true]
        fake.run(long, appID: terminal)
        #expect(fake.keyBatches.isEmpty)
        #expect(fake.outcome == .secureFieldCopied)
    }

    @Test func testFocusMovingMidwayStopsTypingAsPartlyTyped() {
        let fake = Fake()
        // The look before posting, then before batch 1 and batch 2.
        fake.onTarget = [true, true, false]
        fake.run(long, appID: terminal)
        #expect(fake.keyBatches.count == 2)
        #expect(fake.outcome == .partlyTyped)
    }

    @Test func testTheCheckBetweenBatchesIsIdentityOnly() {
        // The full look (with the page) once before posting; identity only per batch.
        let fake = Fake()
        fake.run(long, appID: terminal)
        #expect(fake.calls.filter { $0 == "onTarget?" }.count == 1)
        #expect(fake.calls.filter { $0 == "stillOnTarget?" }.count == fake.keyBatches.count - 1)
    }

    @Test func testAKeyThatCannotBePostedMidwayIsPartlyTyped() {
        let fake = Fake()
        fake.keysOK = { $0 < 1 }
        fake.run(long, appID: terminal)
        #expect(fake.keyBatches.count == 1)
        #expect(fake.outcome == .partlyTyped)
    }

    @Test func testTypingThatCannotStartFallsBackWithoutAnAXInsert() {
        let fake = Fake()
        fake.keysOK = { _ in false }
        fake.probes = [probe(10)]
        fake.axInsertOK = true
        fake.run(long, appID: terminal)
        #expect(fake.keyBatches.isEmpty)
        #expect(!fake.calls.contains("axInsert"))
        #expect(fake.outcome == .clipboardOnly)
    }

    @Test func testTypingThatRunsOutOfTimeStopsAsPartlyTyped() {
        let fake = Fake()
        // Each gap costs a second on the fake clock; the budget allows two.
        fake.run(long, appID: terminal,
                 timing: InsertionTiming(keyGap: 1, typingBudget: 2.5))
        #expect(fake.keyBatches.count == 3)
        #expect(fake.outcome == .partlyTyped)
        #expect(fake.typedText != long)
    }
}
