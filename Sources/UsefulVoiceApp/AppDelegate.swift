import AppKit
import AVFoundation
import ApplicationServices
import Carbon.HIToolbox
import UsefulVoiceCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    /// The menu bar menu and its header row (see MenuBarMenu).
    private var menuBar: MenuBarMenu?
    private let languagePicker = LanguagePickerPanel()
    private let settings = AppSettings()
    private let hotkeys = HotkeyManager()
    private let hud = HUDPanel()
    private let chimes = ChimePlayer()
    private let inserter = TextInserter()
    private let mainWindow = MainWindowController()
    private var viewModel: UsefulVoiceViewModel?
    private var firstRun: FirstRunModel?
    private var history: DictationHistory?
    private var usageStats: UsageStatsStore?
    private var languageMemory: LanguageMemoryStore?
    private var scratchpad: ScratchpadStore?
    private var controller: DictationController?
    /// Local transcription: the on-disk model directory, the whisper.cpp
    /// engine (lazily loads a context), and the cached provider for the
    /// currently selected model.
    private let modelStore = LocalModelStore()
    private let localEngine = WhisperCppEngine()
    private var modelManager: LocalModelManager?
    private var recordingTimer: Timer?
    /// The live recorder, for the countdown to auto-stop shown in the dock.
    private var audioRecorder: AudioRecorder?
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
    /// The hotkey and the menu bar item start a hotkey dictation (pasted into the
    /// app in front); the window's mic button passes `.window` (saved and copied).
    private func toggleDictation(source: DictationSource = .hotkey) {
        controller?.toggle(source: source)
    }

    /// Opens the language picker, anchored above the HUD capsule. Ignored while
    /// dictation is in flight so the language never changes out from under an
    /// active recording.
    ///
    /// This used to cycle English↔German in place. That cannot work once the
    /// catalogue has ten languages: tapping a key repeatedly is a poor way to reach
    /// the tenth, and it silently skipped the ones in between. The popup keeps the
    /// shortcut useful while making the choice explicit, and cancelling leaves the
    /// current language alone.
    private func switchLanguage() {
        guard !isDictationBusy else { return }
        languagePicker.show(
            anchor: hud.capsuleAnchor(),
            // Read lazily so the picker always reflects the live setting.
            current: { [weak self] in self?.settings.languagePin ?? .auto },
            onSelect: { [weak self] chosen in
                guard let self else { return }
                self.settings.languagePin = chosen
                self.viewModel?.refreshConfig()   // keep Home + Settings in sync
                self.menuBar?.syncLanguage()
                // Confirms the change in the HUD for 1 s (the HUD hides itself).
                self.hud.show(.language(chosen))
            }
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else installs an event tap: a second copy of the app
        // would fight this one for the hotkey (one press would toggle dictation
        // on and straight back off) and draw a second HUD pill. The duplicate is
        // reachable because `make run` leaves a live bundle in dist/ with the
        // same bundle identifier and signature as the /Applications copy.
        // An offscreen render (`UV_SNAPSHOT`) installs no event tap and adds no
        // status item, so it may run beside the copy the user is dictating with.
        let isSnapshot = ProcessInfo.processInfo.environment["UV_SNAPSHOT"] != nil
        if !isSnapshot, SingleInstance.yieldToExistingInstance() { return }
        // Settles the English default for new installs while an existing one
        // stays on Auto-detect. Must run before anything reads the language.
        // A forced first-run preview saves nothing, so it skips this too.
        if !FirstRunGate.isForced(environment: ProcessInfo.processInfo.environment) {
            settings.resolveLanguageDefault(hasPriorData: hasPriorData())
        }

        // Recorded before the key cache is primed, because priming can block
        // indefinitely on a keychain authorization dialog. It previously ran only
        // after the read returned, so a launch that hit a prompt produced no launch
        // record at all - the one case where a launch record is most useful.
        recordLaunchDiagnostic()
        Appearance.install(settings: settings)
        ThinScrollbar.install()
        installMainMenu()
        // An offscreen render (`UV_SNAPSHOT`) never needs the key's value, only
        // whether one exists, and reading it can raise a Keychain prompt in a
        // differently signed copy of the app.
        if ProcessInfo.processInfo.environment["UV_SNAPSHOT"] == nil { primeKeyCache() }
        chimes.isEnabled = { [settings] in settings.soundEffectsEnabled }
        setUpController()
        if !isSnapshot { setUpStatusItem() }
        setUpFirstRun()
        // `UV_SNAPSHOT=<png path>@<width>x<height>` renders the page named by
        // `UV_START_SECTION` to a PNG and quits, with no window and no focus change.
        if let spec = ProcessInfo.processInfo.environment["UV_SNAPSHOT"], let viewModel {
            let parts = spec.split(separator: "@")
            let dims = parts.last?.split(separator: "x").compactMap { Double($0) } ?? []
            guard parts.count == 2, dims.count == 2 else {
                fputs("UV_SNAPSHOT must look like /tmp/page.png@1280x860\n", stderr)
                exit(2)
            }
            let url = URL(fileURLWithPath: String(parts[0]))
            let size = NSSize(width: dims[0], height: dims[1])
            let appearance = Appearance.nsAppearance(for: settings.appearance)
            // `UV_HUD_STATE=<state>` renders the HUD (or the language picker) with
            // sample data, and `UV_MENU_HEADER=idle|recording` the menu bar header.
            if let state = ProcessInfo.processInfo.environment["UV_HUD_STATE"] {
                HUDSnapshot.render(state, size: size, appearance: appearance, to: url) { ok in
                    exit(ok ? 0 : 1)
                }
                return
            }
            if let header = ProcessInfo.processInfo.environment["UV_MENU_HEADER"] {
                MenuHeaderSnapshot.render(header, appearance: appearance, to: url) { ok in
                    exit(ok ? 0 : 1)
                }
                return
            }
            guard let firstRun else { exit(1) }
            mainWindow.snapshot(viewModel: viewModel, settings: settings, firstRun: firstRun,
                                size: NSSize(width: dims[0], height: dims[1]),
                                to: URL(fileURLWithPath: String(parts[0]))) { ok in
                exit(ok ? 0 : 1)
            }
            return
        }
        // While the first-run flow is up, it asks for each permission at its own
        // step, so nothing is requested here.
        let firstRunActive = firstRun?.active == true
        if !firstRunActive { requestPermissions() }
        startHotkeys()

        // Only open the window when the user asked for the app. A login-item or
        // restored-state launch must stay quiet in the menu bar: opening a
        // window here took focus with `activate(ignoringOtherApps: true)` on
        // every login, so the first keystrokes after logging in landed in
        // Useful Voice instead of the app the user was typing into.
        // The exception is first run: setup has to be seen, so the window opens
        // with the flow over it even on a login launch.
        if firstRunActive || LaunchReason.current(from: notification) == .userInitiated {
            openMainWindow()
        }
    }

    /// Whether this Mac has used the app before: history, usage stats or a
    /// stored Deepgram key. The key check is presence only, so it never prompts.
    private func hasPriorData() -> Bool {
        let folder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sadaa")
        let files = ["history.json", "usage-stats.json"]
        return files.contains { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            || Keychain.exists(account: DeepgramKeyStore.account)
    }

    /// Builds the first-run flow and wires it to the hotkey tap and the window.
    private func setUpFirstRun() {
        guard let viewModel else { return }
        let firstRun = FirstRunModel(settings: settings, viewModel: viewModel)
        firstRun.onAccessibilityGranted = { [weak self] in
            self?.accessibilityBecameTrusted()
        }
        mainWindow.onVisibilityChange = { [weak firstRun] visible in
            firstRun?.windowVisibilityChanged(visible)
        }
        mainWindow.onClose = { [weak firstRun] in
            firstRun?.windowClosed()
        }
        self.firstRun = firstRun
    }

    /// Accessibility was just granted in the first-run flow: start the tap now
    /// instead of waiting for the next poll tick.
    private func accessibilityBecameTrusted() {
        guard viewModel?.hotkeyActive != true else { return }
        if tryStartHotkeys() {
            axPollTimer?.invalidate()
            axPollTimer = nil
        } else {
            startAccessibilityPoll()
        }
    }

    /// Records one line describing this launch.
    ///
    /// Why: on a healthy install nothing is ever logged, so `diagnostics.log` would
    /// stay empty and could not answer the obvious first question - "which build was
    /// this, and was anything different about it?". One line per launch makes the log
    /// a usable timeline, and the file is capped, so this cannot grow without bound.
    ///
    /// Contains no user content: version, build, and two booleans.
    /// Facts known immediately at launch. Deliberately says nothing about the key,
    /// which is not known yet - see `recordKeyStateDiagnostic`.
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
                // "no key cached" on every launch - wrong every single time, which
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
        hotkeys.stop()
        // Cancel first: it shows "Cancelled", which the next line removes.
        if controller?.state == .recording {
            controller?.cancel()
        }
        hud.hideImmediately()
        viewModel?.flushPendingEdits()
        firstRun?.appWillTerminate()
        // Keep the bytes of any model download in flight: pause it so URLSession
        // hands back resume data, and give the write a bounded moment to land.
        modelManager?.pauseAllDownloads()
    }

    /// Frees the loaded whisper context only when it is no longer the active,
    /// usable model: that model was deleted, replaced by a fresh download or
    /// deactivated. Another model's download finishing or failing leaves the
    /// loaded context alone.
    private func unloadLocalEngineIfStale(after change: LocalModelManager.Change) {
        let active = modelManager?.activeModel ?? WhisperModelCatalog.default
        let activeURL = modelStore.fileURL(for: active)
        let activeUsable = modelStore.availability(of: active) == .usable
        let replacedURL: URL? = {
            if case .downloaded(let model) = change { return modelStore.fileURL(for: model) }
            return nil
        }()
        Task { [localEngine] in
            guard let loaded = await localEngine.loadedModelURL else { return }
            if loaded != activeURL || !activeUsable || loaded == replacedURL {
                await localEngine.unload()
            }
        }
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
        self.audioRecorder = recorder
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

        let usageStats = UsageStatsStore(
            fileURL: sadaaDir.appendingPathComponent("usage-stats.json"))
        // Seed once from existing history, but only when history was read cleanly.
        if history.loadOutcome.allowsWriting {
            usageStats.seedIfFresh(from: history.all())
        }
        self.usageStats = usageStats

        let languageMemory = LanguageMemoryMigrator.migrateIfNeeded(
            memoryURL: sadaaDir.appendingPathComponent("language-memory.json"),
            dictionaryURL: sadaaDir.appendingPathComponent("dictionary.json"),
            snippetsURL: sadaaDir.appendingPathComponent("snippets.json"))
        self.languageMemory = languageMemory

        let scratchpad = ScratchpadMigrator.migrateIfNeeded(
            scratchpadURL: sadaaDir.appendingPathComponent("scratchpad.json"),
            notesURL: sadaaDir.appendingPathComponent("notes.json"))
        self.scratchpad = scratchpad

        // Model directory is created and hardened once up front so the
        // Settings page and a first download never race its creation.
        modelStore.prepare()
        let modelManager = LocalModelManager(settings: settings, store: modelStore)
        modelManager.onModelsChanged = { [weak self] change in
            self?.unloadLocalEngineIfStale(after: change)
            self?.viewModel?.refreshConfig()
        }
        modelManager.onEngineChanged = { [weak self] engine in
            // Leaving local frees the whisper context now; it reloads on demand
            // if the user comes back.
            guard engine == .deepgram, let self else { return }
            Task { await self.localEngine.unload() }
        }
        self.modelManager = modelManager

        let viewModel = UsefulVoiceViewModel(
            settings: settings,
            history: history,
            usageStats: usageStats,
            languageMemory: languageMemory,
            scratchpad: scratchpad,
            models: modelManager,
            onToggle: { [weak self] source in self?.toggleDictation(source: source) })
        self.viewModel = viewModel

        let controller = DictationController(
            recorder: recorder,
            providers: { [weak self] in self?.buildProviders(showPartials: true) ?? [] },
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
            deliver: { [weak self] text, mode, done in
                switch mode {
                case .paste:
                    self?.inserter.deliver(text) { outcome in
                        if outcome == .clipboardOnly {
                            // The HUD shows "Copied. Press ⌘V to paste" from the outcome.
                            done(.success(.copiedNotPasted))
                        } else {
                            done(.success(.pasted))
                        }
                    }
                case .copy:
                    // Saved and copied: the clipboard is the destination, so
                    // nothing is pasted and the user's old clipboard is not
                    // restored over it.
                    if self?.inserter.copy(text) == true {
                        done(.success(.copied))
                    } else {
                        done(.failure(DeliveryFailure()))
                    }
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
                self.usageStats?.record(record)
                self.viewModel?.refreshUsage()
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
            isSecureInputActive: { IsSecureEventInputEnabled() },
            frontmostApp: {
                let app = NSWorkspace.shared.frontmostApplication
                return FrontmostApp(
                    id: app?.bundleIdentifier, name: app?.localizedName,
                    isSelf: app?.processIdentifier == ProcessInfo.processInfo.processIdentifier)
            }
        )
        controller.onStateChange = { [weak self] state in
            self?.render(state: state)
            self?.viewModel?.refreshState(state)
            self?.viewModel?.canRetry = self?.controller?.canRetry ?? false
            // After the view model, so an open menu shows the new Retry, fix and copy items.
            self?.menuBar?.refresh()
        }
        controller.onOutcome = { [weak self] outcome in
            self?.viewModel?.handle(outcome: outcome)
            self?.menuBar?.refresh()
            self?.showOutcome(outcome)
        }
        // The HUD pill's verb (Retry last recording, Open settings) runs the same
        // fix as the window and the menu.
        hud.onFix = { [weak self] fix in self?.viewModel?.perform(fix) }
        viewModel.onOpenWindow = { [weak self] in self?.openMainWindow() }
        viewModel.onRecordingsDeleted = { [weak self] in
            self?.controller?.discardRetainedAudio()
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
        viewModel.makeTranscriptionProvider = { [weak self] in
            self?.buildProviders().first
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
        // Reprocess in the language the dictation ran in, not whatever is
        // pinned now - a German record re-runs its German rules even if the
        // user has since switched to English. `resolvedPin` validates the
        // stored union: a stored `multi` re-sends `language=multi`, an
        // unknown stored code resolves to `.auto` (detect_language) rather
        // than being sent to the provider.
        let recordPin = record.resolvedPin ?? settings.languagePin
        let hint = transcriptionHint(languageMemory: languageMemory,
                                     languagePin: recordPin)
        let context = formattingContext(languageMemory: languageMemory,
                                        languagePin: recordPin)
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
        let chain = buildProviders()
        guard !chain.isEmpty else {
            viewModel?.reprocessHistoryTextOnly(record)
            hud.show(.error(HUDError(message: "No engine set up", fix: .openEngineSettings)))
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
            Diagnostics.shared.warning("reprocess", "reprocess failed: \(detail)")
            hud.show(.error(HUDError(message: "Reprocess failed")))
            return
        }

        guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hud.show(.error(HUDError(message: "No speech detected", symbol: "waveform.slash")))
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
            language: transcript.sanitizedDetectedLanguage ?? record.language,
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
        hud.show(.done(.reprocessed))
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

    private func transcriptionHint(languageMemory: LanguageMemoryStore,
                                   languagePin: LanguagePin) -> TranscriptionHint {
        TranscriptionHint(
            languagePin: languagePin,
            dictionaryWords: Self.dictionaryBiasWords(
                from: languageMemory.snapshot(),
                languagePin: languagePin
            )
        )
    }

    private func formattingContext(languageMemory: LanguageMemoryStore,
                                   languagePin: LanguagePin) -> FormattingContext {
        let memory = languageMemory.snapshot()
        return FormattingContext(
            appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            dictionaryWords: Self.dictionaryBiasWords(
                from: memory,
                languagePin: languagePin
            ),
            language: languagePin,
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

    /// Active transcription provider: the engine the user picked in Settings.
    ///
    /// Deliberately does NOT read the Keychain: this runs on the main actor
    /// inside the dictation pipeline, and a blocking keychain read there would
    /// stall the main run loop, which is where the global event tap lives.
    /// `DeepgramKeyStore` is primed off-main at launch and refreshed whenever the
    /// user saves the key in Settings.
    ///
    /// A local selection that cannot run (model missing or invalid) returns an
    /// `UnavailableProvider` rather than an empty chain, so the dictation fails
    /// with "download it in Settings" instead of the generic no-provider error.
    /// Local is never silently swapped for Deepgram - choosing it means no
    /// audio leaves the machine.
    private func buildProviders(showPartials: Bool = false) -> [TranscriptionProvider] {
        let model = modelManager?.activeModel ?? WhisperModelCatalog.default
        let plan = ProviderSelector.resolve(
            engine: settings.transcriptionEngine,
            deepgramKeyAvailable: !(DeepgramKeyStore.shared.current ?? "").isEmpty,
            localModel: model,
            localModelAvailability: modelStore.availability(of: model))
        switch plan {
        case .deepgram:
            guard let key = DeepgramKeyStore.shared.current, !key.isEmpty else {
                return []
            }
            return [DeepgramProvider(config: .init(
                apiKey: key,
                smartFormat: settings.formattingEnabled,
                spokenPunctuation: settings.spokenPunctuationEnabled))]
        case .local(let model):
            return [localProvider(for: model, showPartials: showPartials)]
        case .needsDeepgramKey:
            // Same outcome the Deepgram path always had: the chain is empty and
            // the controller reports "No transcription provider configured".
            return []
        case .needsModelDownload, .modelInvalid:
            let message = ProviderSelector.unavailableMessage(for: plan)
                ?? "Local transcription is not set up. Open Settings."
            return [UnavailableProvider(name: "Whisper (local)", message: message)]
        }
    }

    /// A local provider for `model`. Cheap to build (the engine and its loaded
    /// context are shared), so one is made per dictation: the live dictation
    /// passes `showPartials` to drive the HUD, reprocess and the health probe
    /// pass false, and partials can never leak from one call into another.
    private func localProvider(for model: WhisperModel, showPartials: Bool) -> LocalWhisperProvider {
        let onPartial: (@Sendable (String) -> Void)?
        if showPartials {
            onPartial = { [weak self] (text: String) in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard self?.controller?.state == .transcribing else { return }
                        self?.hud.show(.transcribing(partial: text, local: true))
                        self?.viewModel?.telemetry.setPartial(text)
                    }
                }
            }
        } else {
            onPartial = nil
        }
        return LocalWhisperProvider(
            model: model, engine: localEngine, store: modelStore,
            onPartialResult: onPartial)
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
        case .engineFailed(let detail):
            return detail
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
        // The first-run flow has its own Accessibility step, so no pill there.
        if firstRun?.active != true {
            hud.show(.error(HUDError(message: "Accessibility access is off", symbol: "hand.raised",
                                     fix: .openAccessibilitySettings)))
        }
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
        menuBar?.apply(state: state)
        switch state {
        case .idle:
            stopRecordingTimer()
            setIcon(tint: nil)
            // Done, cancelled and "copied" are shown by the outcome, which fires
            // just before this and ends on its own timer. Only a progress state
            // still on screen is cleared here.
            hud.hideIfProgress()
        case .recording:
            chimes.playStart()
            startRecordingTimer()
            setIcon(tint: .systemRed)
        case .transcribing:
            if lastDictationState == .recording { chimes.playStop() }
            stopRecordingTimer()
            setIcon(tint: .systemOrange)
            hud.show(.transcribing(partial: nil, local: settings.transcriptionEngine == .whisperLocal))
        case .delivering:
            hud.show(.delivering)
        case .error(let error):
            stopRecordingTimer()
            setIcon(tint: nil)
            // Stays until the next dictation starts, the pill's button or the x is
            // clicked, or 8 s pass. The fix stays in the window and the menu.
            hud.show(.error(HUDError(error)))
        }
    }

    /// The HUD for how a dictation ended: done (1,2 s), cancelled (1,5 s), or the
    /// copied-not-pasted notice (until the next dictation, a click or 8 s).
    private func showOutcome(_ outcome: DictationOutcome) {
        switch outcome {
        case .cancelled:
            hud.show(.cancelled)
        case .delivered(let words, let mode, _):
            switch mode {
            case .pasted: hud.show(.done(.inserted(words: words)))
            case .copied: hud.show(.done(.savedAndCopied(words: words)))
            case .copiedNotPasted: hud.show(.copiedNotPasted)
            }
        }
    }

    private func startRecordingTimer() {
        recordingStartedAt = Date()
        hud.show(.recording(seconds: 0, level: 0, stopsIn: nil))
        // Push the live mic level at ~30Hz so the wave's amplitude tracks speech
        // promptly (the bars ripple continuously on their own via TimelineView;
        // this keeps the loudness envelope responsive). The seconds field drives
        // the elapsed m:ss, recomputed from the start time each tick.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                let elapsed = Int(now.timeIntervalSince(self.recordingStartedAt ?? now))
                self.viewModel?.telemetry.tick(
                    elapsed: elapsed, level: self.currentLevel,
                    deadlines: self.audioRecorder?.autoStopDeadlines ?? .none, now: now)
                // "Stops in 5 s" for whichever automatic stop comes first.
                let stopsIn = [self.viewModel?.telemetry.silenceRemaining,
                               self.viewModel?.telemetry.maxRemaining].compactMap { $0 }.min()
                self.hud.show(.recording(seconds: elapsed, level: self.currentLevel, stopsIn: stopsIn))
                self.menuBar?.tick(seconds: elapsed, level: self.currentLevel)
            }
        }
        recordingTimer = timer
        // .common so the menu header's timer keeps counting while the menu is open
        // (the menu tracks in its own run-loop mode, where a default-mode timer freezes).
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
    }

    private func setIcon(tint: NSColor?) {
        statusItem?.button?.image = Self.statusItemImage(tint: tint)
        statusItem?.button?.contentTintColor = nil
    }

    /// The Landing mark as an 18 pt menu bar image (StatusItem.png and @2x in
    /// Resources). With no tint it is a template, so the menu bar colours it for
    /// light, dark and the highlighted state. With a tint (recording, transcribing)
    /// it is drawn in that colour and is not a template.
    /// Resolved once. A bare `swift run` has no bundle Resources: it falls back to
    /// a system glyph and logs it, rather than crashing the menu bar app.
    private static let statusMark: NSImage = {
        if let mark = NSImage(named: "StatusItem") { return mark }
        Diagnostics.shared.record(level: .warning, category: "launch",
                                  message: "StatusItem.png missing from Resources; using a system glyph")
        return NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage()
    }()

    private static func statusItemImage(tint: NSColor?) -> NSImage {
        let mark = statusMark.copy() as! NSImage
        mark.accessibilityDescription = "Useful Voice"
        guard let tint else {
            mark.isTemplate = true
            return mark
        }
        let tinted = NSImage(size: mark.size, flipped: false) { rect in
            mark.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.accessibilityDescription = "Useful Voice"
        tinted.isTemplate = false
        return tinted
    }

    // MARK: - Status item and menu

    private func setUpStatusItem() {
        guard let viewModel else { return }
        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength)
        item.button?.image = Self.statusItemImage(tint: nil)
        let menuBar = MenuBarMenu(
            settings: settings,
            viewModel: viewModel,
            actions: .init(
                toggleDictation: { [weak self] in self?.toggleDictation() },
                cancelDictation: { [weak self] in
                    if self?.controller?.state == .recording { self?.controller?.cancel() }
                },
                openMainWindow: { [weak self] in self?.openMainWindow() },
                openSettings: { [weak self] anchor in
                    // Open on Settings (UV-038): the window used to open on whatever
                    // section it had, for "Settings" too.
                    self?.openMainWindow()
                    self?.viewModel?.navigate(to: "settings", anchor: anchor)
                },
                copy: { [weak self] text in self?.inserter.copy(text) },
                setLanguage: { [weak self] pin in
                    self?.settings.languagePin = pin
                    self?.viewModel?.refreshConfig()   // keep the window in sync with the menu
                }))
        item.menu = menuBar.menu
        statusItem = item
        self.menuBar = menuBar
        // The controller already ran: show its current state, not "Ready".
        if let state = controller?.state { menuBar.apply(state: state) }
    }

    @objc private func openMainWindow() {
        if let viewModel, let firstRun {
            mainWindow.show(viewModel: viewModel, settings: settings, firstRun: firstRun)
        }
    }

    // MARK: - Permissions

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                DispatchQueue.main.async { [weak self] in
                    self?.hud.show(.error(HUDError(message: "Microphone access is off", symbol: "mic.slash",
                                                   fix: .openMicrophoneSettings)))
                }
            }
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue()
                       as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
