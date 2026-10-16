import Testing
import Foundation
@testable import UsefulVoiceCore

/// App-aware formatting through the real controller: the category is decided at the press,
/// the text is formatted for it in the formatted path only, and the send key is pressed
/// only after a delivery that landed in the target locked at the press.
@Suite @MainActor final class AppAwareDictationTests {
    private let dir: URL
    private let store: RecordingStore
    private let recorder = FakeRecorder()

    private var delivered: [String] = []
    private var deliveredModes: [DeliveryMode] = []
    private var outcomes: [DictationOutcome] = []
    private var records: [DictationRecord] = []
    private var sentKeys: [SendKeyChord] = []
    private var cursorReads: [DeliveryTarget] = []
    private var settingsReads = 0
    private var reactivations = 0

    // What the fake system reports.
    private var focus: DeliveryTarget?
    private var secureInput = false
    private var reactivationSucceeds = true
    /// Moves focus here while the delivery is in flight, to model leaving the target at the last moment.
    private var focusDuringDelivery: DeliveryTarget??
    private var deliveryResult: DeliveryResult?
    private var deliveryFails = false
    private var textBefore: String?

    // What the person chose.
    private var appFormatting = AppFormattingSettings(userName: "Wasim")

    private let mail = DeliveryTarget(appID: "com.apple.mail", appName: "Mail", processID: 900,
                                      windowID: "win#5", elementID: "AXTextArea#2")
    private let slack = DeliveryTarget(appID: "com.tinyspeck.slackmacgap", appName: "Slack", processID: 501,
                                       windowID: "win#1", elementID: "AXTextArea#9")
    private let terminal = DeliveryTarget(appID: "com.apple.Terminal", appName: "Terminal", processID: 310,
                                          windowID: "win#3", elementID: "AXTextArea#4")
    private let messages = DeliveryTarget(appID: "com.apple.MobileSMS", appName: "Messages", processID: 220,
                                          windowID: "win#2", elementID: "AXTextArea#7")
    private let ownWindow = DeliveryTarget(appID: "ai.useful.voice", appName: "Useful Voice", processID: 42,
                                           windowID: "win#9", elementID: "AXTextArea#1")

    private let emailDictation =
        "Hi Sam, can you send me the report. Thanks."
    private let emailFormatted =
        "Hi Sam,\n\nCan you send me the report.\n\nThanks,\nWasim"

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("aware-\(UUID().uuidString)")
        store = try RecordingStore(directory: dir)
        focus = mail
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    private func provider(_ text: String) -> TranscriptionProvider {
        FakeProvider(name: "fake", result: .success(Transcript(text: text, detectedLanguage: nil, durationSeconds: 1)))
    }

    private func controller(
        _ text: String,
        providers: [TranscriptionProvider]? = nil,
        format: ((String, FormattingContext) async throws -> FormattingResult)? = nil,
        rawTransform: ((String, FormattingContext) async -> FormattingResult)? = nil,
        ownAppID: String? = nil,
        typeOutApps: [String] = [],
        words: [String] = []
    ) -> DictationController {
        let controller = DictationController(
            recorder: recorder,
            providers: { providers ?? [self.provider(text)] },
            store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) },
            recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            record: { [weak self] record in self?.records.append(record) },
            diagnostics: .memoryOnly,
            format: format,
            rawTransform: rawTransform,
            context: { FormattingContext(appBundleID: nil, dictionaryWords: words, language: .auto) },
            isSecureInputActive: { [weak self] in self?.secureInput ?? false },
            focusTarget: { [weak self] in self?.focus },
            isTargetRunning: { _ in true },
            reactivate: { [weak self] target in
                guard let self else { return false }
                self.reactivations += 1
                if self.reactivationSucceeds { self.focus = target }
                return self.reactivationSucceeds
            },
            typeOutApps: { typeOutApps },
            appFormatting: { [weak self] in
                self?.settingsReads += 1
                return self?.appFormatting ?? .standard
            },
            textBeforeCursor: { [weak self] target in
                self?.cursorReads.append(target)
                return self?.textBefore
            },
            sendKey: { [weak self] chord in self?.sentKeys.append(chord) },
            ownAppID: ownAppID)
        controller.onOutcome = { [weak self] outcome in self?.outcomes.append(outcome) }
        return controller
    }

    private func fakeDeliver(_ text: String, _ mode: DeliveryMode, _ done: @escaping (DeliveryReport) -> Void) {
        delivered.append(text)
        deliveredModes.append(mode)
        if let move = focusDuringDelivery { focus = move }
        if deliveryFails { done(.failure(DeliveryFailure())); return }
        done(.success(deliveryResult ?? (mode == .paste ? .pasted : .copied)))
    }

    private func dictate(_ controller: DictationController, rawMode: Bool = false,
                         source: DictationSource = .hotkey) async {
        controller.toggle(source: source)
        controller.toggle(rawMode: rawMode)
        await controller.awaitProcessing()
    }

    // MARK: formatting for the category

    @Test func anEmailToMailGetsItsGreetingParagraphsAndSignOffWithTheName() async {
        let c = controller(emailDictation)
        await dictate(c)
        #expect(delivered == [emailFormatted])
        #expect(deliveredModes == [.paste])
        #expect(records.first?.text == emailFormatted)
        #expect(records.first?.rawText == emailDictation)
        #expect(records.first?.appID == "com.apple.mail")
        #expect(records.first?.category == "email")
    }

    @Test func historyShowsFormattedOnlyWhenTheCategoryFormatterChangedTheText() async {
        let c = controller(emailDictation)
        await dictate(c)
        #expect(records.last?.mode == .formatted)
        focus = slack
        await dictate(controller("Sounds good"))      // nothing to change
        #expect(records.last?.mode == .raw)
        appFormatting.enabled = false
        focus = mail
        await dictate(controller(emailDictation))
        #expect(records.last?.mode == .raw)
    }

    @Test func noNameMeansNoNameIsAdded() async {
        appFormatting.userName = ""
        let c = controller(emailDictation)
        await dictate(c)
        #expect(delivered == ["Hi Sam,\n\nCan you send me the report.\n\nThanks."])
    }

    @Test func aWorkChatDropsTheClosingFullStopAndFormalKeepsIt() async {
        focus = slack
        let c = controller("Sounds good.")
        await dictate(c)
        #expect(delivered == ["Sounds good"])
        #expect(records.first?.category == "workChat")

        delivered = []
        appFormatting.setStyle(.formal, for: .workChat)
        await dictate(c)
        #expect(delivered == ["Sounds good."])
    }

    @Test func veryCasualAppliesToPersonalChatOnly() async {
        focus = messages
        appFormatting.setStyle(.veryCasual, for: .personalChat)
        let c = controller("Are you free tonight.")
        await dictate(c)
        #expect(delivered == ["are you free tonight"])

        delivered = []
        focus = slack
        appFormatting.styles["workChat"] = .veryCasual   // a stale value the category does not allow
        await dictate(c)
        #expect(delivered == ["Are you free tonight"])
    }

    @Test func aBrowserIsCategorisedByTheCapturedPageAddress() async {
        focus = DeliveryTarget(appID: "com.google.Chrome", appName: "Chrome", processID: 700, windowID: "win#6",
                               elementID: "AXTextArea#3", browserURL: "https://mail.google.com/mail/u/0/#inbox")
        let c = controller(emailDictation)
        await dictate(c)
        #expect(delivered == [emailFormatted])
        #expect(records.first?.category == "email")
    }

    @Test func theUsersOverrideForAnAppWins() async {
        appFormatting.setCategory(.personalChat, forAppID: "com.apple.mail")
        let c = controller("Sounds good.")
        await dictate(c)
        // Personal chat: no email layout, and the closing full stop goes.
        #expect(delivered == ["Sounds good"])
        #expect(records.first?.category == "personalChat")
    }

    @Test func theCategoryIsDecidedAtThePressNotAfterTranscription() async {
        focus = mail
        let c = controller(emailDictation)
        c.toggle()
        focus = slack            // clicked into Slack while talking
        c.toggle()
        await c.awaitProcessing()
        #expect(delivered == [emailFormatted])
        #expect(records.first?.category == "email")
        #expect(reactivations == 1)      // the lock brought Mail back
    }

    @Test func theSettingsOfThePressAreTheOnesUsed() async {
        focus = slack
        let c = controller("Sounds good.")
        c.toggle()
        appFormatting.enabled = false      // changed while recording
        appFormatting.setStyle(.formal, for: .workChat)
        c.toggle()
        await c.awaitProcessing()
        #expect(delivered == ["Sounds good"])
        #expect(settingsReads == 1)
    }

    @Test func offMeansTheTranscriptIsDeliveredAsItCame() async {
        appFormatting.enabled = false
        let c = controller(emailDictation)
        await dictate(c)
        #expect(delivered == [emailDictation])
        #expect(cursorReads.isEmpty)
    }

    @Test func rawModeStaysRaw() async {
        let c = controller(emailDictation)
        await dictate(c, rawMode: true)
        #expect(delivered == [emailDictation])
        #expect(records.first?.rawText == emailDictation)
    }

    @Test func rawModeStillRunsTheRawTransformOnTheUntouchedTranscript() async {
        var seen: [String] = []
        let c = controller(emailDictation, rawTransform: { raw, _ in
            seen.append(raw)
            return FormattingResult(text: raw.uppercased(), newTerms: [], mode: .raw)
        })
        await dictate(c, rawMode: true)
        #expect(seen == [emailDictation])
        #expect(delivered == [emailDictation.uppercased()])
    }

    // MARK: where it sits in the pipeline

    @Test func theUsersRulesAndSnippetsRunAfterTheCategoryFormatting() async {
        var received: [String] = []
        let c = controller(emailDictation, format: { text, _ in
            received.append(text)
            // A user's replacement rule has the last word on what the formatter produced.
            return FormattingResult(text: text.replacingOccurrences(of: "report", with: "Q3 report"), newTerms: [])
        })
        await dictate(c)
        #expect(received == [emailFormatted])
        #expect(delivered == [emailFormatted.replacingOccurrences(of: "report", with: "Q3 report")])
    }

    @Test func ifTheFormatterFailsTheTranscriptIsDeliveredWithoutCategoryFormatting() async {
        struct Boom: Error {}
        let c = controller(emailDictation, format: { _, _ in throw Boom() })
        await dictate(c)
        #expect(delivered == [emailDictation])
        #expect(outcomes.count == 1)
    }

    @Test func aFormatterThatChangesNothingUsefulNeverEmptiesTheDictation() {
        // The plan keeps the text when the formatter has nothing usable to say.
        let plan = AppFormattingPlan(category: .email, userName: "Wasim")
        #expect(plan.apply(to: "   ") == "   ")
        #expect(plan.apply(to: "") == "")
        #expect(plan.apply(to: "ok") == "ok")
    }

    @Test func dictionaryWordsKeepTheirCapitalisationInVeryCasual() async {
        focus = messages
        appFormatting.setStyle(.veryCasual, for: .personalChat)
        let c = controller("Wasim is here.", words: ["Wasim"])
        await dictate(c)
        #expect(delivered == ["Wasim is here"])
    }

    // MARK: text before the cursor

    @Test func theTextBeforeTheCursorIsReadAtThePressAndFitsTheContinuation() async {
        focus = slack
        textBefore = "I was thinking"
        let c = controller("We could go.")
        c.toggle()
        #expect(c.state == .recording)
        // Started at the press, not after transcription.
        await Task.yield()
        #expect(cursorReads == [slack])
        c.toggle()
        await c.awaitProcessing()
        #expect(delivered == [" we could go"])
    }

    @Test func theTextBeforeTheCursorIsNeverStored() async {
        focus = slack
        textBefore = "my secret draft so far"
        let c = controller("We could go.")
        await dictate(c)
        let stored = records.map { "\($0)" }.joined()
        #expect(!stored.contains("secret draft"))
    }

    @Test func aReadThatFindsNothingFormatsWithoutIt() async {
        focus = slack
        textBefore = nil
        let c = controller("We could go.")
        await dictate(c)
        #expect(delivered == ["We could go"])
    }

    @Test func aReaderThatNeverAnswersCannotHoldUpTheDictation() async {
        focus = slack
        let c = DictationController(
            recorder: recorder, providers: { [self.provider("We could go.")] }, store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) }, recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            diagnostics: .memoryOnly,
            focusTarget: { [weak self] in self?.focus },
            appFormatting: { AppFormattingSettings() },
            textBeforeCursor: { _ in await withCheckedContinuation { (_: CheckedContinuation<String?, Never>) in } })
        let started = Date()
        c.toggle()
        #expect(c.state == .recording)               // the press did not wait for the reader
        #expect(Date().timeIntervalSince(started) < 1)
        c.toggle()
        await c.awaitProcessing()
        #expect(delivered == ["We could go"])        // formatted without the unknown context
        #expect(Date().timeIntervalSince(started) < 15)   // it only has to end; CI machines are slow under load
    }

    // MARK: window dictations and Useful Voice itself (WAS-54 item 4)

    @Test func aWindowDictationIsOtherCopiedAndFiledUnderNoApp() async {
        focus = mail
        let c = controller(emailDictation)
        await dictate(c, source: .window)
        #expect(delivered == [emailDictation])             // Other: no email layout
        #expect(deliveredModes == [.copy])
        #expect(records.first?.appID == nil)
        #expect(records.first?.category == nil)
        #expect(cursorReads.isEmpty)
    }

    @Test func theHotkeyPressedInUsefulVoiceItselfIsAWindowDictation() async {
        focus = ownWindow
        let c = controller(emailDictation, ownAppID: "ai.useful.voice")
        c.toggle()
        #expect(c.deliveryTarget == nil)
        await { c.toggle(); await c.awaitProcessing() }()
        #expect(deliveredModes == [.copy])
        #expect(outcomes == [.delivered(words: 9, mode: .copied, appName: nil)])
        #expect(reactivations == 0)
        #expect(records.first?.appID == nil)
        #expect(records.first?.category == nil)
        #expect(cursorReads.isEmpty)
        #expect(sentKeys.isEmpty)
    }

    @Test func theOwnAppIsMatchedWithoutRegardToCase() async {
        focus = DeliveryTarget(appID: "AI.Useful.Voice", appName: "Useful Voice", processID: 42)
        let c = controller("hello", ownAppID: "ai.useful.voice")
        await dictate(c)
        #expect(deliveredModes == [.copy])
    }

    @Test func anotherAppStillPastes() async {
        let c = controller("hello", ownAppID: "ai.useful.voice")
        await dictate(c)
        #expect(deliveredModes == [.paste])
    }

    // MARK: retry

    @Test func aRetryIsFormattedForTheAppItWasDictatedForAndOnlyCopied() async {
        var attempt = 0
        let providers: [TranscriptionProvider] = [
            FakeProvider(name: "flaky", result: .failure(ProviderError.http(500, "boom")))
        ]
        let c = DictationController(
            recorder: recorder,
            providers: {
                attempt += 1
                return attempt == 1 ? providers : [self.provider(self.emailDictation)]
            },
            store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) }, recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in self?.fakeDeliver(text, mode, done) },
            record: { [weak self] record in self?.records.append(record) },
            diagnostics: .memoryOnly,
            focusTarget: { [weak self] in self?.focus },
            appFormatting: { [weak self] in self?.appFormatting ?? .standard },
            sendKey: { [weak self] chord in self?.sentKeys.append(chord) })
        appFormatting.setAutoSend(.return, for: .workChat)
        await dictate(c)
        #expect(c.canRetry)
        focus = slack      // in front when Retry is clicked
        await c.retryLastAndWait()
        #expect(delivered == [emailFormatted])
        #expect(deliveredModes == [.copy])
        #expect(records.first?.category == "email")
        #expect(sentKeys.isEmpty)
    }

    // MARK: auto-send

    @Test func autoSendPressesTheKeyAfterADeliveryThatLanded() async {
        focus = slack
        appFormatting.setAutoSend(.return, for: .workChat)
        let c = controller("Sounds good.")
        await dictate(c)
        #expect(sentKeys == [SendKeyChord()])
        #expect(outcomes.count == 1)
    }

    @Test func autoSendUsesTheChosenChord() async {
        focus = slack
        appFormatting.setAutoSend(.shiftReturn, for: .workChat)
        let c = controller("one")
        await dictate(c)
        appFormatting.setAutoSend(.modReturn, for: .workChat)
        await dictate(c)
        #expect(sentKeys == [SendKeyChord(shift: true), SendKeyChord(command: true)])
    }

    @Test func autoSendIsOffByDefaultEverywhere() async {
        for target in [slack, messages, terminal, mail] {
            focus = target
            let c = controller("hello there")
            await dictate(c)
        }
        #expect(delivered.count == 4)
        #expect(sentKeys.isEmpty)
    }

    @Test func autoSendIsPerCategory() async {
        appFormatting.setAutoSend(.return, for: .workChat)
        focus = messages
        await dictate(controller("hello"))
        #expect(sentKeys.isEmpty)
        focus = slack
        await dictate(controller("hello"))
        #expect(sentKeys.count == 1)
    }

    @Test func autoSendNeverFiresForEmailOrDocsAndNotesEvenIfSomethingStoredIt() async throws {
        appFormatting = try JSONDecoder().decode(AppFormattingSettings.self, from: Data(
            #"{"autoSend": {"email": "return", "docsNotes": "return"}}"#.utf8))
        focus = mail
        await dictate(controller("hello"))
        focus = DeliveryTarget(appID: "com.apple.Notes", appName: "Notes", processID: 12, windowID: "w", elementID: "e")
        await dictate(controller("hello"))
        #expect(delivered.count == 2)
        #expect(sentKeys.isEmpty)
    }

    @Test func autoSendWorksAfterATypedDeliveryToo() async {
        // A typed delivery that completed reports the same landed result as a paste.
        focus = terminal
        appFormatting.setAutoSend(.return, for: .coding)
        deliveryResult = .pasted
        await dictate(controller("git status", typeOutApps: ["com.apple.Terminal"]))
        #expect(sentKeys == [SendKeyChord()])
    }

    @Test func autoSendNeverFiresAfterAnythingButALandedDelivery() async {
        focus = slack
        appFormatting.setAutoSend(.return, for: .workChat)
        let notLanded: [DeliveryResult] = [.copied, .copiedNotPasted, .copiedAppChanged, .copiedSecureField,
                                           .copiedNotLanded, .copiedPartlyTyped, .copiedHasLineBreaks]
        for result in notLanded {
            deliveryResult = result
            await dictate(controller("hello"))
        }
        #expect(delivered.count == notLanded.count)
        #expect(sentKeys.isEmpty, "\(sentKeys)")
    }

    @Test func autoSendNeverFiresAfterAFailedDelivery() async {
        focus = slack
        appFormatting.setAutoSend(.return, for: .workChat)
        deliveryFails = true
        let c = controller("hello")
        await dictate(c)
        #expect(sentKeys.isEmpty)
        if case .error(let error) = c.state { #expect(error.kind == .deliveryFailed) } else { Issue.record("not an error") }
    }

    @Test func autoSendNeverFiresWhenTheTextWasOnlyCopiedBecauseTheTargetWasLost() async {
        focus = slack
        appFormatting.setAutoSend(.return, for: .workChat)
        reactivationSucceeds = false
        let c = controller("hello")
        c.toggle()
        focus = mail
        c.toggle()
        await c.awaitProcessing()
        #expect(deliveredModes == [.copy])
        #expect(sentKeys.isEmpty)
    }

    @Test func autoSendNeverFiresWhenTheLineBreakCopyHappened() async {
        focus = slack
        appFormatting.setAutoSend(.return, for: .workChat)
        await dictate(controller("one\ntwo", typeOutApps: ["com.tinyspeck.slackmacgap"]))
        #expect(deliveredModes == [.copy])
        #expect(sentKeys.isEmpty)
    }

    @Test func autoSendNeverFiresIfFocusLeftTheTargetAfterTheTextLanded() async {
        focus = slack
        appFormatting.setAutoSend(.return, for: .workChat)
        focusDuringDelivery = .some(mail)      // the user switched away as the paste finished
        let c = controller("hello")
        await dictate(c)
        #expect(deliveredModes == [.paste])
        #expect(sentKeys.isEmpty)
    }

    @Test func autoSendNeverFiresIfAnotherElementOfTheSameAppHasFocus() async {
        focus = slack
        appFormatting.setAutoSend(.return, for: .workChat)
        focusDuringDelivery = .some(DeliveryTarget(appID: slack.appID, appName: "Slack", processID: 501,
                                                   windowID: "win#1", elementID: "AXTextField#77"))
        await dictate(controller("hello"))
        #expect(sentKeys.isEmpty)
    }

    @Test func autoSendNeverFiresIfAnotherPageIsShownInTheTargetTab() async {
        let page = { (url: String) in
            DeliveryTarget(appID: "com.google.Chrome", appName: "Chrome", processID: 700, windowID: "win#6",
                           elementID: "AXTextArea#3", browserURL: url)
        }
        focus = page("https://app.slack.com/client/T1/C2")
        appFormatting.setAutoSend(.return, for: .workChat)
        focusDuringDelivery = .some(page("https://app.slack.com/client/T1/C9"))
        await dictate(controller("hello"))
        #expect(deliveredModes == [.paste])
        #expect(sentKeys.isEmpty)
    }

    @Test func autoSendNeverFiresWhileAPasswordFieldHasFocus() async {
        focus = slack
        appFormatting.setAutoSend(.return, for: .workChat)
        let c = DictationController(
            recorder: recorder, providers: { [self.provider("hello")] }, store: store,
            hint: { TranscriptionHint(languagePin: .auto, dictionaryWords: []) }, recordingsToKeep: 10,
            deliver: { [weak self] text, mode, done in
                self?.delivered.append(text)
                self?.secureInput = true      // a password field takes focus right after the paste
                done(.success(mode == .paste ? .pasted : .copied))
            },
            diagnostics: .memoryOnly,
            isSecureInputActive: { [weak self] in self?.secureInput ?? false },
            focusTarget: { [weak self] in self?.focus },
            appFormatting: { [weak self] in self?.appFormatting ?? .standard },
            sendKey: { [weak self] chord in self?.sentKeys.append(chord) })
        await dictate(c)
        #expect(delivered == ["hello"])
        #expect(sentKeys.isEmpty)
    }

    @Test func autoSendIsNeverPressedForAWindowDictation() async {
        appFormatting.setAutoSend(.return, for: .other)
        focus = slack
        await dictate(controller("hello"), source: .window)
        #expect(deliveredModes == [.copy])
        #expect(sentKeys.isEmpty)
    }

    @Test func autoSendPressesTheKeyBeforeTheOutcomeIsReported() async {
        focus = slack
        appFormatting.setAutoSend(.return, for: .workChat)
        var order: [String] = []
        let c = controller("hello")
        c.onOutcome = { [weak self] _ in order.append("outcome:\(self?.sentKeys.count ?? -1)") }
        await dictate(c)
        #expect(order == ["outcome:1"])
    }
}
