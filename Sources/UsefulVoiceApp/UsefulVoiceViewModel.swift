import SwiftUI
import UsefulVoiceCore

/// Bridges the dictation pipeline and stored settings/history into observable
/// state for the main window. Lives on the main actor like the rest of the UI.
@MainActor
final class UsefulVoiceViewModel: ObservableObject {
    @Published var dictationState: DictationState = .idle
    /// The error or "copied, not pasted" notice from the last dictation. Set when
    /// the dictation fails or its text could not be pasted; cleared when the next
    /// recording (or a retry) starts, or by `dismissIssue()`.
    @Published private(set) var lastIssue: DictationIssue?
    /// How the last dictation ended. Published just before the state returns to
    /// idle; cleared when the next recording (or a retry) starts.
    @Published private(set) var lastOutcome: DictationOutcome?
    /// Live level, timer, countdowns and local partial text. A separate object so
    /// its 30 Hz updates redraw only the views that observe it.
    let telemetry = DictationTelemetry()
    @Published var recent: [DictationRecord] = []
    /// Bumped whenever the usage stats change, so the Insights page redraws.
    @Published var usageRevision = 0
    @Published var providerConfigured: Bool = false
    /// What Home says when the provider is not ready, matched to the engine.
    @Published var providerSetupHint: String = "Add your Deepgram key in Settings"
    @Published var providerName: String = "Deepgram"
    @Published var languagePin: LanguagePin = .en
    /// Whether the global hotkey tap is actually running (Accessibility granted).
    @Published var hotkeyActive: Bool = false
    @Published var hotkeyKeycode: Int = 54
    @Published var languageSwitchKeycode: Int = 60
    /// A failed dictation whose audio is retained and can be retried.
    @Published var canRetry: Bool = false

    /// Set by the app layer to push a new activation key to the live HotkeyManager.
    var onHotkeyKeycodeChange: ((Int) -> Void)?
    /// Set by the app layer to push a new language-switch key to the live HotkeyManager.
    var onLanguageSwitchKeycodeChange: ((Int) -> Void)?
    /// Set by the app layer: the saved recordings were deleted, so retained audio
    /// for Retry is gone too.
    var onRecordingsDeleted: (() -> Void)?
    /// Set by the app layer to bring the main window up (closed or behind).
    var onOpenWindow: (() -> Void)?
    /// Set by the app layer to retry the last failed dictation on its audio.
    var onRetry: (() -> Void)?
    /// Set by the app layer to re-run a history item from retained audio when possible.
    var onReprocessHistory: ((DictationRecord) -> Void)?
    /// Applies recording settings to the live controller without requiring a relaunch.
    var onRecordingSettingsChange: ((TimeInterval, Int) -> Void)?
    /// Builds the provider a dictation would use right now — for the Settings
    /// "Test connection" probe, which must exercise the real engine selection
    /// rather than a copy of it.
    var makeTranscriptionProvider: (() -> TranscriptionProvider?)?

    private let settings: AppSettings
    private let history: DictationHistory
    /// Lifetime usage totals behind the Insights page.
    let usageStats: UsageStatsStore
    let languageMemory: LanguageMemoryViewModel
    let scratchpad: ScratchpadViewModel
    /// Local model downloads/state for the Settings page. Owns the store and
    /// downloader; the view reads it as an ordinary ObservedObject.
    let models: LocalModelManager
    private let onToggle: (DictationSource) -> Void
    private var feedback = DictationFeedback()

    /// History pages read search/all directly off the store.
    var historyStore: DictationHistory { history }

    init(settings: AppSettings, history: DictationHistory,
         usageStats: UsageStatsStore,
         languageMemory: LanguageMemoryStore,
         scratchpad: ScratchpadStore,
         models: LocalModelManager? = nil,
         onToggle: @escaping (DictationSource) -> Void) {
        self.settings = settings
        self.history = history
        self.usageStats = usageStats
        self.languageMemory = LanguageMemoryViewModel(store: languageMemory)
        self.scratchpad = ScratchpadViewModel(store: scratchpad)
        self.models = models ?? LocalModelManager(settings: settings)
        self.onToggle = onToggle
        refreshConfig()
        refreshRecent()
    }

    /// The window's mic button and transport: the dictation is saved and copied,
    /// not pasted.
    func toggle() { onToggle(.window) }

    func retry() { onRetry?() }

    /// Call after deleting the saved recordings (Delete all dictations).
    func recordingsDeleted() {
        onRecordingsDeleted?()
        canRetry = false
    }

    func refreshState(_ state: DictationState) {
        dictationState = state
        telemetry.apply(state: state)
        feedback.apply(state: state)
        publishFeedback()
    }

    /// A dictation finished (delivered) or was cancelled.
    func handle(outcome: DictationOutcome) {
        feedback.apply(outcome: outcome)
        publishFeedback()
    }

    /// Clears the issue the window shows (the dock row). The HUD's x and its 8 s
    /// only hide the HUD: the fix stays reachable in the window and the menu.
    func dismissIssue() {
        feedback.dismissIssue()
        publishFeedback()
    }

    // MARK: - Navigation and fixes

    /// Asks the window to show a section, optionally scrolled to an anchor (a
    /// Settings group id such as "engine" or "appearance"). RootView consumes it.
    struct NavigationRequest: Equatable {
        let section: String
        let anchor: String?
        let id = UUID()
    }
    @Published var navigationRequest: NavigationRequest?

    /// `section` is a `SidebarSection` raw value.
    func navigate(to section: String, anchor: String? = nil) {
        navigationRequest = NavigationRequest(section: section, anchor: anchor)
    }

    /// Runs the fix verb attached to an error or notice, from the dock, a banner,
    /// the HUD or a menu item.
    func perform(_ fix: DictationFix) {
        switch fix {
        case .openMicrophoneSettings: Self.openPrivacyPane("Privacy_Microphone")
        case .openAccessibilitySettings: Self.openPrivacyPane("Privacy_Accessibility")
        case .openEngineSettings:
            // From the HUD or the menu the window may be closed: open it first.
            onOpenWindow?()
            navigate(to: "settings", anchor: "engine")
        case .retry: retry()
        }
    }

    static func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func publishFeedback() {
        if lastIssue != feedback.issue { lastIssue = feedback.issue }
        if lastOutcome != feedback.outcome { lastOutcome = feedback.outcome }
    }

    func refreshRecent() { recent = history.recent(5) }

    func refreshUsage() { usageRevision += 1 }

    func refreshConfig() {
        // Reads the in-memory cache rather than the Keychain. Calling get() here
        // would run on the main thread (refreshConfig is called from init and
        // after every settings/language change) and can block on a keychain
        // authorization prompt, freezing the app and, with it, the HUD and the
        // event tap. DeepgramKeyStore is primed off-main at launch.
        let engine = settings.transcriptionEngine
        providerName = engine.displayName
        let model = models.activeModel
        let plan = ProviderSelector.resolve(
            engine: engine,
            deepgramKeyAvailable: DeepgramKeyStore.shared.current != nil
                || DeepgramKeyStore.shared.isConfigured(),
            localModel: model,
            localModelAvailability: models.availability(of: model))
        switch plan {
        case .deepgram, .local:
            providerConfigured = true
        case .needsDeepgramKey:
            providerConfigured = false
            providerSetupHint = "Add your Deepgram key in Settings"
        case .needsModelDownload:
            providerConfigured = false
            providerSetupHint = "Download a model in Settings"
        case .modelInvalid:
            providerConfigured = false
            providerSetupHint = "Download your model again in Settings"
        }
        languagePin = settings.languagePin
        hotkeyKeycode = settings.hotkeyKeycode
        languageSwitchKeycode = settings.languageSwitchKeycode
        onRecordingSettingsChange?(settings.silenceTimeout, settings.recordingsToKeep)
    }

    /// Commits any debounced editor work before the process exits.
    func flushPendingEdits() {
        scratchpad.commitDraft()
    }

    /// Sets the dictation key and swaps the language key when they collide.
    func setHotkeyKeycode(_ code: Int) {
        var assignment = HotkeyAssignment(
            dictation: hotkeyKeycode,
            languageSwitch: languageSwitchKeycode
        )
        assignment.setDictation(code)
        apply(assignment)
    }

    /// Sets the language-switch key and swaps the dictation key on collision.
    func setLanguageSwitchKeycode(_ code: Int) {
        var assignment = HotkeyAssignment(
            dictation: hotkeyKeycode,
            languageSwitch: languageSwitchKeycode
        )
        assignment.setLanguageSwitch(code)
        apply(assignment)
    }

    private func apply(_ assignment: HotkeyAssignment) {
        if hotkeyKeycode != assignment.dictation {
            settings.hotkeyKeycode = assignment.dictation
            hotkeyKeycode = assignment.dictation
            onHotkeyKeycodeChange?(assignment.dictation)
        }
        if languageSwitchKeycode != assignment.languageSwitch {
            settings.languageSwitchKeycode = assignment.languageSwitch
            languageSwitchKeycode = assignment.languageSwitch
            onLanguageSwitchKeycodeChange?(assignment.languageSwitch)
        }
    }

    func refreshLanguageMemory() {
        languageMemory.refresh()
        objectWillChange.send()
    }

    // MARK: - Scratchpad

    func refreshScratchpad() {
        scratchpad.refresh()
        objectWillChange.send()
    }

    func sendToScratchpad(_ record: DictationRecord) {
        scratchpad.createDictationNote(record.text)
    }

    func reprocessHistoryWithLanguageMemory(_ record: DictationRecord) {
        if let onReprocessHistory {
            onReprocessHistory(record)
            return
        }
        reprocessHistoryTextOnly(record)
    }

    func reprocessHistoryTextOnly(_ record: DictationRecord) {
        let snapshot = languageMemory.exportSnapshot()
        // Reprocess in the language the dictation ran in, not whatever is
        // pinned now. `resolvedPin` validates the stored union: a stored
        // `multi` re-sends `language=multi`, an unknown code scopes as auto
        // rather than producing an unsendable pin.
        let pin = record.resolvedPin ?? languagePin
        let language = MemoryLanguage(languagePin: pin)
        let source = record.rawText ?? record.text
        let result = LanguageMemoryPostProcessor.rawResult(
            for: source,
            snapshot: snapshot,
            language: language
        )
        let next = DictationRecord(
            text: result.text,
            createdAt: Date(),
            language: record.language,
            provider: "\(record.provider) reprocess",
            durationSeconds: record.durationSeconds,
            mode: .raw,
            rawText: source,
            intermediateText: record.text,
            memoryHitIDs: result.memoryHitIDs.isEmpty ? nil : result.memoryHitIDs,
            replacementRuleIDs: result.replacementRuleIDs.isEmpty ? nil : result.replacementRuleIDs,
            snippetIDs: result.snippetIDs.isEmpty ? nil : result.snippetIDs
        )
        history.append(next)
        languageMemory.recordUsage(
            termIDs: result.memoryHitIDs,
            replacementRuleIDs: result.replacementRuleIDs,
            snippetIDs: result.snippetIDs
        )
        refreshRecent()
    }
}
