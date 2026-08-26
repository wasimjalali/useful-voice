import SwiftUI
import UsefulVoiceCore

/// Bridges the dictation pipeline and stored settings/history into observable
/// state for the main window. Lives on the main actor like the rest of the UI.
@MainActor
final class UsefulVoiceViewModel: ObservableObject {
    @Published var dictationState: DictationState = .idle
    @Published var recent: [DictationRecord] = []
    @Published var providerConfigured: Bool = false
    @Published var providerName: String = "Deepgram"
    @Published var languagePin: LanguagePin = .auto
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
    /// Set by the app layer to retry the last failed dictation on its audio.
    var onRetry: (() -> Void)?
    /// Set by the app layer to re-run a history item from retained audio when possible.
    var onReprocessHistory: ((DictationRecord) -> Void)?
    /// Applies recording settings to the live controller without requiring a relaunch.
    var onRecordingSettingsChange: ((TimeInterval, Int) -> Void)?

    private let settings: AppSettings
    private let history: DictationHistory
    let languageMemory: LanguageMemoryViewModel
    let scratchpad: ScratchpadViewModel
    private let onToggle: () -> Void

    /// History pages read search/all directly off the store.
    var historyStore: DictationHistory { history }

    init(settings: AppSettings, history: DictationHistory,
         languageMemory: LanguageMemoryStore,
         scratchpad: ScratchpadStore, onToggle: @escaping () -> Void) {
        self.settings = settings
        self.history = history
        self.languageMemory = LanguageMemoryViewModel(store: languageMemory)
        self.scratchpad = ScratchpadViewModel(store: scratchpad)
        self.onToggle = onToggle
        refreshConfig()
        refreshRecent()
    }

    func toggle() { onToggle() }

    func retry() { onRetry?() }

    func refreshState(_ state: DictationState) { dictationState = state }

    func refreshRecent() { recent = history.recent(5) }

    func refreshConfig() {
        // exists() not get(): refreshConfig runs on the main thread (init, and
        // after every settings/language change), and get() can trigger a
        // blocking keychain authorization prompt that freezes the app, and with
        // it the HUD. An existence check is all "configured?" needs and never
        // prompts. See Keychain.exists.
        providerName = "Deepgram"
        providerConfigured = Keychain.exists(account: "deepgram-key")
        languagePin = settings.languagePin
        hotkeyKeycode = settings.hotkeyKeycode
        languageSwitchKeycode = settings.languageSwitchKeycode
        onRecordingSettingsChange?(settings.silenceTimeout, settings.recordingsToKeep)
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
        let language = MemoryLanguage(languagePin: languagePin)
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
