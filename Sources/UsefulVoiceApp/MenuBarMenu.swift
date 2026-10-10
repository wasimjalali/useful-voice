import AppKit
import SwiftUI
import UsefulVoiceCore

/// The menu bar menu: a native NSMenu with one custom header row. Every HUD
/// action has a menu path here (Retry last recording, and the fix verb for the
/// last issue), so each one is reachable from the keyboard and VoiceOver.
@MainActor
final class MenuBarMenu: NSObject, NSMenuDelegate {
    /// What the menu asks the app to do.
    struct Actions {
        var toggleDictation: () -> Void
        var cancelDictation: () -> Void
        var openMainWindow: () -> Void
        /// Opens the window on Settings, scrolled to the group with this id.
        var openSettings: (_ anchor: String?) -> Void
        var copy: (String) -> Void
        var setLanguage: (LanguagePin) -> Void
    }

    let menu = NSMenu()
    let header = MenuHeaderModel()

    private let settings: AppSettings
    private let viewModel: UsefulVoiceViewModel
    private let actions: Actions
    private var isRecording = false

    private let toggleItem = NSMenuItem()
    private let cancelItem = NSMenuItem()
    private let retryItem = NSMenuItem()
    private let copyItem = NSMenuItem()
    private let fixItem = NSMenuItem()
    private let formattingItem = NSMenuItem()
    private let settingsItem = NSMenuItem()
    private var languageItems: [NSMenuItem] = []

    init(settings: AppSettings, viewModel: UsefulVoiceViewModel, actions: Actions) {
        self.settings = settings
        self.viewModel = viewModel
        self.actions = actions
        super.init()
        build()
    }

    // MARK: - Building

    private func build() {
        // Items are enabled and hidden by hand below, and the header row has to
        // stay enabled for its Copy button to receive clicks.
        menu.autoenablesItems = false
        menu.minimumWidth = MenuHeaderView.size.width
        menu.delegate = self

        header.onCopy = { [weak self] in self?.copyLastFromHeader() }
        let headerItem = NSMenuItem()
        let hosting = NSHostingView(rootView: MenuHeaderView(model: header))
        hosting.frame = NSRect(origin: .zero, size: MenuHeaderView.size)
        headerItem.view = hosting
        menu.addItem(headerItem)
        menu.addItem(.separator())

        configure(toggleItem, title: "Start dictation", action: #selector(toggleDictation))
        configure(cancelItem, title: "Cancel dictation (Esc)", action: #selector(cancelDictation))
        configure(retryItem, title: "Retry last recording", action: #selector(retryLast))
        configure(copyItem, title: "Copy last transcript", action: #selector(copyLast))
        for item in [toggleItem, cancelItem, retryItem, copyItem] { menu.addItem(item) }

        let languageMenu = NSMenu()
        languageMenu.autoenablesItems = false
        let catalogue = DeepgramLanguageCatalog.all.map { LanguagePin(rawValue: $0.code) }
        for pin in LanguagePin.modes + catalogue {
            // The modes (detection, code-switching) first, then the languages.
            if pin == catalogue.first { languageMenu.addItem(.separator()) }
            let item = NSMenuItem(title: Self.languageTitle(pin), action: #selector(pickLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = pin.rawValue
            languageMenu.addItem(item)
            languageItems.append(item)
        }
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        menu.setSubmenu(languageMenu, for: languageItem)
        menu.addItem(languageItem)

        configure(formattingItem, title: "Auto-format transcript", action: #selector(toggleFormatting))
        menu.addItem(formattingItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem()
        configure(openItem, title: "Open Useful Voice", action: #selector(openMainWindow))
        menu.addItem(openItem)
        configure(fixItem, title: "Open settings", action: #selector(performFix))
        menu.addItem(fixItem)
        configure(settingsItem, title: "Open settings", action: #selector(openSettings), key: ",")
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Useful Voice",
                                  action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        refresh()
    }

    private func configure(_ item: NSMenuItem, title: String, action: Selector, key: String = "") {
        item.title = title
        item.action = action
        item.keyEquivalent = key
        item.target = self
    }

    private static func languageTitle(_ pin: LanguagePin) -> String {
        if pin.isAuto { return "Auto-detect" }
        if pin.isMultilingual { return "Multiple languages" }
        guard let language = DeepgramLanguageCatalog.language(for: pin.rawValue) else { return pin.displayName }
        return language.nativeName == language.name ? language.name : "\(language.nativeName) (\(language.name))"
    }

    // MARK: - State

    /// Follows the dictation state: the header status, Start or Stop, Cancel.
    func apply(state: DictationState) {
        isRecording = state == .recording
        switch state {
        case .idle, .error: header.status = .ready
        case .recording: header.status = .recording
        case .transcribing: header.status = .transcribing
        case .delivering: header.status = .inserting
        }
        if state == .recording { header.seconds = 0 }
        refresh()
    }

    /// One recording tick. Runs from a timer in `.common` run-loop mode, so the
    /// timer in the header keeps counting while the menu is open.
    func tick(seconds: Int, level: Float) {
        if header.seconds != seconds { header.seconds = seconds }
        header.level = level
    }

    /// Brings every item in line with the current state. Called when the state
    /// changes and when the menu is about to open.
    func refresh() {
        let hotkey = HotkeyOption.label(for: settings.hotkeyKeycode)
        toggleItem.title = isRecording ? "Stop dictation (\(hotkey))" : "Start dictation (\(hotkey))"
        cancelItem.isHidden = !isRecording

        retryItem.isHidden = !viewModel.canRetry
        let lastText = viewModel.recent.first?.text
        copyItem.isHidden = lastText == nil
        header.lastLine = lastText.flatMap(Self.firstLine)

        // The fix verb of the last issue, so the HUD's button has a menu path.
        // System Settings panes get their own item; an engine fix is the app's
        // own Settings, scrolled to the engine group by "Open settings".
        switch viewModel.lastIssue?.fix {
        case .openAccessibilitySettings:
            fixItem.title = "Open Accessibility settings"
            fixItem.isHidden = false
        case .openMicrophoneSettings:
            fixItem.title = "Open Microphone settings"
            fixItem.isHidden = false
        default:
            fixItem.isHidden = true
        }

        // Smart formatting is a Deepgram option; local models format on their own.
        formattingItem.state = settings.formattingEnabled ? .on : .off
        formattingItem.isHidden = settings.transcriptionEngine == .whisperLocal
        syncLanguage()
    }

    /// Refreshes the Language submenu checkmarks to match the stored pin.
    func syncLanguage() {
        for item in languageItems {
            guard let raw = item.representedObject as? String else { continue }
            item.state = settings.languagePin.rawValue == raw ? .on : .off
        }
    }

    /// The first non-empty line, so a long dictation shows as one line.
    private static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        header.copied = false
        refresh()
    }

    // MARK: - Actions

    @objc private func toggleDictation() { actions.toggleDictation() }

    @objc private func cancelDictation() { actions.cancelDictation() }

    @objc private func retryLast() { viewModel.retry() }

    @objc private func copyLast() {
        guard let text = viewModel.recent.first?.text else { return }
        actions.copy(text)
    }

    @objc private func copyLastFromHeader() {
        guard let text = viewModel.recent.first?.text else { return }
        actions.copy(text)
        header.copied = true
        // Closes the menu: a view in a menu does not dismiss it by itself.
        menu.cancelTracking()
    }

    @objc private func toggleFormatting() {
        // Off = raw transcript, Deepgram's smart_format is disabled.
        // Takes effect on the next dictation (the provider is built per use).
        settings.formattingEnabled.toggle()
        formattingItem.state = settings.formattingEnabled ? .on : .off
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        actions.setLanguage(LanguagePin(code: raw))
        syncLanguage()
    }

    @objc private func openMainWindow() { actions.openMainWindow() }

    /// Opens Settings. When the last issue needs the engine set up, the window
    /// scrolls to the Engine group, which is that issue's fix.
    @objc private func openSettings() {
        let anchor: String? = viewModel.lastIssue?.fix == .openEngineSettings ? "engine" : nil
        actions.openSettings(anchor)
    }

    @objc private func performFix() {
        guard let fix = viewModel.lastIssue?.fix else { return }
        viewModel.perform(fix)
    }
}
