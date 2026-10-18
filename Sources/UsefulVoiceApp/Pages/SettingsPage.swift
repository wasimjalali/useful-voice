import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import UniformTypeIdentifiers
import UsefulVoiceCore

/// Settings as one scrolling page with a left index. Every control saves the moment it
/// changes and says so with a quiet "Saved" toast; each API key keeps its own Save, Remove
/// and Test. `anchor` scrolls to a group (see `groups`) and is then cleared; the old
/// `engine` anchor opens Models.
struct SettingsPage: View {
    let settings: AppSettings
    @ObservedObject var viewModel: UsefulVoiceViewModel
    /// The same manager instance the app layer wired up, observed here so download
    /// progress and availability redraw this page live.
    @ObservedObject private var models: LocalModelManager
    @ObservedObject var firstRun: FirstRunModel
    @Binding var anchor: String?
    @EnvironmentObject private var toasts: AppToastCenter

    @StateObject private var modelsVM: ModelsViewModel
    @State private var formattingEnabled = true
    @State private var spokenPunctuationEnabled = false
    @State private var silenceTimeout = 60.0
    @State private var recordingsToKeep = 10
    @State private var soundEffectsEnabled = true
    @State private var appearance: AppearanceChoice = .system
    @State private var dailyGoal = AppSettings.defaultDailyWordGoal
    /// Login item, permissions and the dictation count, read once and refreshed on appear and
    /// when the app comes forward, never on every body evaluation.
    @StateObject private var system: SettingsSystemState
    @State private var confirmation: Confirmation?
    /// The group at the top of the scroll view: drives the index, and scrolls when set.
    @State private var topGroup: String? = SettingsPage.groups[0].id
    @StateObject private var diagnostics = DiagnosticsViewModel()

    init(settings: AppSettings, viewModel: UsefulVoiceViewModel, firstRun: FirstRunModel,
         anchor: Binding<String?>) {
        self.settings = settings
        self.viewModel = viewModel
        self.firstRun = firstRun
        _anchor = anchor
        // A requested group is the first scroll position, so even a page that is rendered
        // before it appears (an offscreen snapshot) opens there.
        let requested = (anchor.wrappedValue ?? SettingsSnapshot.anchor).map(Self.canonical)
        if let requested, Self.groups.contains(where: { $0.id == requested }) {
            _topGroup = State(initialValue: requested)
        }
        _models = ObservedObject(wrappedValue: viewModel.models)
        // Read up front as well as in `load()`: a page that is rendered before it appears
        // (an offscreen snapshot) never gets its onAppear.
        let modelsVM = ModelsViewModel(settings: settings, whisper: viewModel.models,
                                       parakeet: viewModel.parakeet)
        _modelsVM = StateObject(wrappedValue: modelsVM)
        _formattingEnabled = State(initialValue: settings.formattingEnabled)
        _spokenPunctuationEnabled = State(initialValue: settings.spokenPunctuationEnabled)
        _silenceTimeout = State(initialValue: settings.silenceTimeout)
        _recordingsToKeep = State(initialValue: settings.recordingsToKeep)
        _soundEffectsEnabled = State(initialValue: settings.soundEffectsEnabled)
        _appearance = State(initialValue: settings.appearance)
        _dailyGoal = State(initialValue: settings.dailyWordGoal)
        _system = StateObject(wrappedValue: SettingsSystemState(history: viewModel.historyStore))
        switch SettingsSnapshot.state {
        case "noKey":
            modelsVM.applyPreview(.noKeys)
        case "modelsSample", "modelsCompact":
            modelsVM.applyPreview(.sample)
        case "invalidKey":
            modelsVM.applyPreview(.rejectedKey)
        case "confirmDelete":
            _confirmation = State(initialValue: .allDictations(count: viewModel.historyStore.all().count))
        default:
            break
        }
    }

    static let groups: [(id: String, title: String)] = [
        ("general", "General"), ("models", "Models"), ("keys", "API keys"), ("formatting", "Formatting"),
        ("hotkeys", "Hotkeys"), ("appearance", "Appearance"), ("data", "Data"),
        ("importExport", "Import and export"), ("diagnostics", "Diagnostics"), ("about", "About"),
    ]

    /// Older deep links name the Models group "engine".
    static func canonical(_ anchor: String) -> String { anchor == "engine" ? "models" : anchor }

    private enum Confirmation: Equatable {
        case model(ModelEntry)
        case allDictations(count: Int)
    }

    /// Where the app keeps its data.
    private var supportFolder: URL { DataFolder.current() }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            StagePageHeader(title: "Settings", hairline: true)
            HStack(alignment: .top, spacing: 0) {
                SettingsIndex(groups: Self.groups, active: topGroup ?? Self.groups[0].id) { id in
                    withAnimation(BrandMotion.resolved(BrandMotion.rise)) { topGroup = id }
                }
                form
            }
        }
        // Under the confirmation nothing behind it can be reached by Tab or VoiceOver.
        .disabled(confirmation != nil)
        .accessibilityHidden(confirmation != nil)
        .background(Theme.surface)
        .overlay { dialog }
        // The rail lives outside this page: tell the shell to fence it off too.
        .onChange(of: confirmation != nil) { _, shown in viewModel.modalPresented = shown }
        .onDisappear { viewModel.modalPresented = false }
        .onAppear(perform: load)
        .onChange(of: viewModel.usageRevision) { _, _ in system.refreshCount() }
        // The setup flow can change the engine and the key: re-read only those, so edits
        // elsewhere on the page survive. (AppSettings is not observable, so the end of the
        // flow is the signal.)
        .onAppear(perform: wireModels)
        .onChange(of: firstRun.active) { _, active in
            if !active { syncFromFirstRun() }
        }
        // A key saved mid-flow, or an engine put back when the window closed on a first
        // launch, can land while the flow is still marked active.
        .onChange(of: firstRun.keyConnected) { _, _ in syncFromFirstRun() }
        .onChange(of: firstRun.engineRestoreCount) { _, _ in syncFromFirstRun() }
        // Permissions change in System Settings, so look again when the app comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            system.refresh()
        }
    }

    private var form: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    generalGroup
                    modelsGroup
                    apiKeysGroup
                    formattingGroup
                    hotkeysGroup
                    appearanceGroup
                    dataGroup
                    importExportGroup
                    diagnosticsGroup
                    aboutGroup
                }
                .scrollTargetLayout()
                .frame(maxWidth: 740, alignment: .leading)
                .padding(.leading, 24)
                .padding(.trailing, 40)
                // Room for the last group to reach the top, so every index row can be jumped to.
                .padding(.bottom, max(28, viewport.size.height - 220))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition(id: $topGroup, anchor: .top)
            .onChange(of: anchor) { _, raw in
                guard let requested = raw.map(Self.canonical) else { return }
                if Self.groups.contains(where: { $0.id == requested }) {
                    withAnimation(BrandMotion.resolved(BrandMotion.rise)) { topGroup = requested }
                }
                anchor = nil
            }
            // A group asked for before the page existed: the position was set at init. Set it
            // again once the page is laid out (the first value can land before there is
            // anything to scroll), then clear the request.
            .task {
                guard let requested = (anchor ?? SettingsSnapshot.anchor).map(Self.canonical),
                      Self.groups.contains(where: { $0.id == requested }) else { return }
                try? await Task.sleep(for: .milliseconds(80))
                topGroup = requested
                anchor = nil
            }
        }
    }

    private func saved() {
        toasts.show("Saved", duration: 1.6)
    }

    // MARK: - General

    private var generalGroup: some View {
        SettingsGroup(id: "general", title: "General") {
            SettingsRow(title: "Language") {
                LanguagePickerButton(selection: languageBinding).frame(width: 200)
            }
            SettingsRow(title: "Daily goal") {
                SettingsStepper(label: "Daily goal", value: $dailyGoal, range: 100...1_000_000, step: 100,
                                format: SettingsFormat.number, editable: true, onCommit: {
                    settings.dailyWordGoal = dailyGoal
                    viewModel.refreshUsage()
                    saved()
                })
                Text("words").font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
            }
            SettingsRow(title: "Start at login",
                        detail: system.loginNeedsApproval
                            ? "Allow it in System Settings, under Login Items." : nil) {
                Toggle("", isOn: launchBinding).labelsHidden().accessibilityLabel("Start at login")
            }
            SettingsRow(title: "Sound cues") {
                Toggle("", isOn: soundBinding).labelsHidden().accessibilityLabel("Sound cues")
            }
            SettingsRow(title: "Microphone") {
                PremiumStatusBadge(kind: system.microphone.kind, text: system.microphone.text)
                Button("Open System Settings") { UsefulVoiceViewModel.openPrivacyPane("Privacy_Microphone") }
                    .buttonStyle(.brandSecondary)
            }
            SettingsRow(title: "Accessibility") {
                PremiumStatusBadge(kind: system.accessibility.kind, text: system.accessibility.text)
                Button("Open System Settings") { UsefulVoiceViewModel.openPrivacyPane("Privacy_Accessibility") }
                    .buttonStyle(.brandSecondary)
            }
        }
    }

    // MARK: - Models

    private var modelsGroup: some View {
        SettingsGroup(id: "models", title: "Models") {
            ModelsLists(models: modelsVM) { entry in confirmation = .model(entry) }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let deleteError = viewModel.models.deleteError {
                    Text(deleteError).font(.uv(.meta)).foregroundStyle(Theme.danger).padding(.horizontal, 4)
                }
            }
        }
    }

    private var apiKeysGroup: some View {
        SettingsGroup(id: "keys", title: "API keys") {
            ForEach(KeyProvider.allCases, id: \.self) { provider in
                ApiKeyRow(provider: provider, models: modelsVM)
            }
        }
    }

    private func wireModels() {
        modelsVM.onChanged = { viewModel.refreshConfig() }
        modelsVM.onSaved = { saved() }
        modelsVM.onKeyError = { message in toasts.show(message, kind: .danger) }
        modelsVM.languagePin = { viewModel.languagePin }
        modelsVM.onShowKeys = {
            withAnimation(BrandMotion.resolved(BrandMotion.rise)) { topGroup = "keys" }
        }
    }

    // MARK: - Formatting

    private var formattingGroup: some View {
        SettingsGroup(id: "formatting", title: "Formatting") {
            SettingsRow(title: "Auto-format transcript") {
                Toggle("", isOn: formattingBinding).labelsHidden().accessibilityLabel("Auto-format transcript")
            }
            SettingsRow(title: "Speak punctuation",
                        detail: "English only. Say period, comma or new line.") {
                Toggle("", isOn: spokenPunctuationBinding).labelsHidden().accessibilityLabel("Speak punctuation")
            }
        } footer: {
            if settings.voiceModel.provider == "deepgram" {
                // Disclosed because it is charged and was previously invisible: the app sends
                // `keyterm` for every dictionary term, on every request, and Deepgram bills
                // Keyterm Prompting separately. https://deepgram.com/pricing
                SettingsFootnote(text: "Deepgram bills Keyterm Prompting separately: $0,0013 per minute "
                                 + "on top of $0,0043 per minute for Nova-3. That is about 30 % more per "
                                 + "minute while your dictionary is in use. Smart formatting and language "
                                 + "detection are included.")
            } else {
                SettingsFootnote(text: "Your voice model formats its own punctuation and capitalization, so "
                                 + "these two apply to Deepgram. Your dictionary still fixes mistakes afterwards.")
            }
        }
    }

    // MARK: - Hotkeys

    private var hotkeysGroup: some View {
        SettingsGroup(id: "hotkeys", title: "Hotkeys") {
            SettingsRow(title: "Dictation", detail: "Tap once to start and again to stop") {
                hotkeyControl(selection: hotkeyBinding, current: viewModel.hotkeyKeycode)
            }
            SettingsRow(title: "Language picker", detail: "Opens the language picker while you dictate") {
                hotkeyControl(selection: languageSwitchBinding, current: viewModel.languageSwitchKeycode)
            }
            SettingsRow(title: "Cancel dictation") {
                BrandKbd("Esc")
                Text("Fixed").font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    @ViewBuilder
    private func hotkeyControl(selection: Binding<Int>, current: Int) -> some View {
        if PreviewFeatures.enabled {
            HotkeyCaptureField(currentLabel: HotkeyOption.label(for: current)) { selection.wrappedValue = $0 }
        } else {
            BrandedMenuPicker(
                title: "Hotkey", selection: selection,
                options: HotkeyOption.all.map { ($0.label, $0.keycode) })
            .frame(width: 200)
        }
    }

    // MARK: - Appearance

    private var appearanceGroup: some View {
        SettingsGroup(id: "appearance", title: "Appearance") {
            SettingsRow(title: "Theme") {
                BrandedSegmentedControl(selection: appearanceBinding, options: [
                    (label: "System", value: AppearanceChoice.system),
                    (label: "Light", value: AppearanceChoice.light),
                    (label: "Dark", value: AppearanceChoice.dark),
                ])
                .frame(width: 240)
            }
        }
    }

    // MARK: - Data

    private var dataGroup: some View {
        SettingsGroup(id: "data", title: "Data") {
            SettingsRow(title: "Stop after silence") {
                // Not `step:`, which draws a tick for every stop; the value snaps to 5 instead.
                Slider(value: Binding(get: { silenceTimeout },
                                      set: { silenceTimeout = ($0 / 5).rounded() * 5 }),
                       in: 15...120) { editing in
                    if !editing { commitSilence() }
                }
                .frame(width: 180)
                Text("\(Int(silenceTimeout)) sec")
                    .font(.uv(.ui, .medium)).monospacedDigit().foregroundStyle(Theme.ink)
                    .frame(width: 56, alignment: .trailing)
            }
            SettingsRow(title: "Keep recordings",
                        detail: recordingsToKeep == 0 ? "Off. Retry needs a saved recording."
                            : "Lets you retry and reprocess the last \(recordingsToKeep).") {
                SettingsStepper(label: "Keep recordings", value: $recordingsToKeep, range: 0...50, onCommit: {
                    settings.recordingsToKeep = recordingsToKeep
                    viewModel.refreshConfig()
                    saved()
                })
            }
            SettingsRow(title: "Delete all dictations",
                        detail: dictationBusy ? "Finish or cancel the current dictation first." : nil) {
                Button {
                    confirmation = .allDictations(count: viewModel.historyStore.all().count)
                } label: {
                    Label("Delete all dictations...", systemImage: "trash")
                }
                .buttonStyle(.brandDanger)
                .disabled(system.dictationCount == 0 || dictationBusy)
            }
        }
    }

    // MARK: - Import and export

    private var importExportGroup: some View {
        SettingsGroup(id: "importExport", title: "Import and export") {
            SettingsRow(title: "Vocabulary backup") {
                fileButton("Export JSON", "square.and.arrow.down", exportVocabularyJSON)
                fileButton("Import JSON", "square.and.arrow.up", importVocabularyJSON)
            }
            SettingsRow(title: "Words") {
                fileButton("Export CSV", "square.and.arrow.down") {
                    export(viewModel.languageMemory.exportTermsCSV(), "useful-voice-words.csv", .commaSeparatedText)
                }
                fileButton("Import CSV", "square.and.arrow.up") {
                    importCSV { viewModel.languageMemory.importTermsCSV($0) }
                }
            }
            SettingsRow(title: "Fixes") {
                fileButton("Export CSV", "square.and.arrow.down") {
                    export(viewModel.languageMemory.exportReplacementsCSV(), "useful-voice-fixes.csv", .commaSeparatedText)
                }
                fileButton("Import CSV", "square.and.arrow.up") {
                    importCSV { viewModel.languageMemory.importReplacementsCSV($0) }
                }
            }
            SettingsRow(title: "Notes") {
                fileButton("Export Markdown", "square.and.arrow.down") {
                    export(viewModel.scratchpad.exportAllMarkdown(), "useful-voice-notes.md",
                           UTType(filenameExtension: "md") ?? .plainText)
                }
                fileButton("Export JSON", "square.and.arrow.down") {
                    export(viewModel.scratchpad.exportAllJSON(), "useful-voice-notes.json", .json)
                }
                fileButton("Import JSON", "square.and.arrow.up", importNotesJSON)
            }
        }
    }

    private func fileButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.brandSecondary)
    }

    private func export(_ text: String, _ name: String, _ type: UTType) {
        switch SettingsFiles.save(text, suggestedName: name, type: type) {
        case .done(let url): toasts.show("Exported \(url.lastPathComponent)")
        case .failed(let reason): toasts.show("Could not export. \(reason)", kind: .danger)
        case .cancelled: break
        }
    }

    /// The text of the file the person picked. A cancel is silent; a read failure is a toast.
    private func readFile(_ types: [UTType]) -> String? {
        switch SettingsFiles.open(types: types) {
        case .done(let text): return text
        case .failed(let reason):
            toasts.show("Could not import. \(reason)", kind: .danger)
            return nil
        case .cancelled: return nil
        }
    }

    private func exportVocabularyJSON() {
        export(viewModel.languageMemory.exportSnapshotJSON(), "useful-voice-vocabulary.json", .json)
    }

    private func importVocabularyJSON() {
        guard let json = readFile([.json]) else { return }
        guard let result = viewModel.languageMemory.importSnapshotJSON(json) else {
            toasts.show("The JSON backup could not be read.", kind: .danger)
            return
        }
        report(result)
    }

    private func importCSV(_ run: (String) -> LanguageMemoryImportResult) {
        guard let csv = readFile([.commaSeparatedText, .plainText]) else { return }
        report(run(csv))
    }

    private func report(_ result: LanguageMemoryImportResult) {
        var parts = ["Imported \(result.inserted)", "updated \(result.updated)"]
        if result.duplicates > 0 { parts.append("\(result.duplicates) already there") }
        if !result.invalid.isEmpty { parts.append("\(result.invalid.count) skipped") }
        toasts.show(parts.joined(separator: ", "), kind: result.invalid.isEmpty ? .success : .info)
    }

    private func importNotesJSON() {
        guard let json = readFile([.json]) else { return }
        guard let result = viewModel.scratchpad.importJSON(json) else {
            toasts.show("The JSON backup could not be read.", kind: .danger)
            return
        }
        var parts = ["Imported \(result.inserted)", "updated \(result.updated)"]
        if result.keptLocal > 0 { parts.append("\(result.keptLocal) kept as newer") }
        if !result.invalid.isEmpty { parts.append("\(result.invalid.count) skipped") }
        toasts.show(parts.joined(separator: ", "), kind: result.invalid.isEmpty ? .success : .info)
    }

    // MARK: - Diagnostics

    private var diagnosticsGroup: some View {
        SettingsGroup(id: "diagnostics", title: "Diagnostics") {
            SettingsBlock {
                if diagnostics.hasEntries {
                    ForEach(Array(diagnostics.entries.prefix(8).enumerated()), id: \.offset) { _, entry in
                        (Text(entry.level.rawValue.uppercased() + " ")
                            .foregroundStyle(entry.level == .error ? Theme.danger : Theme.ink)
                         + Text("\(entry.category) \(entry.message)").foregroundStyle(Theme.inkMuted))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Nothing recorded yet.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            SettingsRow(title: "Event log") {
                Button { diagnostics.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.brandSecondary)
                Button {
                    diagnostics.copyReport()
                    toasts.show(diagnostics.copyConfirmation ?? "Copied")
                } label: { Label("Copy report", systemImage: "doc.on.doc") }
                    .buttonStyle(.brandSecondary).disabled(!diagnostics.hasEntries)
                Button("Clear") {
                    diagnostics.clear()
                    toasts.show("Cleared")
                }
                .buttonStyle(.brandSecondary).disabled(!diagnostics.hasEntries)
            }
        }
        .onAppear { diagnostics.reload() }
    }

    // MARK: - About

    private var aboutGroup: some View {
        SettingsGroup(id: "about", title: "About") {
            SettingsRow(title: "Version") {
                Text(versionText).font(.uv(.ui)).foregroundStyle(Theme.ink).textSelection(.enabled)
            }
            SettingsRow(title: "Data folder", detail: "Readable only by you.") {
                Text((supportFolder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1).fixedSize()
                    .textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([supportFolder]) }
                    .buttonStyle(.brandSecondary)
            }
            SettingsRow(title: "Setup") {
                Button("Run setup again") { firstRun.restart() }
                    .buttonStyle(.brandSecondary)
            }
            ForEach(ReleaseLinks.links(), id: \.title) { link in
                SettingsRow(title: link.title) {
                    Button("Open") { NSWorkspace.shared.open(link.url) }
                        .buttonStyle(.brandSecondary)
                }
            }
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    // MARK: - Confirmation

    @ViewBuilder
    private var dialog: some View {
        switch confirmation {
        case .model(let model):
            SettingsConfirmDialog(
                title: "Delete \(model.name)?",
                message: "The weights file is removed from this Mac. You can download it again later.",
                confirmTitle: "Delete",
                onCancel: { confirmation = nil },
                onConfirm: {
                    modelsVM.delete(model)
                    confirmation = nil
                })
        case .allDictations(let count):
            SettingsConfirmDialog(
                title: "Delete all dictations?",
                message: "This removes \(InsightsFormat.grouped(count)) dictations and their saved recordings "
                    + "from this Mac. Notes and your vocabulary stay, and Insights keep your lifetime totals. "
                    + "You can't undo this.",
                confirmTitle: "Delete \(InsightsFormat.grouped(count)) dictations",
                onCancel: { confirmation = nil },
                onConfirm: {
                    deleteAllDictations(count: count)
                    confirmation = nil
                })
        case nil:
            EmptyView()
        }
    }

    /// True while a dictation is recording, transcribing or delivering: its audio is in use.
    private var dictationBusy: Bool {
        switch viewModel.dictationState {
        case .recording, .transcribing, .delivering: return true
        case .idle, .error: return false
        }
    }

    /// Clears the history, then the saved recordings. Notes, vocabulary and the lifetime
    /// usage totals behind Insights are not touched. The recordings are only deleted once the
    /// history clear has been saved: a failed save leaves both alone.
    private func deleteAllDictations(count: Int) {
        guard !dictationBusy else {
            toasts.show("Finish or cancel the current dictation first.", kind: .danger)
            return
        }
        viewModel.historyStore.clear()
        viewModel.refreshRecent()
        system.refreshCount()
        if let problem = viewModel.historyStore.lastSaveError {
            toasts.show("Could not delete the dictations: \(problem). Your recordings were kept.", kind: .danger)
            return
        }
        // The app's own folder, and the temporary one the store falls back to when the first
        // cannot be created.
        var failed = 0
        for folder in [supportFolder.appendingPathComponent("Recordings"),
                       FileManager.default.temporaryDirectory.appendingPathComponent("UsefulVoice-Recordings")] {
            failed += Self.removeRecordings(in: folder)
        }
        viewModel.recordingsDeleted()
        if failed > 0 {
            toasts.show("Deleted the dictations, but \(failed) recordings could not be removed.", kind: .danger)
        } else {
            toasts.show("Deleted \(InsightsFormat.grouped(count)) dictations", kind: .info)
        }
    }

    /// Removes the .wav and .txt files in a recordings folder. Returns how many it could not.
    private static func removeRecordings(in folder: URL) -> Int {
        guard FileManager.default.fileExists(atPath: folder.path) else { return 0 }
        var failed = 0
        do {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            for file in files where ["wav", "txt"].contains(file.pathExtension) {
                do { try FileManager.default.removeItem(at: file) } catch {
                    failed += 1
                    Diagnostics.shared.error("settings", "could not delete \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            failed += 1
            Diagnostics.shared.error("settings", "could not list \(folder.lastPathComponent): \(error.localizedDescription)")
        }
        return failed
    }

    // MARK: - Bindings that save

    private var languageBinding: Binding<LanguagePin> {
        Binding(
            get: { viewModel.languagePin },
            set: {
                settings.languagePin = $0
                viewModel.refreshConfig()
                saved()
            })
    }

    private var hotkeyBinding: Binding<Int> {
        Binding(get: { viewModel.hotkeyKeycode },
                set: { viewModel.setHotkeyKeycode($0); saved() })
    }

    private var languageSwitchBinding: Binding<Int> {
        Binding(get: { viewModel.languageSwitchKeycode },
                set: { viewModel.setLanguageSwitchKeycode($0); saved() })
    }

    private var formattingBinding: Binding<Bool> {
        Binding(get: { formattingEnabled },
                set: { formattingEnabled = $0; settings.formattingEnabled = $0; saved() })
    }

    private var spokenPunctuationBinding: Binding<Bool> {
        Binding(get: { spokenPunctuationEnabled },
                set: { spokenPunctuationEnabled = $0; settings.spokenPunctuationEnabled = $0; saved() })
    }

    private var soundBinding: Binding<Bool> {
        Binding(get: { soundEffectsEnabled },
                set: { soundEffectsEnabled = $0; settings.soundEffectsEnabled = $0; saved() })
    }

    private var appearanceBinding: Binding<AppearanceChoice> {
        Binding(get: { appearance },
                set: { appearance = $0; settings.appearance = $0; saved() })
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { system.launchAtLogin },
            set: { newValue in
                do {
                    try LoginItem.setEnabled(newValue)
                    system.refresh()
                    saved()
                } catch {
                    toasts.show("Could not update the login setting", kind: .danger)
                }
            })
    }

    private func commitSilence() {
        settings.silenceTimeout = silenceTimeout
        viewModel.refreshConfig()
        saved()
    }

    // MARK: - Load and sync

    private func syncFromFirstRun() {
        modelsVM.reload()
    }

    private func load() {
        // Existence-only checks: they never return or decrypt a key, so they cannot block this
        // main-thread SwiftUI update on an authorization prompt. A sample render keeps its sample.
        if SettingsSnapshot.state == nil { modelsVM.reload() }
        formattingEnabled = settings.formattingEnabled
        spokenPunctuationEnabled = settings.spokenPunctuationEnabled
        silenceTimeout = settings.silenceTimeout
        recordingsToKeep = settings.recordingsToKeep
        soundEffectsEnabled = settings.soundEffectsEnabled
        appearance = settings.appearance
        dailyGoal = settings.dailyWordGoal
        system.refresh()
    }

}

/// What a permission row says.
private enum PermissionState {
    case unknown, allowed, notAsked, blocked, pastesCopyOnly

    var kind: PremiumStatusBadge.Kind {
        switch self {
        case .allowed: return .ok
        case .notAsked, .pastesCopyOnly, .unknown: return .warn
        case .blocked: return .bad
        }
    }

    var text: String {
        switch self {
        case .allowed: return "Allowed"
        case .notAsked: return "Not asked yet"
        case .blocked: return "Blocked"
        case .pastesCopyOnly: return "Off, pastes become copy only"
        case .unknown: return "Checking"
        }
    }
}

/// What the page reads from the system and the history. Created once with the page, and read
/// again on appear, when the app comes forward and when a dictation lands.
@MainActor
private final class SettingsSystemState: ObservableObject {
    @Published var launchAtLogin = false
    @Published var loginNeedsApproval = false
    @Published var microphone = PermissionState.unknown
    @Published var accessibility = PermissionState.unknown
    @Published var dictationCount = 0

    private let history: DictationHistory

    init(history: DictationHistory) {
        self.history = history
        refresh()
    }

    func refresh() {
        let login = LoginItem.status
        launchAtLogin = login.isOn
        loginNeedsApproval = login.needsUserApproval
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .allowed
        case .notDetermined: microphone = .notAsked
        default: microphone = .blocked
        }
        accessibility = AXIsProcessTrusted() ? .allowed : .pastesCopyOnly
        refreshCount()
    }

    func refreshCount() {
        dictationCount = history.all().count
    }
}
