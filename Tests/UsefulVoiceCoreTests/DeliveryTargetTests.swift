import Testing
@testable import UsefulVoiceCore

/// The target lock: text goes only into the window captured at the hotkey press.
///
/// Ways it could fail, each pinned by a test below:
/// - pasting into whatever is in front at delivery (the "wrong composer" bug);
/// - matching by app id alone when the process is known, so a relaunched app
///   (new pid, same bundle id) counts as the old target;
/// - ignoring the window or the element, so another Slack window or another
///   composer in the same window takes the text;
/// - treating "could not read the focus now" as a match;
/// - treating a target that recorded no window or element as a mismatch, so an
///   AX-blind app (Electron) never pastes;
/// - reactivating a target that quit, or reactivating twice;
/// - pasting after a reactivation that reported success but brought back the
///   wrong window or element;
/// - pasting when no target was captured at all.
@Suite struct DeliveryTargetTests {
    private let slack = DeliveryTarget(appID: "com.tinyspeck.slackmacgap", appName: "Slack",
                                       processID: 501, windowID: "win#1", windowTitle: "general",
                                       elementID: "AXTextArea#9")

    private func with(pid: Int32? = 501, appID: String? = "com.tinyspeck.slackmacgap",
                      window: String? = "win#1", element: String? = "AXTextArea#9",
                      title: String? = "general") -> DeliveryTarget {
        DeliveryTarget(appID: appID, appName: "Slack", processID: pid, windowID: window,
                       windowTitle: title, elementID: element)
    }

    // MARK: - matches

    @Test func testSameProcessWindowAndElementMatches() {
        #expect(TargetLock.matches(slack, with()))
    }

    @Test func testWindowTitleIsNeverCompared() {
        // The title changes while the user types (unread counts, document names).
        #expect(TargetLock.matches(slack, with(title: "general (3)")))
    }

    @Test func testAnotherProcessOfTheSameAppDoesNotMatch() {
        // Relaunched: same bundle id, new pid. The old composer is gone.
        #expect(!TargetLock.matches(slack, with(pid: 777)))
    }

    @Test func testAppIDDecidesWhenAPidIsMissing() {
        let noPid = DeliveryTarget(appID: "com.apple.mail", appName: "Mail")
        #expect(TargetLock.matches(noPid, DeliveryTarget(appID: "com.apple.mail", processID: 12)))
        #expect(!TargetLock.matches(noPid, DeliveryTarget(appID: "com.apple.Notes", processID: 12)))
        #expect(!TargetLock.matches(noPid, DeliveryTarget(appID: nil, processID: 12)))
    }

    @Test func testAnotherWindowOfTheSameAppDoesNotMatch() {
        #expect(!TargetLock.matches(slack, with(window: "win#2")))
    }

    @Test func testAnotherElementInTheSameWindowDoesNotMatch() {
        // The search field instead of the composer.
        #expect(!TargetLock.matches(slack, with(element: "AXTextField#4")))
    }

    @Test func testAFocusThatCannotReportItsWindowOrElementDoesNotMatch() {
        #expect(!TargetLock.matches(slack, with(window: nil)))
        #expect(!TargetLock.matches(slack, with(element: nil)))
    }

    @Test func testATargetThatRecordedNoElementSkipsThatComparison() {
        // AX-blind app (Electron, a terminal): the element was never readable.
        let blind = with(element: nil)
        #expect(TargetLock.matches(blind, with(element: "AXGroup#3")))
        #expect(TargetLock.matches(blind, with(element: nil)))
        let noWindow = with(window: nil, element: nil)
        #expect(TargetLock.matches(noWindow, with(window: "win#7", element: nil)))
    }

    @Test func testUnreadableFocusNeverMatches() {
        #expect(!TargetLock.matches(slack, nil))
    }

    @Test func testAnUnidentifiedTargetMatchesNothing() {
        let nothing = DeliveryTarget(appID: nil)
        #expect(!nothing.isIdentified)
        #expect(!TargetLock.matches(nothing, DeliveryTarget(appID: nil)))
        #expect(!TargetLock.matches(nothing, slack))
    }

    @Test func testAppOnlyTargetFromFrontmostApp() {
        let target = DeliveryTarget(app: FrontmostApp(id: "com.apple.mail", name: "Mail"))
        #expect(target.appID == "com.apple.mail")
        #expect(target.appName == "Mail")
        #expect(target.processID == nil && target.windowID == nil && target.elementID == nil)
        #expect(target.browserURL == nil)
    }

    // MARK: - check (first look at delivery)

    @Test func testCheckInsertsWhenTheTargetIsStillInFront() {
        #expect(TargetLock.check(target: slack, current: with(), targetRunning: true) == .insert)
    }

    @Test func testCheckReactivatesWhenFocusMovedToAnotherApp() {
        let mail = DeliveryTarget(appID: "com.apple.mail", processID: 900, windowID: "w", elementID: "e")
        #expect(TargetLock.check(target: slack, current: mail, targetRunning: true) == .reactivate)
    }

    @Test func testCheckReactivatesWhenFocusMovedInsideTheTargetApp() {
        #expect(TargetLock.check(target: slack, current: with(window: "win#2"), targetRunning: true) == .reactivate)
        #expect(TargetLock.check(target: slack, current: with(element: "AXTextField#4"), targetRunning: true)
                == .reactivate)
    }

    @Test func testCheckReactivatesWhenTheFocusCannotBeRead() {
        #expect(TargetLock.check(target: slack, current: nil, targetRunning: true) == .reactivate)
    }

    @Test func testCheckCopiesWhenTheTargetQuit() {
        #expect(TargetLock.check(target: slack, current: nil, targetRunning: false) == .copyOnly(.targetGone))
        #expect(TargetLock.check(target: slack, current: with(pid: 777), targetRunning: false)
                == .copyOnly(.targetGone))
    }

    @Test func testCheckCopiesWhenNoTargetWasCaptured() {
        #expect(TargetLock.check(target: nil, current: with(), targetRunning: true) == .copyOnly(.unknownTarget))
        #expect(TargetLock.check(target: DeliveryTarget(appID: nil), current: with(), targetRunning: true)
                == .copyOnly(.unknownTarget))
    }

    @Test func testAStillFrontTargetInsertsEvenIfTheRunningProbeSaysOtherwise() {
        // In front is proof enough that it runs; a flaky probe must not block a paste.
        #expect(TargetLock.check(target: slack, current: with(), targetRunning: false) == .insert)
    }

    // MARK: - recheck (after one reactivation attempt)

    @Test func testRecheckInsertsWhenTheTargetCameBack() {
        #expect(TargetLock.recheck(target: slack, current: with(), reactivated: true) == .insert)
    }

    @Test func testRecheckCopiesWhenReactivationFailed() {
        // Even if the focus happens to read as the target, a refused activation is
        // not trusted.
        #expect(TargetLock.recheck(target: slack, current: with(), reactivated: false) == .copyOnly(.notRestored))
    }

    @Test func testRecheckCopiesWhenTheWrongWindowOrElementCameBack() {
        #expect(TargetLock.recheck(target: slack, current: with(window: "win#2"), reactivated: true)
                == .copyOnly(.notRestored))
        #expect(TargetLock.recheck(target: slack, current: with(element: "AXTextField#4"), reactivated: true)
                == .copyOnly(.notRestored))
        #expect(TargetLock.recheck(target: slack, current: nil, reactivated: true) == .copyOnly(.notRestored))
    }

    @Test func testRecheckNeverAsksToReactivateAgain() {
        let currents: [DeliveryTarget?] = [nil, with(), with(window: "x"), with(pid: 3)]
        for current in currents {
            for reactivated in [true, false] {
                #expect(TargetLock.recheck(target: slack, current: current, reactivated: reactivated) != .reactivate)
            }
        }
    }

    @Test func testRecheckWithoutATargetCopies() {
        #expect(TargetLock.recheck(target: nil, current: with(), reactivated: true) == .copyOnly(.unknownTarget))
    }

    // MARK: - Insertion method

    @Test func testPasteIsTheDefaultForEveryApp() {
        #expect(InsertionMethod.method(forAppID: "com.apple.Terminal", typeOutApps: []) == .paste)
    }

    @Test func testTypeOutOnlyForAppsTheUserTurnedOn() {
        let list = ["com.apple.Terminal", "com.googlecode.iterm2"]
        #expect(InsertionMethod.method(forAppID: "com.apple.Terminal", typeOutApps: list) == .typeOut)
        #expect(InsertionMethod.method(forAppID: "com.googlecode.iterm2", typeOutApps: list) == .typeOut)
        #expect(InsertionMethod.method(forAppID: "com.tinyspeck.slackmacgap", typeOutApps: list) == .paste)
    }

    @Test func testTypeOutMatchIgnoresCase() {
        #expect(InsertionMethod.method(forAppID: "com.apple.terminal", typeOutApps: ["com.apple.Terminal"])
                == .typeOut)
    }

    @Test func testAnUnknownAppAlwaysPastes() {
        #expect(InsertionMethod.method(forAppID: nil, typeOutApps: ["com.apple.Terminal"]) == .paste)
        #expect(InsertionMethod.method(forAppID: "", typeOutApps: [""]) == .paste)
    }

    // MARK: - Type-out chunks

    @Test func testChunksCoverTheTextExactlyOnceInOrder() {
        let text = String(repeating: "Hallo Welt, ", count: 9)
        let chunks = TypeOutChunker.chunks(of: text)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= TypeOutChunker.maxUnitsPerEvent })
        #expect(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == text)
    }

    @Test func testAnEmptyTextHasNoChunks() {
        #expect(TypeOutChunker.chunks(of: "").isEmpty)
    }

    @Test func testAChunkNeverSplitsAnEmoji() {
        // 19 ASCII then an emoji: the emoji's two UTF-16 units straddle unit 20.
        let text = String(repeating: "a", count: 19) + "😀" + "b"
        let chunks = TypeOutChunker.chunks(of: text)
        for chunk in chunks {
            #expect(!UTF16.isLeadSurrogate(chunk.last!))
            #expect(!UTF16.isTrailSurrogate(chunk.first!))
        }
        #expect(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == text)
    }

    @Test func testAChunkNeverSplitsCRLF() {
        let text = String(repeating: "a", count: 19) + "\r\n" + "b"
        let chunks = TypeOutChunker.chunks(of: text)
        #expect(chunks[0].last != 0x0D)
        #expect(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == text)
    }

    @Test func testPersianWithZWNJSurvivesChunking() {
        let text = "می‌خواهم این متن را بنویسم و بعد آن را ارسال کنم"
        let chunks = TypeOutChunker.chunks(of: text, maxUnits: 7)
        #expect(chunks.allSatisfy { $0.count <= 7 })
        #expect(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == text)
    }

    // MARK: - Browsers

    @Test func testKnownBrowsersAreRecognised() {
        for id in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
                   "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox"] {
            #expect(KnownBrowsers.isBrowser(bundleID: id))
        }
        #expect(!KnownBrowsers.isBrowser(bundleID: "com.tinyspeck.slackmacgap"))
        #expect(!KnownBrowsers.isBrowser(bundleID: nil))
    }
}
