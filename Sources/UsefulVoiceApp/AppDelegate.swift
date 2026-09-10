import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import UsefulVoiceCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var formattingMenuItem: NSMenuItem?
    /// The three Language submenu items, kept so a hotkey switch can refresh
    /// their checkmarks without rebuilding the menu.
    private var languageMenuItems: [NSMenuItem] = []
    private let languagePicker = LanguagePickerPanel()
    private let settings = AppSettings()
    private let hotkeys = HotkeyManager()
    private let hud = HUDPanel()
    private let chimes = ChimePlayer()
    private let inserter = TextInserter()
    private let mainWindow = MainWindowController()
    private var viewModel: UsefulVoiceViewModel?
    private var history: DictationHistory?
    private var languageMemory: LanguageMemoryStore?
    private var scratchpad: ScratchpadStore?
    private var controller: DictationController?
    private var recordingTimer: Timer?
    /// When the current recording began, so the pill can show elapsed mm:ss.
    private var recordingStartedAt: Date?
    private var currentLevel: Float = 0
    private var axPollTimer: Timer?
    /// Previous dictation state, so the stop chime only plays when a recording
    /// actually ended (retryLast jumps straight to .transcribing).
    private var lastDictationState: DictationState = .idle

    /// A dictation is mid-flight (recording or processing).
    private var isDictationBusy: Bool {
        switch controller?.state {
        case .recording, .transcribing, .delivering: return true
        default: return false
        }
    }
    private func toggleDictation() {
        controller?.toggle()
    }

    /// Flips the dictation language between English and German and flashes the
    /// new language in the HUD. Ignored while dictation is in flight so the
    /// language never changes out from under an active recording.
    /// Opens the language picker.
    ///
    /// This used to cycle English↔German in place. That cannot work once the
    /// catalogue has ten languages: tapping a key repeatedly is a poor way to reach
    /// the tenth, and it silently skipped the ones in between. The popup keeps the
    /// shortcut useful while making the choice explicit, and cancelling leaves the
    /// current language alone.
    private func switchLanguage() {
        guard !isDictationBusy else { return }
        languagePicker.show(
            selection: settings.languagePin,
            onSelect: { [weak self] chosen in
                guard let self else { return }
                self.settings.languagePin = chosen
                self.viewModel?.refreshConfig()   // keep Home + Settings in sync
                self.syncLanguageMenu()
                // Confirms the change in the same pill the cycle used to use, so
                // the feedback is unchanged even though the interaction is new.
                self.hud.show(.language(chosen))
                self.hud.hide(after: 1.3)
            }
        )
    }

    /// Refreshes the Language submenu checkmarks to match the stored pin, used
    /// after a hotkey switch and whenever the menu is about to open.
    private func syncLanguageMenu() {
        for item in languageMenuItems {
            guard let raw = item.representedObject as? String else { continue }
            item.state = settings.languagePin.rawValue == raw ? .on : .off
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else installs an event tap: a second copy of the app
        // would fight this one for the hotkey (one press would toggle dictation
        // on and straight back off) and draw a second HUD pill. The duplicate is
        // reachable because `make run` leaves a live bundle in dist/ with the
        // same bundle identifier and signature as the /Applications copy.
        if SingleInstance.yieldToExistingInstance() { return }

        // Recorded before the key cache is primed, because priming can block
        // indefinitely on a keychain authorization dialog. It previously ran only
        // after the read returned, so a launch that hit a prompt produced no launch
        // record at all — the one case where a launch record is most useful.
        recordLaunchDiagnostic()
        ThinScrollbar.install()
        installMainMenu()
        primeKeyCache()
        chimes.isEnabled = { [settings] in settings.soundEffectsEnabled }
        setUpStatusItem()
        setUpController()
        requestPermissions()
        startHotkeys()

        // Only open the window when the user asked for the app. A login-item or
        // restored-state launch must stay quiet in the menu bar: opening a
        // window here took focus with `activate(ignoringOtherApps: true)` on
        // every login, so the first keystrokes after logging in landed in
        // Useful Voice instead of the app the user was typing into.
        if LaunchReason.current(from: notification) == .userInitiated {
            openMainWindow()
        }
    }

    /// Records one line describing this launch.
    ///
    /// Why: on a healthy install nothing is ever logged, so `diagnostics.log` would
    /// stay empty and could not answer the obvious first question — "which build was
    /// this, and was anything different about it?". One line per launch makes the log
    /// a usable timeline, and the file is capped, so this cannot grow without bound.
    ///
    /// Contains no user content: version, build, and two booleans.
    /// Facts known immediately at launch. Deliberately says nothing about the key,
    /// which is not known yet — see `recordKeyStateDiagnostic`.
    private func recordLaunchDiagnostic() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let loginItem = LoginItem.isEnabled ? "starts at login" : "manual start"
        Diagnostics.shared.info(
            "launch",
            "Useful Voice \(version) (\(build)) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString); \(loginItem)",
        )
    }

    /// Recorded once the keychain read resolves, which may be never.
    ///
    /// A missing record is therefore itself the signal: it means the read never
    /// returned, which in practice means a keychain authorization dialog is still
    /// on screen. That is worth being able to see, because while that dialog is up
    /// every dictation fails with "no transcription provider configured" and the
    /// cause is invisible from inside the app.
    private func recordKeyStateDiagnostic() {
        // Distinguishes "no key stored" from "a key is stored but could not be
        // read", which the pre-lookup API collapsed into one unhelpful value.
        let store = DeepgramKeyStore.shared
        if store.current != nil {
            Diagnostics.shared.info("keychain", "Deepgram key loaded")
        } else if let problem = store.lookupProblem {
            Diagnostics.shared.warning(
                "keychain",
                "a Deepgram key is stored but could not be read (\(problem)); dictation will ask for a key until the keychain grants access",
            )
        } else {
            Diagnostics.shared.info("keychain", "no Deepgram key configured")
        }
    }

    /// Warms the Deepgram key cache off the main thread.
    ///
    /// The read can block on securityd, and on the first run after a re-signed
    /// reinstall it can put up an authorization prompt. Doing it here, on a
    /// background thread, keeps both app launch and the event tap responsive.
    private func primeKeyCache() {
        DispatchQueue.global(qos: .userInitiated).async {
            DeepgramKeyStore.shared.load()
            DispatchQueue.main.async { [weak self] in
                self?.viewModel?.refreshConfig()
                // The key state is recorded separately, once it is actually known.
                // It cannot be part of the launch line: the read is asynchronous and
                // can block on a keychain prompt, so reading it there reported
                // "no key cached" on every launch — wrong every single time, which
                // is worse than no line at all. And this callback never runs at all
                // while a prompt is unanswered, which is why the key state is its
                // own record rather than a field on the launch record.
                self?.recordKeyStateDiagnostic()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    /// AppKit asks for this on macOS 14+ when the process takes part in state
    /// restoration; without it every launch logs "Secure coding is not enabled
    /// for restorable state!". The app keeps no restorable state of its own, so
    /// answering yes is both correct and quiet.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Returning from System Settings is the most likely moment for a grant to
    /// have changed, so re-check both the Accessibility tap and the microphone.
    func applicationDidBecomeActive(_ notification: Notification) {
        if viewModel?.hotkeyActive == false || axPollTimer != nil {
            startAccessibilityPoll()
        }
    }

    /// Tear down deterministically: an in-flight recording is discarded rather
    /// than left as a truncated WAV, and timers/tap stop before the process dies.
    func applicationWillTerminate(_ notification: Notification) {
        axPollTimer?.invalidate()
        axPollTimer = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        hud.hideImmediately()
        hotkeys.stop()
        if controller?.state == .recording {
            controller?.cancel()
        }
        viewModel?.flushPendingEdits()
    }

    /// Useful Voice is an accessory app, so no menu bar is visible, but AppKit still
    /// routes key equivalents through NSApp.mainMenu. Without an Edit menu,
    /// Cmd-V (the user's or TextInserter's synthetic one) dies inside Useful Voice's
    /// own windows, so dictating into the Scratchpad lost the text.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Useful Voice",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",
                         action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Wiring

    private func setUpController() {
        let recorder = AudioRecorder(silenceTimeout: settings.silenceTimeout)
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.currentLevel = level }
        }
        let sadaaDir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sadaa")
        let appSupport = sadaaDir.appendingPathComponent("Recordings")
        // Never trap here. A failed app-support directory (full disk, managed
        // Mac, permission change) must not turn launch-at-login into an
        // invisible crash loop; RecordingStore.make falls back to a temporary
        // directory and the app stays usable.
        let store = RecordingStore.make(directory: appSupport)

        try? FileManager.default.createDirectory(
            at: sadaaDir, withIntermediateDirectories: true)
        // Owner-only. The directory is created with the process umask (022 on a
        // default macOS install), which would make the dictionary, the full
        // dictation history and the retained recordings readable by every other
        // account on the machine. This also corrects files written by an earlier
        // build, and directories restored from a backup (modes are not preserved).
        FileProtection.restrictRecursively(sadaaDir)
        let history = DictationHistory(
            fileURL: sadaaDir.appendingPathComponent("history.json"))
        self.history = history

        let languageMemory = LanguageMemoryMigrator.migrateIfNeeded(
            memoryURL: sadaaDir.appendingPathComponent("language-memory.json"),
            dictionaryURL: sadaaDir.appendingPathComponent("dictionary.json"),
            snippetsURL: sadaaDir.appendingPathComponent("snippets.json"))
        self.languageMemory = languageMemory

        let scratchpad = ScratchpadMigrator.migrateIfNeeded(
            scratchpadURL: sadaaDir.appendingPathComponent("scratchpad.json"),
            notesURL: sadaaDir.appendingPathComponent("notes.json"))
        self.scratchpad = scratchpad

        let viewModel = UsefulVoiceViewModel(
            settings: settings,
            history: history,
            languageMemory: languageMemory,
            scratchpad: scratchpad,
            onToggle: { [weak self] in self?.toggleDictation() })
        self.viewModel = viewModel

        let controller = DictationController(
            recorder: recorder,
            providers: { [settings] in Self.buildProviders(settings: settings) },
            store: store,
            hint: { [settings, languageMemory] in
                TranscriptionHint(
                    languagePin: settings.languagePin,
                    dictionaryWords: Self.dictionaryBiasWords(
                        from: languageMemory.snapshot(),
                        languagePin: settings.languagePin
                    )
                )
            },
            recordingsToKeep: settings.recordingsToKeep,
            deliver: { [weak self] text, done in
                self?.inserter.deliver(text) { outcome in
                    if outcome == .clipboardOnly {
                        self?.hud.show(.error("Copied. Press Cmd-V to paste."))
                        self?.hud.hide(after: 4)
                    }
                    done()
                }
            },
            record: { [weak self] record in
                guard let self else { return }
                self.languageMemory?.recordUsage(
                    termIDs: record.memoryHitIDs ?? [],
                    replacementRuleIDs: record.replacementRuleIDs ?? [],
                    snippetIDs: record.snippetIDs ?? []
                )
                self.history?.append(record)
                self.viewModel?.refreshLanguageMemory()
                self.viewModel?.refreshRecent()
            },
            format: { [languageMemory] raw, ctx in
                // Deepgram's smart_format handles punctuation and casing during
                // transcription. Here we only apply the deterministic local
                // Language Memory corrections (dictionary, replacements, snippets).
                let memory = languageMemory.snapshot()
                let memoryLanguage = MemoryLanguage(languagePin: ctx.language)
                let prepared = LanguageMemoryPostProcessor.applyDeterministic(
                    to: raw,
                    snapshot: memory,
                    language: memoryLanguage)
                return LanguageMemoryPostProcessor.rawResult(from: prepared)
            },
            rawTransform: { [languageMemory] raw, ctx in
                LanguageMemoryPostProcessor.rawResult(
                    for: raw,
                    snapshot: languageMemory.snapshot(),
                    language: MemoryLanguage(languagePin: ctx.language)
                )
            },
            context: { [settings, languageMemory] in
                let memory = languageMemory.snapshot()
                return FormattingContext(
                    appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                    dictionaryWords: Self.dictionaryBiasWords(
                        from: memory,
                        languagePin: settings.languagePin
                    ),
                    language: settings.languagePin,
                    snippets: Self.snippets(from: memory),
                    replacementRules: memory.replacements)
            },
            suggestTerms: { [weak self] terms in
                self?.languageMemory?.suggest(terms)
                self?.viewModel?.refreshLanguageMemory()
            },
            isSecureInputActive: { IsSecureEventInputEnabled() }
        )
        controller.onStateChange = { [weak self] state in
            self?.render(state: state)
            self?.viewModel?.refreshState(state)
            self?.viewModel?.canRetry = self?.controller?.canRetry ?? false
        }
        viewModel.onRetry = { [weak self] in
            self?.controller?.retryLast()
        }
        viewModel.onReprocessHistory = { [weak self] record in
            self?.reprocessHistory(record)
        }
        viewModel.onRecordingSettingsChange = { [weak controller] silenceTimeout, recordingsToKeep in
            controller?.updateRecordingSettings(
                silenceTimeout: silenceTimeout,
                recordingsToKeep: recordingsToKeep
            )
        }
        self.controller = controller
    }

    private func reprocessHistory(_ record: DictationRecord) {
        guard let audioPath = record.audioPath,
              FileManager.default.fileExists(atPath: audioPath),
              let languageMemory
        else {
            viewModel?.reprocessHistoryTextOnly(record)
            return
        }

        let audioURL = URL(fileURLWithPath: audioPath)
        let hint = transcriptionHint(languageMemory: languageMemory)
        let context = formattingContext(languageMemory: languageMemory)
        Task { [weak self] in
            await self?.reprocessHistoryAudio(
                record: record,
                audioURL: audioURL,
                hint: hint,
                context: context,
                languageMemory: languageMemory
            )
        }
    }

    private func reprocessHistoryAudio(record: DictationRecord,
                                       audioURL: URL,
                                       hint: TranscriptionHint,
                                       context: FormattingContext,
                                       languageMemory: LanguageMemoryStore) async {
        let chain = Self.buildProviders(settings: settings)
        guard !chain.isEmpty else {
            viewModel?.reprocessHistoryTextOnly(record)
            hud.show(.error("No provider configured. Reprocessed with local memory only."))
            hud.hide(after: 4)
            return
        }

        var transcript: Transcript?
        var usedProvider: String?
        var lastError: Error?
        for provider in chain {
            do {
                transcript = try await provider.transcribe(audio: audioURL, hint: hint)
                usedProvider = provider.name
                break
            } catch {
                lastError = error
            }
        }

        guard let transcript else {
            let detail = (lastError as? ProviderError).map(Self.describeProviderError)
                ?? lastError?.localizedDescription ?? "unknown error"
            hud.show(.error("Reprocess failed: \(detail)"))
            hud.hide(after: 5)
            return
        }

        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hud.show(.error("Reprocess returned no speech."))
            hud.hide(after: 4)
            return
        }

        let formatted = await formatForHistoryReprocess(
            raw: transcript.text,
            context: context,
            languageMemory: languageMemory
        )
        let reprocessed = DictationRecord(
            text: formatted.text,
            createdAt: Date(),
            language: transcript.detectedLanguage ?? record.language,
            provider: "\(usedProvider ?? record.provider) reprocess",
            durationSeconds: transcript.durationSeconds ?? record.durationSeconds,
            mode: formatted.mode,
            rawText: transcript.text,
            intermediateText: record.text,
            modelDeployment: nil,
            memoryHitIDs: formatted.memoryHitIDs.isEmpty ? nil : formatted.memoryHitIDs,
            replacementRuleIDs: formatted.replacementRuleIDs.isEmpty ? nil : formatted.replacementRuleIDs,
            snippetIDs: formatted.snippetIDs.isEmpty ? nil : formatted.snippetIDs,
            audioPath: audioURL.path
        )
        languageMemory.recordUsage(
            termIDs: formatted.memoryHitIDs,
            replacementRuleIDs: formatted.replacementRuleIDs,
            snippetIDs: formatted.snippetIDs
        )
        history?.append(reprocessed)
        viewModel?.refreshLanguageMemory()
        viewModel?.refreshRecent()
        hud.show(.done)
        hud.hide(after: 1.0)
    }

    private func formatForHistoryReprocess(raw: String,
                                           context: FormattingContext,
                                           languageMemory: LanguageMemoryStore) async -> FormattingResult {
        let memory = languageMemory.snapshot()
        let memoryLanguage = MemoryLanguage(languagePin: context.language)
        let prepared = LanguageMemoryPostProcessor.applyDeterministic(
            to: raw,
            snapshot: memory,
            language: memoryLanguage
        )
        return LanguageMemoryPostProcessor.rawResult(from: prepared)
    }

    private func transcriptionHint(languageMemory: LanguageMemoryStore) -> TranscriptionHint {
        TranscriptionHint(
            languagePin: settings.languagePin,
            dictionaryWords: Self.dictionaryBiasWords(
                from: languageMemory.snapshot(),
                languagePin: settings.languagePin
            )
        )
    }

    private func formattingContext(languageMemory: LanguageMemoryStore) -> FormattingContext {
        let memory = languageMemory.snapshot()
        return FormattingContext(
            appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            dictionaryWords: Self.dictionaryBiasWords(
                from: memory,
                languagePin: settings.languagePin
            ),
            language: settings.languagePin,
            snippets: Self.snippets(from: memory),
            replacementRules: memory.replacements
        )
    }

    /// Deepgram keyterm budget. Correct spellings only (terms, correction
    /// targets, snippet triggers, base vocabulary). Pronunciations stay local.
    private static let dictionaryBiasBudget = 100

    private static func dictionaryBiasWords(from memory: LanguageMemorySnapshot,
                                            languagePin: LanguagePin) -> [String] {
        MemoryBiasBuilder.biasList(
            terms: memory.terms,
            baseVocabulary: BaseVocabulary.terms,
            budget: dictionaryBiasBudget,
            language: MemoryLanguage(languagePin: languagePin),
            replacements: memory.replacements,
            snippets: memory.snippets
        )
    }

    private static func snippets(from memory: LanguageMemorySnapshot) -> [Snippet] {
        memory.snippets
            .filter(\.isEnabled)
            .map { Snippet(id: $0.id, trigger: $0.trigger, expansion: $0.expansion) }
    }

    /// Active transcription provider: Deepgram Nova-3, keyed from the in-memory
    /// key cache.
    ///
    /// Deliberately does NOT read the Keychain: this runs on the main actor
    /// inside the dictation pipeline, and a blocking keychain read there would
    /// stall the main run loop, which is where the global event tap lives.
    /// `DeepgramKeyStore` is primed off-main at launch and refreshed whenever the
    /// user saves the key in Settings.
    private static func buildProviders(settings: AppSettings)
        -> [TranscriptionProvider] {
        guard let key = DeepgramKeyStore.shared.current, !key.isEmpty else {
            return []
        }
        return [DeepgramProvider(config: .init(
            apiKey: key,
            smartFormat: settings.formattingEnabled,
            spokenPunctuation: settings.spokenPunctuationEnabled))]
    }

    private static func describeProviderError(_ error: ProviderError) -> String {
        switch error {
        case .http(let status, let body):
            let detail = ProviderHealthCheck.sanitize(
                body.trimmingCharacters(in: .whitespacesAndNewlines)
            ).prefix(200)
            return detail.isEmpty ? "HTTP \(status) from provider"
                                  : "HTTP \(status): \(detail)"
        case .outOfCredits:
            return "Your Deepgram account is out of credits. Add credits, then try again."
        case .badResponse:
            return "unreadable provider response"
        case .notConfigured(let what):
            return what
        case .timedOut:
            return "timed out"
        case .transport(let urlError):
            return urlError.localizedDescription
        }
    }

    private func startHotkeys() {
        hotkeys.activationKeycode = Int64(settings.hotkeyKeycode)
        viewModel?.onHotkeyKeycodeChange = { [weak self] code in
            self?.hotkeys.activationKeycode = Int64(code)
        }
        hotkeys.languageSwitchKeycode = Int64(settings.languageSwitchKeycode)
        viewModel?.onLanguageSwitchKeycodeChange = { [weak self] code in
            self?.hotkeys.languageSwitchKeycode = Int64(code)
        }
        hotkeys.onLanguageSwitch = { [weak self] in self?.switchLanguage() }
        hotkeys.onToggle = { [weak self] in
            self?.toggleDictation()
        }
        hotkeys.onCancel = { [weak self] in
            if self?.controller?.state == .recording {
                self?.controller?.cancel()
            }
        }

        // The tap died: usually the Accessibility grant was revoked while the app
        // was running, or a system event killed the tap. Without this the hotkey
        // goes silently dead while the UI still reports "Hotkeys active".
        hotkeys.onTapDisabled = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.viewModel?.hotkeyActive = false
                    self.hotkeys.stop()
                    self.startAccessibilityPoll()
                }
            }
        }

        // Gate on real trust first. CGEvent.tapCreate returns a non-nil but
        // DEAD tap when the process is not Accessibility-trusted, so checking
        // tap != nil is not enough - we would early-return and never start the
        // poll, leaving the hotkey dead until a full relaunch.
        if AXIsProcessTrusted() && tryStartHotkeys() { return }

        // Not Accessibility-trusted yet. Poll until the user grants it, then
        // start the tap without requiring a relaunch.
        hud.show(.error("Enable Accessibility for Useful Voice in System Settings to use the hotkey."))
        hud.hide(after: 6)
        startAccessibilityPoll()
    }

    /// Polls for Accessibility trust until the tap can start.
    ///
    /// Called both at launch and whenever the tap is torn down (for example after
    /// the grant is revoked mid-session), so re-granting recovers without a
    /// relaunch in every direction.
    private func startAccessibilityPoll() {
        guard axPollTimer == nil else { return }
        axPollTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard AXIsProcessTrusted() else { return }
                if self.tryStartHotkeys() {
                    self.axPollTimer?.invalidate()
                    self.axPollTimer = nil
                }
            }
        }
        if let axPollTimer {
            // .common so the poll keeps ticking while a menu is open or a window
            // is being dragged, which are exactly when a user returns from
            // System Settings.
            RunLoop.main.add(axPollTimer, forMode: .common)
        }
    }

    /// Attempts to start the global hotkey tap. Returns true on success, and
    /// publishes the active state so the Settings UI reflects reality.
    @discardableResult
    private func tryStartHotkeys() -> Bool {
        do {
            try hotkeys.start()
            viewModel?.hotkeyActive = true
            return true
        } catch {
            viewModel?.hotkeyActive = false
            return false
        }
    }

    // MARK: - State rendering

    private func render(state: DictationState) {
        defer { lastDictationState = state }
        // Publish to the tap thread whether Esc belongs to us. Set here rather
        // than read from a closure so the tap thread never touches main-actor
        // state directly.
        hotkeys.isRecordingActive = (state == .recording)
        switch state {
        case .idle:
            stopRecordingTimer()
            setIcon("waveform", tint: nil)
            if lastDictationState == .delivering {
                // A dictation just landed: flash a brief success confirmation
                // before the pill fades out, the way WhisperFlow and friends do.
                hud.show(.done)
                hud.hide(after: 1.0)
            } else {
                hud.hide(after: 0.4)
            }
        case .recording:
            chimes.playStart()
            startRecordingTimer()
            setIcon("record.circle.fill", tint: .systemRed)
        case .transcribing:
            if lastDictationState == .recording { chimes.playStop() }
            stopRecordingTimer()
            setIcon("waveform", tint: .systemOrange)
            hud.show(.transcribing)
        case .delivering:
            hud.show(.delivering)
        case .error(let message):
            stopRecordingTimer()
            setIcon("waveform", tint: nil)
            hud.show(.error(message))
            hud.hide(after: 6)
        }
    }

    private func startRecordingTimer() {
        recordingStartedAt = Date()
        hud.show(.recording(seconds: 0, level: 0))
        // Push the live mic level at ~30Hz so the wave's amplitude tracks speech
        // promptly (the bars ripple continuously on their own via TimelineView;
        // this keeps the loudness envelope responsive). The seconds field drives
        // the pill's elapsed mm:ss, recomputed from the start time each tick.
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                              repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = Int(Date().timeIntervalSince(self.recordingStartedAt ?? Date()))
                self.hud.show(.recording(seconds: elapsed, level: self.currentLevel))
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
    }

    private func setIcon(_ symbol: String, tint: NSColor?) {
        let image = NSImage(systemSymbolName: symbol,
                            accessibilityDescription: "Useful Voice")
        image?.isTemplate = (tint == nil)
        statusItem?.button?.image = image
        statusItem?.button?.contentTintColor = tint
    }

    // MARK: - Status item and menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform",
                                     accessibilityDescription: "Useful Voice")
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open Useful Voice",
                                  action: #selector(openMainWindow),
                                  keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: "Start/Stop Dictation",
                                    action: #selector(menuToggle),
                                    keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        // Every language the catalogue offers, not the two the enum used to have.
        // A menu bar menu scrolls natively, so unlike the settings popover it needs
        // no height cap of its own.
        let languageMenu = NSMenu()
        languageMenuItems = []
        for pin in LanguagePin.allCases {
            let item = NSMenuItem(title: pin.displayName,
                                  action: #selector(setLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = pin.rawValue
            item.state = settings.languagePin == pin ? .on : .off
            languageMenu.addItem(item)
            languageMenuItems.append(item)
        }
        let languageItem = NSMenuItem(title: "Language",
                                      action: nil, keyEquivalent: "")
        menu.setSubmenu(languageMenu, for: languageItem)
        menu.addItem(languageItem)

        // Quick auto-format switch, mirrors the Settings toggle. When off,
        // Deepgram's smart_format is disabled and transcripts come back raw.
        let formattingItem = NSMenuItem(title: "Auto-format transcript",
                                        action: #selector(toggleSmartFormatting),
                                        keyEquivalent: "")
        formattingItem.target = self
        formattingItem.state = settings.formattingEnabled ? .on : .off
        menu.addItem(formattingItem)
        formattingMenuItem = formattingItem

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openMainWindow),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Useful Voice",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Keep the menu's checkmarks in sync with settings each time it opens, so a
    /// change made on the Settings page is reflected here too.
    func menuWillOpen(_ menu: NSMenu) {
        formattingMenuItem?.state = settings.formattingEnabled ? .on : .off
        syncLanguageMenu()
    }

    @objc private func menuToggle() {
        toggleDictation()
    }

    @objc private func toggleSmartFormatting() {
        // Off = raw transcript, Deepgram's smart_format is disabled.
        // Takes effect on the next dictation (the provider is built per use).
        settings.formattingEnabled.toggle()
        formattingMenuItem?.state = settings.formattingEnabled ? .on : .off
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let pin = LanguagePin(code: raw)
        settings.languagePin = pin
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
        viewModel?.refreshConfig()   // keep Home + Settings in sync with the menu
    }

    @objc private func openMainWindow() {
        if let viewModel {
            mainWindow.show(viewModel: viewModel, settings: settings)
        }
    }

    // MARK: - Permissions

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async { [weak self] in
                    self?.hud.show(.error(
                        "Enable Microphone for Useful Voice in System Settings."))
                    self?.hud.hide(after: 6)
                }
            }
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue()
                       as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
