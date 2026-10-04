import AppKit
import AVFoundation
import ApplicationServices
import Combine
import SwiftUI
import UsefulVoiceCore

/// Drives the first-run flow: which page is showing, what each page has done,
/// and every side effect (settings, Keychain, downloads, permission polling).
///
/// Failure modes, and where each is handled:
/// - Key check: a refused key (401/403) and a network failure are different
///   messages (`KeyCheck.rejected` / `.network`); anything else shows a short
///   reason. Nothing is saved unless the check passes.
/// - Download: failed, stopped or cancelled shows the stopped state with Resume
///   (partial data is kept by the downloader); a full disk is caught before the
///   download starts and again from the failure text.
/// - Switching engine mid-download: choosing Deepgram or the other model pauses
///   the running download first.
/// - Half-saved engine: picking a Whisper row only starts its download. Continue
///   on the download page commits the engine and that model, even while the file
///   is still coming down. Cancel, Back, closing the window or Close from
///   Settings drop the choice and put the engine back to what it was when the
///   flow opened (unless the committed model already works). Nothing switches
///   the engine after the flow ends, so a later Settings choice is never undone.
/// - Microphone denied, then granted while the step is open: a one-second poll
///   moves on by itself.
/// - Accessibility granted while the app is in the background: the same poll
///   runs on the main run loop in `.common` mode, and activation re-checks.
/// - Window closed mid-flow: `completed` is only written on Done or Finish, so
///   the flow opens again next launch. The meter stops when the window hides.
/// - Practice dictation fails: the pipeline's own error text shows and Retry
///   re-runs the last audio.
@MainActor
final class FirstRunModel: ObservableObject {
    enum Page: Int, CaseIterable {
        case welcome, engine, deepgramKey, localDownload, microphone, accessibility, tryIt, done
    }

    /// A state a screenshot can jump straight to.
    enum Preview: String {
        case errKey, errDownload, errMic, tryItDone, tryItDownloading, accessibilityOn
    }

    enum KeyCheck: Equatable {
        case idle
        case checking
        case rejected
        case network
        case failed(String)
        /// The key passed the check but the Keychain write failed.
        case saveFailed
    }

    enum MicStatus: Equatable {
        case notDetermined, authorized, denied
    }

    // MARK: - Published state

    @Published private(set) var active: Bool
    @Published private(set) var page: Page = .welcome
    /// Bumped when the flow ends, so the window can land on Dictate.
    @Published private(set) var finishCount = 0
    /// Opened from Settings "Run setup again": it can be closed without finishing.
    @Published private(set) var startedFromSettings = false

    // Engine
    @Published var keyText = ""
    @Published private(set) var keyCheck: KeyCheck = .idle
    /// The Keychain write is running. It cannot be cancelled, so the key field,
    /// Connect, Keep current key and the Whisper rows are off until it returns.
    @Published private(set) var savingKey = false
    /// A key is saved (or, in a forced run, the check passed this run).
    @Published private(set) var keyConnected = false
    @Published var changingKey = false
    /// Bumped to ask the key field to take focus (after the Claim round trip).
    @Published private(set) var focusKeyRequest = 0
    @Published private(set) var selectedModel: WhisperModel = WhisperModelCatalog.default

    // Microphone
    @Published private(set) var micStatus: MicStatus = .notDetermined
    /// Separate object so only the meter redraws at audio rate.
    let meterLevels = MicLevels()
    @Published private(set) var micDeviceName = "Microphone"

    // Accessibility
    @Published private(set) var accessibilityGranted = false

    // Try it
    @Published var practiceText = ""
    @Published private(set) var practiceWorked = false

    static let meterBars = 24

    // MARK: - Configuration

    let forced: Bool
    /// A screenshot jump: polling, auto-advance and hardware are off so the
    /// page stays exactly as asked.
    let frozen: Bool
    let preview: Preview?
    /// Offscreen render: never touches the microphone.
    private let offscreen: Bool

    private let settings: AppSettings
    let viewModel: UsefulVoiceViewModel
    private let defaults: UserDefaults

    /// Called when Accessibility becomes trusted, so the app layer can start
    /// the hotkey tap without waiting for its own poll.
    var onAccessibilityGranted: (() -> Void)?

    // MARK: - Private

    private var pollTimer: Timer?
    private var checkTask: Task<Void, Never>?
    private var advanceWork: DispatchWorkItem?
    private var meter: MicLevelMeter?
    private var windowVisible = true
    private var meterConfigObserver: AnyCancellable?
    /// A failed meter start is not retried before this, so the 1 s poll does not
    /// hammer a device that will not open.
    private var meterRetryAfter = Date.distantPast
    private var lastLevelPush = Date.distantPast
    /// The key a running check is for, so editing the field cancels it.
    private var keyUnderCheck: String?
    /// What the app was set to when the flow opened.
    private var snapshot: FirstRunGate.EngineSelection
    /// The Whisper model the flow is downloading for. Set when a row is picked and
    /// cleared when the flow ends, so it never outlives the flow.
    private var pendingLocal: WhisperModel?
    /// Forced runs save nothing, so a language or key picked in Try it is shown
    /// from these instead.
    @Published private var previewLanguage: LanguagePin?
    @Published private var previewHotkey: Int?
    private var recentBaseline: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var awaitingClaim = false
    /// Where the current download's rate is measured from.
    private(set) var downloadStart: (time: Date, bytes: Int64)?

    /// Called as bytes arrive; the first sample anchors the time-left estimate.
    func noteProgress(received: Int64) {
        guard received > 0, downloadStart == nil else { return }
        downloadStart = (Date(), received)
    }

    // MARK: - Init

    init(settings: AppSettings,
         viewModel: UsefulVoiceViewModel,
         defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.settings = settings
        self.viewModel = viewModel
        self.defaults = defaults
        let forced = FirstRunGate.isForced(environment: environment)
        self.forced = forced
        self.offscreen = environment["UV_SNAPSHOT"] != nil

        self.snapshot = FirstRunGate.EngineSelection(
            engine: settings.transcriptionEngine, modelID: settings.localModelID)
        // Key PRESENCE (attributes only, never prompts) or a usable local model.
        // Never the key cache, which may not have loaded yet, and a stored key
        // that cannot be read right now still counts as configured.
        let decision = FirstRunGate.decide(
            completed: defaults.bool(forKey: FirstRunGate.completedKey),
            engineConfigured: FirstRunGate.engineConfigured(
                engine: settings.transcriptionEngine,
                keyStored: Keychain.exists(account: DeepgramKeyStore.account),
                activeModelUsable: viewModel.models.availability(
                    of: viewModel.models.activeModel) == .usable),
            microphoneAuthorized: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityTrusted: AXIsProcessTrusted(),
            forced: forced)
        if decision == .skipAndMarkCompleted {
            defaults.set(true, forKey: FirstRunGate.completedKey)
        }
        self.active = decision == .show

        var start: Page = .welcome
        var preview: Preview?
        if decision == .show, let name = environment["UV_FIRST_RUN_STEP"],
           let jump = Self.jump(named: name) {
            start = jump.page
            preview = jump.preview
        }
        self.page = start
        self.preview = preview
        self.frozen = decision == .show && environment["UV_FIRST_RUN_STEP"].flatMap(Self.jump(named:)) != nil

        // A forced run pretends to be a new Mac: whatever key is really saved
        // does not count, so the claim card shows as designed.
        keyConnected = forced ? false : Keychain.exists(account: DeepgramKeyStore.account)
        applyPreview()
        if active { enter(start) }

        viewModel.$recent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recent in self?.recentChanged(recent) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.appBecameActive() }
            }
            .store(in: &cancellables)
    }

    private static func jump(named name: String) -> (page: Page, preview: Preview?)? {
        switch name {
        case "welcome": return (.welcome, nil)
        case "engine": return (.engine, nil)
        case "deepgramKey": return (.deepgramKey, nil)
        case "localDownload": return (.localDownload, nil)
        case "microphone": return (.microphone, nil)
        case "accessibility": return (.accessibility, nil)
        case "tryIt": return (.tryIt, nil)
        case "tryItDone": return (.tryIt, .tryItDone)
        case "tryItDownloading": return (.tryIt, .tryItDownloading)
        case "done": return (.done, nil)
        case "errKey": return (.engine, .errKey)
        case "errDownload": return (.localDownload, .errDownload)
        case "errMic": return (.microphone, .errMic)
        case "accessibilityOn": return (.accessibility, .accessibilityOn)
        default: return nil
        }
    }

    /// Fills in the sample data a screenshot page needs.
    private func applyPreview() {
        guard frozen else { return }
        if page == .deepgramKey { keyConnected = true }
        if preview == .errKey {
            keyText = "3f9a1c7e5b2d8a64f0c1"
            keyCheck = .rejected
        }
        if page == .tryIt, preview == .tryItDone {
            practiceText = "Hello from Useful Voice."
            practiceWorked = true
        }
        if page == .microphone {
            micStatus = preview == .errMic ? .denied : .authorized
            meterLevels.levels = Self.sampleLevels
        }
        if page == .accessibility { accessibilityGranted = preview == .accessibilityOn }
    }

    /// The meter shape from the mockup, for offscreen renders.
    private static let sampleLevels: [Float] = [
        6, 10, 16, 24, 14, 9, 18, 28, 22, 12, 8, 16, 25, 19, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ].map { $0 / 28 }

    // MARK: - Navigation

    func go(_ next: Page) {
        guard next != page else { return }
        let old = page
        leave(old)
        // The key field is cleared on the way out unless the connected page is
        // next (it shows the saved key as dots, never the text).
        if old == .engine && next != .deepgramKey { clearKeyField() }
        page = next
        enter(next)
    }

    private func clearKeyField() {
        keyText = ""
        keyCheck = .idle
        keyUnderCheck = nil
    }

    /// Reopens the flow from Welcome. Always saves normally.
    func restart() {
        guard !active else { return }
        keyText = ""
        keyCheck = .idle
        changingKey = false
        practiceText = ""
        practiceWorked = false
        accessibilityGranted = false
        keyConnected = Keychain.exists(account: DeepgramKeyStore.account)
        snapshot = FirstRunGate.EngineSelection(
            engine: settings.transcriptionEngine, modelID: settings.localModelID)
        pendingLocal = nil
        startedFromSettings = true
        page = .welcome
        active = true
        enter(.welcome)
    }

    /// Done or Finish: the setup counts as complete. Never written in a forced run.
    func markCompleted() {
        guard !forced else { return }
        defaults.set(true, forKey: FirstRunGate.completedKey)
    }

    func finish() {
        markCompleted()
        leave(page)
        clearKeyField()
        // A download still running keeps going: the engine is already committed
        // to it. One that never started or already stopped is not coming back on
        // its own, so the engine goes back to what it was.
        let wasPreparing = preparingDownload
        cancelDiskTask()
        if let pending = pendingLocal {
            switch models.state(for: pending) {
            case .downloading, .validating: pendingLocal = nil
            default:
                if wasPreparing || models.availability(of: pending) != .usable {
                    dropPendingLocal()
                } else {
                    pendingLocal = nil
                }
            }
        }
        startedFromSettings = false
        finishCount += 1
        withAnimation(BrandMotion.easeOut(duration: 0.2)) { active = false }
    }

    /// Close from Settings "Run setup again". Drops any half-finished choice and
    /// never touches the completed flag.
    func closeSetup() {
        guard active, startedFromSettings else { return }
        // On the Done page Close and Esc finish, like "Open Useful Voice".
        if page == .done { finish(); return }
        leave(page)
        clearKeyField()
        cancelDiskTask()
        dropPendingLocal()
        startedFromSettings = false
        withAnimation(BrandMotion.easeOut(duration: 0.2)) { active = false }
    }

    /// The window was closed with the flow still up.
    func windowClosed() {
        guard active, !frozen else { return }
        if page == .done {
            finish()
        } else if startedFromSettings {
            closeSetup()
        } else {
            // Back to Welcome with the engine as it was, so the next launch (or
            // reopening) starts clean.
            leave(page)
            clearKeyField()
            changingKey = false
            cancelDiskTask()
            dropPendingLocal()
            page = .welcome
            enter(.welcome)
        }
    }

    private func enter(_ page: Page) {
        switch page {
        case .engine:
            if !frozen {
                keyCheck = .idle
                keyText = ""
                changingKey = false
            }
        case .localDownload:
            refreshModels()
        case .microphone:
            guard !frozen else { return }
            refreshMic()
            if micStatus == .authorized { startMeter() }
            startPolling()
        case .accessibility:
            guard !frozen else { return }
            // Already trusted on entry (a Back from Try it, or granted earlier):
            // show Allowed with a Continue button and do not move on by itself.
            // Only a false to true flip during this visit auto-advances.
            accessibilityGranted = AXIsProcessTrusted()
            startPolling()
        case .tryIt:
            recentBaseline = viewModel.recent.first?.id
            if !frozen { practiceWorked = false }
        case .done:
            markCompleted()
        case .welcome, .deepgramKey:
            break
        }
    }

    private func leave(_ page: Page) {
        advanceWork?.cancel()
        advanceWork = nil
        stopPolling()
        stopMeter()
        if page == .engine {
            checkTask?.cancel()
            checkTask = nil
            if keyCheck == .checking { keyCheck = .idle }
        }
    }

    // MARK: - Engine: Deepgram

    var trimmedKey: String { keyText.trimmingCharacters(in: .whitespacesAndNewlines) }

    func claimCredit() {
        guard let url = URL(string: "https://console.deepgram.com/signup?jump=keys") else { return }
        awaitingClaim = true
        NSWorkspace.shared.open(url)
    }

    func changeKey() {
        guard !savingKey else { return }
        clearKeyField()
        changingKey = true
        focusKeyRequest += 1
    }

    /// Back out of "Change key" with the saved key untouched.
    func keepCurrentKey() {
        guard !savingKey else { return }
        checkTask?.cancel()
        checkTask = nil
        clearKeyField()
        changingKey = false
    }

    func keyTextEdited() {
        if case .checking = keyCheck {
            // The check is for the old text: stop it rather than save a key the
            // field no longer shows.
            guard trimmedKey != keyUnderCheck else { return }
            checkTask?.cancel()
            checkTask = nil
            keyUnderCheck = nil
            keyCheck = .idle
            return
        }
        if keyCheck != .idle { keyCheck = .idle }
    }

    /// Runs the Settings "Test connection" probe on the pasted key, and saves
    /// it only when Deepgram accepts it.
    func connect() {
        let key = trimmedKey
        guard !key.isEmpty, keyCheck != .checking, !savingKey else { return }
        keyCheck = .checking
        keyUnderCheck = key
        let language = viewModel.languagePin
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            let provider = DeepgramProvider(config: .init(
                apiKey: key, smartFormat: true, spokenPunctuation: false))
            let result = await ProviderHealthCheck.check(
                provider: provider,
                endpoint: "https://api.deepgram.com/v1/listen",
                hint: TranscriptionHint(languagePin: language, dictionaryWords: []))
            guard !Task.isCancelled, let self else { return }
            if result.ok {
                await self.saveAcceptedKey(key)
                return
            }
            self.keyUnderCheck = nil
            switch result.failure {
            case .rejected: self.keyCheck = .rejected
            case .network: self.keyCheck = .network
            default: self.keyCheck = .failed(result.message)
            }
        }
    }

    private func saveAcceptedKey(_ key: String) async {
        if !forced {
            // The write cannot be cancelled: lock the controls until it returns,
            // and never let a second one start.
            guard !savingKey else { return }
            savingKey = true
            // Off the main actor: the Keychain write can wait on securityd.
            let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try Keychain.set(key, account: DeepgramKeyStore.account)
                    return true
                } catch {
                    return false
                }
            }.value
            savingKey = false
            guard saved else {
                if !Task.isCancelled { keyCheck = .saveFailed }
                return
            }
            // The key is in the Keychain now, so the app must know it even when
            // the person has already moved on. Cancellation only skips navigation.
            DeepgramKeyStore.shared.update(key)
            keyConnected = true
            viewModel.refreshConfig()
            guard !Task.isCancelled else { return }
            chooseEngine(.deepgram)
        } else {
            guard !Task.isCancelled else { return }
            keyConnected = true
        }
        clearKeyField()
        changingKey = false
        go(.deepgramKey)
    }

    /// Continue from the connected card or the connected page.
    func continueWithDeepgram() {
        if !forced { chooseEngine(.deepgram) }
        go(.microphone)
    }

    private func chooseEngine(_ engine: TranscriptionEngineChoice) {
        guard !forced else { return }
        if engine == .deepgram {
            cancelDiskTask()
            dropPendingLocal(restoring: false)
        }
        settings.transcriptionEngine = engine
        viewModel.models.engineChanged(to: engine)
        viewModel.refreshConfig()
    }

    /// Back to the engine page from "Use Deepgram instead": keep any saved key.
    func useDeepgramInstead() {
        if keyConnected {
            continueWithDeepgram()
        } else {
            cancelDiskTask()
            dropPendingLocal()
            go(.engine)
        }
    }

    // MARK: - Engine: local

    var models: LocalModelManager { viewModel.models }

    /// Picking a model only starts its download. The engine and model are
    /// committed by Continue on the download page.
    func chooseLocal(_ model: WhisperModel) {
        guard !savingKey else { return }
        selectedModel = model
        downloadStart = nil
        diskMessage = nil
        if !forced {
            // Switching models while one downloads: stop the other first.
            for other in models.models where other.id != model.id {
                if case .downloading = models.state(for: other) { models.pause(other) }
            }
            pendingLocal = model
            if models.availability(of: model) != .usable { startDownload(model) }
        }
        go(.localDownload)
    }

    /// Continue on the download page commits the engine and this model right
    /// away, even while the download is still running. Try it waits for the file.
    func continueFromDownload() {
        if !forced { commitLocal(selectedModel) }
        go(.microphone)
    }

    private func commitLocal(_ model: WhisperModel) {
        guard !forced else { return }
        models.activate(model, allowUnusable: true)
        chooseEngine(.whisperLocal)
    }

    /// Forgets the pending model, stops its download and, unless the current
    /// choice already works, puts the engine back to what it was at the start.
    private func dropPendingLocal(restoring: Bool = true) {
        cancelDiskTask()
        guard !forced else { return }
        if pendingLocal != nil {
            pauseRunningDownloads()
            pendingLocal = nil
        }
        if restoring { restoreSnapshotIfUnusable() }
    }

    private func restoreSnapshotIfUnusable() {
        guard !forced else { return }
        let current = FirstRunGate.EngineSelection(
            engine: settings.transcriptionEngine, modelID: settings.localModelID)
        let usable: Bool
        switch current.engine {
        case .deepgram:
            usable = Keychain.exists(account: DeepgramKeyStore.account)
        case .whisperLocal:
            usable = WhisperModelCatalog.model(forID: current.modelID)
                .map { models.availability(of: $0) == .usable } ?? false
        }
        let target = FirstRunGate.selectionAfterAbandon(
            snapshot: snapshot, current: current, currentUsable: usable)
        guard target != current else { return }
        if target.modelID != current.modelID,
           let model = WhisperModelCatalog.model(forID: target.modelID) {
            models.activate(model, allowUnusable: true)
        }
        if target.engine != current.engine {
            settings.transcriptionEngine = target.engine
            models.engineChanged(to: target.engine)
        }
        viewModel.refreshConfig()
    }

    func startDownload(_ model: WhisperModel) {
        if forced { return }
        switch models.state(for: model) {
        case .downloading, .validating: return
        default: break
        }
        let have = max(models.installedBytes(for: model) ?? 0, models.partialBytes(for: model))
        diskTask?.cancel()
        preparingDownload = true
        diskTask = Task { [weak self] in
            // The capacity query touches the volume, so it runs off the main actor.
            let shortfall = await Task.detached(priority: .userInitiated) {
                Self.diskShortfall(needed: model.expectedBytes - have)
            }.value
            // A cancel (or a newer start) already reset `preparingDownload`.
            guard !Task.isCancelled, let self else { return }
            self.preparingDownload = false
            // The model must still be the one this flow is downloading for.
            guard self.pendingLocal?.id == model.id else { return }
            if let shortfall {
                self.diskMessage = Self.diskMessage(shortfallBytes: shortfall, model: model)
                return
            }
            self.diskMessage = nil
            self.downloadStart = nil
            self.models.download(model)
        }
    }

    private var diskTask: Task<Void, Never>?

    /// The disk capacity query is running, so the download page shows the
    /// starting state instead of a stopped one.
    @Published private(set) var preparingDownload = false

    private func cancelDiskTask() {
        diskTask?.cancel()
        diskTask = nil
        preparingDownload = false
    }

    /// Set when a download could not start for lack of space.
    @Published private(set) var diskMessage: String?

    /// How many bytes short the volume is, or nil when there is room.
    nonisolated private static func diskShortfall(needed: Int64) -> Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let free = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return nil }
        // Headroom for the checksum step and the OS itself.
        let required = needed + 512 * 1024 * 1024
        return free >= required ? nil : required - free
    }

    static func diskMessage(shortfallBytes: Int64, model: WhisperModel) -> String {
        let gb = ByteCountFormatter.string(fromByteCount: shortfallBytes, countStyle: .file)
        return "There isn't enough space on this Mac for \(model.shortName). Free up about \(gb), then resume."
    }

    /// Cancel download, and the Back link on the download page: nothing of the
    /// half-made choice is kept.
    func cancelDownload() {
        cancelDiskTask()
        pauseRunningDownloads()
        pendingLocal = nil
        restoreSnapshotIfUnusable()
        go(.engine)
    }

    func pauseRunningDownloads() {
        guard !forced else { return }
        for model in models.models {
            if case .downloading = models.state(for: model) { models.pause(model) }
        }
    }

    private func refreshModels() {
        models.refreshAvailability()
    }

    // MARK: - Microphone

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshMic()
                if granted && self.page == .microphone { self.startMeter() }
            }
        }
    }

    func openMicSettings() {
        openPane("Privacy_Microphone")
    }

    private func refreshMic() {
        let next: MicStatus
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: next = .authorized
        case .notDetermined: next = .notDetermined
        default: next = .denied
        }
        micStatus = next
        // Read lazily, here, so opening the flow never touches the capture
        // device. Assigned only when it changed.
        let name = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone"
        if name != micDeviceName { micDeviceName = name }
    }

    private func startMeter() {
        guard !offscreen, !frozen, windowVisible, meter == nil,
              Date() >= meterRetryAfter else { return }
        let meter = MicLevelMeter()
        let ok = meter.start { [weak self] level in
            DispatchQueue.main.async { self?.pushLevel(level) }
        }
        guard ok else {
            meterRetryAfter = Date().addingTimeInterval(5)
            return
        }
        self.meter = meter
        // The default input changed (headphones plugged in, say): the engine
        // stops itself, so start again on the new device.
        meterConfigObserver = NotificationCenter.default
            .publisher(for: .AVAudioEngineConfigurationChange, object: meter.engine)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.page == .microphone else { return }
                    self.stopMeter()
                    self.refreshMic()
                    if self.micStatus == .authorized { self.startMeter() }
                }
            }
    }

    private func stopMeter() {
        meterConfigObserver = nil
        meter?.stop()
        meter = nil
        if !frozen { meterLevels.reset() }
    }

    /// About 20 updates a second is plenty for a 24-bar meter.
    private func pushLevel(_ level: Float) {
        guard meter != nil else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLevelPush) >= 0.05 else { return }
        lastLevelPush = now
        meterLevels.push(level)
    }

    // MARK: - Accessibility

    func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        openPane("Privacy_Accessibility")
    }

    private func openPane(_ pane: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Polling

    private func startPolling() {
        guard pollTimer == nil, !frozen else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollTick() }
        }
        // .common so it keeps ticking in the background and during a drag.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollTick() {
        guard active, !frozen else { return }
        switch page {
        case .microphone:
            let before = micStatus
            refreshMic()
            if micStatus != .authorized {
                // Access was revoked while the step is open: stop listening.
                if meter != nil { stopMeter() }
            } else if before == .denied {
                // Flipped to allowed during this visit: move on by itself.
                go(.accessibility)
            } else if meter == nil {
                startMeter()
            }
        case .accessibility:
            // Only a flip from off to on during this visit moves on by itself.
            guard !accessibilityGranted, AXIsProcessTrusted() else { return }
            accessibilityGranted = true
            onAccessibilityGranted?()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.page == .accessibility else { return }
                self.go(.tryIt)
            }
            advanceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        default:
            break
        }
    }

    private func appBecameActive() {
        if awaitingClaim, page == .engine {
            awaitingClaim = false
            focusKeyRequest += 1
        }
        pollTick()
    }

    /// The window hid or showed. The meter must not run while nobody can see it.
    func windowVisibilityChanged(_ visible: Bool) {
        windowVisible = visible
        guard active else { return }
        if !visible {
            stopMeter()
            // Nobody can see the step, so no one-second poll either. Coming
            // back to the app re-checks (see `appBecameActive`).
            if page == .microphone { stopPolling() }
        } else if page == .microphone {
            startPolling()
            if micStatus == .authorized { startMeter() }
            pollTick()
        }
    }

    // MARK: - Try it

    /// The committed local model when it is not usable yet: Try it waits for it
    /// instead of letting a dictation fail. Nil once it is ready, or on Deepgram.
    var localPending: WhisperModel? {
        if forced { return preview == .tryItDownloading ? selectedModel : nil }
        guard settings.transcriptionEngine == .whisperLocal else { return nil }
        let active = models.activeModel
        return models.availability(of: active) == .usable ? nil : active
    }

    /// The language Try it shows. In a forced run the pick is only shown.
    var languagePin: LanguagePin { previewLanguage ?? viewModel.languagePin }

    func setLanguage(_ pin: LanguagePin) {
        guard !forced else { previewLanguage = pin; return }
        settings.languagePin = pin
        viewModel.refreshConfig()
    }

    var hotkeyKeycode: Int { previewHotkey ?? viewModel.hotkeyKeycode }

    func setHotkey(_ keycode: Int) {
        guard !forced else { previewHotkey = keycode; return }
        viewModel.setHotkeyKeycode(keycode)
    }

    private func recentChanged(_ recent: [DictationRecord]) {
        guard active, page == .tryIt, !frozen,
              let newest = recent.first?.id, newest != recentBaseline else { return }
        practiceWorked = true
    }

    func practiceTextChanged() {
        guard page == .tryIt, !frozen else { return }
        if !practiceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            practiceWorked = true
        }
    }

    /// "Right ⌘" style label for the current dictation key.
    var keyLabel: String { Self.shortKeyLabel(for: hotkeyKeycode) }

    static func shortKeyLabel(for keycode: Int) -> String {
        let label = HotkeyOption.label(for: keycode)
        return label
            .replacingOccurrences(of: "Command", with: "⌘")
            .replacingOccurrences(of: "Option", with: "⌥")
            .replacingOccurrences(of: "Control", with: "⌃")
            .replacingOccurrences(of: "Shift", with: "⇧")
    }
}

extension WhisperModel {
    /// "Whisper Turbo" / "Whisper Large": the names the first-run pages use.
    var shortName: String { isRecommended ? "Whisper Turbo" : "Whisper Large" }
    /// "1.6 GB", always with a point, as the mockups show it.
    var gbDescription: String { String(format: "%.1f GB", Double(expectedBytes) / 1_000_000_000) }
}

/// Reads the default input's level while the microphone step is on screen.
@MainActor
final class MicLevelMeter {
    let engine = AVAudioEngine()
    private var running = false

    func start(onLevel: @escaping @Sendable (Float) -> Void) -> Bool {
        guard !running else { return true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.tap(onLevel: onLevel))
        do {
            try engine.start()
            running = true
            return true
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    /// Built outside the main actor: AVAudioEngine calls it on its own thread.
    nonisolated private static func tap(onLevel: @escaping @Sendable (Float) -> Void)
        -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            var sum: Float = 0
            for index in 0..<count { sum += data[index] * data[index] }
            let rms = (sum / Float(count)).squareRoot()
            let db = 20 * log10(max(rms, 1e-6))
            onLevel(min(1, max(0, (db + 50) / 40)))
        }
    }
}

/// The meter bars, kept out of `FirstRunModel` so only the meter redraws when
/// audio arrives.
@MainActor
final class MicLevels: ObservableObject {
    @Published var levels: [Float] = Array(repeating: 0, count: FirstRunModel.meterBars)

    func push(_ level: Float) {
        levels.insert(level, at: 0)
        levels.removeLast()
    }

    func reset() {
        levels = Array(repeating: 0, count: FirstRunModel.meterBars)
    }
}
