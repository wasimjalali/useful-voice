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
        case errKey, errDownload, errMic, tryItDone
    }

    enum KeyCheck: Equatable {
        case idle
        case checking
        case rejected
        case network
        case failed(String)
    }

    enum MicStatus: Equatable {
        case notDetermined, authorized, denied
    }

    // MARK: - Published state

    @Published private(set) var active: Bool
    @Published private(set) var page: Page = .welcome
    /// Bumped when the flow ends, so the window can land on Dictate.
    @Published private(set) var finishCount = 0

    // Engine
    @Published var keyText = ""
    @Published private(set) var keyCheck: KeyCheck = .idle
    /// A key is saved (or, in a forced run, the check passed this run).
    @Published private(set) var keyConnected = false
    @Published var changingKey = false
    /// Bumped to ask the key field to take focus (after the Claim round trip).
    @Published private(set) var focusKeyRequest = 0
    @Published private(set) var selectedModel: WhisperModel = WhisperModelCatalog.default

    // Microphone
    @Published private(set) var micStatus: MicStatus = .notDetermined
    @Published private(set) var micLevels: [Float] = Array(repeating: 0, count: FirstRunModel.meterBars)
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

        let decision = FirstRunGate.decide(
            completed: defaults.bool(forKey: FirstRunGate.completedKey),
            engineConfigured: viewModel.providerConfigured,
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
        keyConnected = forced ? false : DeepgramKeyStore.shared.isConfigured()
        micDeviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone"
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
        case "done": return (.done, nil)
        case "errKey": return (.engine, .errKey)
        case "errDownload": return (.localDownload, .errDownload)
        case "errMic": return (.microphone, .errMic)
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
            micLevels = Self.sampleLevels
        }
        if page == .accessibility { accessibilityGranted = false }
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
        page = next
        enter(next)
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
        keyConnected = DeepgramKeyStore.shared.isConfigured()
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
        finishCount += 1
        withAnimation(BrandMotion.easeOut(duration: 0.2)) { active = false }
    }

    private func enter(_ page: Page) {
        switch page {
        case .engine:
            keyCheck = frozen ? keyCheck : .idle
        case .localDownload:
            refreshModels()
        case .microphone:
            guard !frozen else { return }
            refreshMic()
            if micStatus == .authorized { startMeter() }
            startPolling()
        case .accessibility:
            guard !frozen else { return }
            accessibilityGranted = false
            startPolling()
            pollTick()
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
        keyText = ""
        keyCheck = .idle
        changingKey = true
        focusKeyRequest += 1
    }

    func keyTextEdited() {
        if case .checking = keyCheck { return }
        if keyCheck != .idle { keyCheck = .idle }
    }

    /// Runs the Settings "Test connection" probe on the pasted key, and saves
    /// it only when Deepgram accepts it.
    func connect() {
        let key = trimmedKey
        guard !key.isEmpty, keyCheck != .checking else { return }
        keyCheck = .checking
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
            switch result.failure {
            case .rejected: self.keyCheck = .rejected
            case .network: self.keyCheck = .network
            default: self.keyCheck = .failed(result.message)
            }
        }
    }

    private func saveAcceptedKey(_ key: String) async {
        if !forced {
            // Off the main actor: the Keychain write can wait on securityd.
            let saved = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try Keychain.set(key, account: DeepgramKeyStore.account)
                    return true
                } catch {
                    return false
                }
            }.value
            guard !Task.isCancelled else { return }
            guard saved else {
                keyCheck = .failed("Couldn't save the key to your Keychain. Try again.")
                return
            }
            DeepgramKeyStore.shared.update(key)
            chooseEngine(.deepgram)
        }
        keyText = ""
        keyCheck = .idle
        keyConnected = true
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
        if engine == .deepgram { pauseRunningDownloads() }
        settings.transcriptionEngine = engine
        viewModel.models.engineChanged(to: engine)
        viewModel.refreshConfig()
    }

    /// Back to the engine page from "Use Deepgram instead": keep any saved key.
    func useDeepgramInstead() {
        pauseRunningDownloads()
        if keyConnected {
            continueWithDeepgram()
        } else {
            go(.engine)
        }
    }

    // MARK: - Engine: local

    var models: LocalModelManager { viewModel.models }

    func chooseLocal(_ model: WhisperModel) {
        // Switching models while one downloads: stop the other first.
        for other in models.models where other.id != model.id {
            if case .downloading = models.state(for: other) { models.pause(other) }
        }
        selectedModel = model
        downloadStart = nil
        if !forced {
            models.select(model)
            chooseEngine(.whisperLocal)
            if models.availability(of: model) != .usable {
                startDownload(model)
            }
        }
        go(.localDownload)
    }

    func startDownload(_ model: WhisperModel) {
        if forced { return }
        if let shortfall = diskShortfall(for: model) {
            diskMessage = Self.diskMessage(shortfallBytes: shortfall, model: model)
            return
        }
        diskMessage = nil
        downloadStart = nil
        models.download(model)
    }

    /// Set when a download could not start for lack of space.
    @Published private(set) var diskMessage: String?

    /// How many bytes short the volume is, or nil when there is room.
    private func diskShortfall(for model: WhisperModel) -> Int64? {
        let have = models.installedBytes(for: model) ?? 0
        let need = model.expectedBytes - have
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let free = try? home.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return nil }
        // Headroom for the checksum step and the OS itself.
        let required = need + 512 * 1024 * 1024
        return free >= required ? nil : required - free
    }

    static func diskMessage(shortfallBytes: Int64, model: WhisperModel) -> String {
        let gb = ByteCountFormatter.string(fromByteCount: shortfallBytes, countStyle: .file)
        return "There isn't enough space on this Mac for \(model.shortName). Free up about \(gb), then resume."
    }

    func cancelDownload() {
        pauseRunningDownloads()
        go(.engine)
    }

    func pauseRunningDownloads() {
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
        micDeviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone"
    }

    private func startMeter() {
        guard !offscreen, !frozen, windowVisible, meter == nil else { return }
        let meter = MicLevelMeter()
        let ok = meter.start { [weak self] level in
            DispatchQueue.main.async { self?.pushLevel(level) }
        }
        if ok { self.meter = meter }
    }

    private func stopMeter() {
        meter?.stop()
        meter = nil
        if !frozen { micLevels = Array(repeating: 0, count: Self.meterBars) }
    }

    private func pushLevel(_ level: Float) {
        guard meter != nil else { return }
        micLevels.insert(level, at: 0)
        micLevels.removeLast()
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
            if micStatus == .authorized, before == .denied {
                go(.accessibility)
            } else if micStatus == .authorized, meter == nil {
                startMeter()
            }
        case .accessibility:
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
        } else if page == .microphone, micStatus == .authorized {
            startMeter()
        }
    }

    // MARK: - Try it

    func setLanguage(_ pin: LanguagePin) {
        settings.languagePin = pin
        viewModel.refreshConfig()
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
    var keyLabel: String { Self.shortKeyLabel(for: viewModel.hotkeyKeycode) }

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
    private let engine = AVAudioEngine()
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
