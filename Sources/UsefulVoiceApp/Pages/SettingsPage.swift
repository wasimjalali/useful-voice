import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices
import UniformTypeIdentifiers
import UsefulVoiceCore

/// Settings as one scrolling page with a left index. Every control saves the moment it
/// changes and says so with a quiet "Saved" toast; the Deepgram key keeps its own Save key
/// and Test connection. `anchor` scrolls to a group (see `groups`) and is then cleared.
struct SettingsPage: View {
    let settings: AppSettings
    @ObservedObject var viewModel: UsefulVoiceViewModel
    /// The same manager instance the app layer wired up, observed here so download
    /// progress and availability redraw this page live.
    @ObservedObject private var models: LocalModelManager
    @ObservedObject var firstRun: FirstRunModel
    @Binding var anchor: String?
    @EnvironmentObject private var toasts: AppToastCenter

    @State private var engine: TranscriptionEngineChoice = .deepgram
    @State private var deepgramKey = ""
    @State private var hasDeepgramKey = false
    @State private var changingDeepgramKey = false
    /// A key save or removal is running: the key controls stay disabled so a second
    /// click can't start another one.
    @State private var savingKey = false
    @State private var formattingEnabled = true
    @State private var spokenPunctuationEnabled = false
    @State private var silenceTimeout = 60.0
    @State private var recordingsToKeep = 10
    @State private var soundEffectsEnabled = true
    @State private var launchAtLogin = false
    @State private var appearance: AppearanceChoice = .system
    @State private var dailyGoal = AppSettings.defaultDailyWordGoal
    @State private var isTesting = false
    @State private var testResult: ProviderHealthResult?
    @State private var microphone = PermissionState.unknown
    @State private var accessibility = PermissionState.unknown
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
        let requested = anchor.wrappedValue ?? SettingsSnapshot.anchor
        if let requested, Self.groups.contains(where: { $0.id == requested }) {
            _topGroup = State(initialValue: requested)
        }
        _models = ObservedObject(wrappedValue: viewModel.models)
        // Read up front as well as in `load()`: a page that is rendered before it appears
        // (an offscreen snapshot) never gets its onAppear.
        _engine = State(initialValue: settings.transcriptionEngine)
        _hasDeepgramKey = State(initialValue: DeepgramKeyStore.shared.isConfigured())
        _formattingEnabled = State(initialValue: settings.formattingEnabled)
        _spokenPunctuationEnabled = State(initialValue: settings.spokenPunctuationEnabled)
        _silenceTimeout = State(initialValue: settings.silenceTimeout)
        _recordingsToKeep = State(initialValue: settings.recordingsToKeep)
        _soundEffectsEnabled = State(initialValue: settings.soundEffectsEnabled)
        _launchAtLogin = State(initialValue: LoginItem.isEnabled)
        _appearance = State(initialValue: settings.appearance)
        _dailyGoal = State(initialValue: settings.dailyWordGoal)
        _microphone = State(initialValue: Self.microphoneState())
        _accessibility = State(initialValue: Self.accessibilityState())
        switch SettingsSnapshot.state {
        case "noKey":
            _hasDeepgramKey = State(initialValue: false)
        case "invalidKey":
            _hasDeepgramKey = State(initialValue: true)
            _changingDeepgramKey = State(initialValue: true)
            _deepgramKey = State(initialValue: "dg_invalid_key_for_snapshot")
            _testResult = State(initialValue: ProviderHealthResult(
                providerName: "Deepgram", ok: false, latencyMilliseconds: nil,
                message: "Deepgram rejected this key.", redactedEndpoint: "", failure: .rejected))
        case "confirmDelete":
            _confirmation = State(initialValue: .allDictations(count: viewModel.historyStore.all().count))
        default:
            break
        }
    }

    static let groups: [(id: String, title: String)] = [
        ("general", "General"), ("engine", "Engine"), ("formatting", "Formatting"),
        ("hotkeys", "Hotkeys"), ("appearance", "Appearance"), ("data", "Data"),
        ("importExport", "Import and export"), ("diagnostics", "Diagnostics"), ("about", "About"),
    ]

    private enum Confirmation: Equatable {
        case model(WhisperModel)
        case allDictations(count: Int)
    }

    /// The Deepgram listen endpoint, shown (redacted) in the connection test.
    private let deepgramEndpoint = "https://api.deepgram.com/v1/listen"

    /// Where the app keeps its data. The folder keeps the app's earlier name.
    private var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sadaa")
    }

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
        .background(Theme.surface)
        .overlay { dialog }
        .onAppear(perform: load)
        // The setup flow can change the engine and the key: re-read only those, so edits
        // elsewhere on the page survive. (AppSettings is not observable, so the end of the
        // flow is the signal.)
        .onChange(of: firstRun.active) { _, active in
            if !active { syncFromFirstRun() }
        }
        // A key saved mid-flow, or an engine put back when the window closed on a first
        // launch, can land while the flow is still marked active.
        .onChange(of: firstRun.keyConnected) { _, _ in syncFromFirstRun() }
        .onChange(of: firstRun.engineRestoreCount) { _, _ in syncFromFirstRun() }
        // A key typed and abandoned must not sit in memory behind a closed editor.
        .onChange(of: changingDeepgramKey) { _, open in
            if !open { deepgramKey = "" }
        }
        // Permissions change in System Settings, so look again when the app comes forward.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private var form: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    generalGroup
                    engineGroup
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
            .onChange(of: anchor) { _, requested in
                guard let requested else { return }
                if Self.groups.contains(where: { $0.id == requested }) {
                    withAnimation(BrandMotion.resolved(BrandMotion.rise)) { topGroup = requested }
                }
                anchor = nil
            }
            // A group asked for before the page existed: the position was set at init. Set it
            // again once the page is laid out (the first value can land before there is
            // anything to scroll), then clear the request.
            .task {
                guard let requested = anchor ?? SettingsSnapshot.anchor,
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
                SettingsStepper(value: $dailyGoal, range: 100...1_000_000, step: 100,
                                format: SettingsFormat.number, editable: true, onCommit: {
                    settings.dailyWordGoal = dailyGoal
                    viewModel.refreshUsage()
                    saved()
                })
                Text("words").font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
            }
            SettingsRow(title: "Start at login",
                        detail: LoginItem.status.needsUserApproval
                            ? "Allow it in System Settings, under Login Items." : nil) {
                Toggle("", isOn: launchBinding).labelsHidden().accessibilityLabel("Start at login")
            }
            SettingsRow(title: "Sound cues") {
                Toggle("", isOn: soundBinding).labelsHidden().accessibilityLabel("Sound cues")
            }
            SettingsRow(title: "Microphone") {
                PremiumStatusBadge(kind: microphone.kind, text: microphone.text)
                Button("Open System Settings") { UsefulVoiceViewModel.openPrivacyPane("Privacy_Microphone") }
                    .buttonStyle(.brandSecondary).clickableCursor()
            }
            SettingsRow(title: "Accessibility") {
                PremiumStatusBadge(kind: accessibility.kind, text: accessibility.text)
                Button("Open System Settings") { UsefulVoiceViewModel.openPrivacyPane("Privacy_Accessibility") }
                    .buttonStyle(.brandSecondary).clickableCursor()
            }
        }
    }

    // MARK: - Engine

    private var engineGroup: some View {
        SettingsGroup(id: "engine", title: "Engine") {
            SettingsRow(title: "Engine") {
                BrandedSegmentedControl(selection: engineBinding, options: [
                    (label: "Deepgram Nova-3", value: TranscriptionEngineChoice.deepgram),
                    (label: "Whisper (local)", value: TranscriptionEngineChoice.whisperLocal),
                ])
                .frame(width: 280)
            }
            deepgramKeyRows
            ForEach(models.models) { model in
                modelRows(model)
            }
            if engine == .whisperLocal {
                SettingsRow(title: "Test engine", detail: testStatusText(for: .whisperLocal),
                            detailTone: testStatusTone) {
                    Button(isTesting ? "Testing" : "Test connection") { testConnection() }
                        .buttonStyle(.brandSecondary).disabled(isTesting).clickableCursor()
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if let deleteError = models.deleteError {
                    Text(deleteError).font(.uv(.meta)).foregroundStyle(Theme.danger).padding(.horizontal, 4)
                }
                if engine == .whisperLocal, models.availability(of: models.activeModel) != .usable {
                    SettingsFootnote(text: "\(models.activeModel.displayName) is not downloaded yet. "
                                     + "Dictation with Whisper (local) will ask you to download it first.")
                }
                if engine == .whisperLocal {
                    SettingsFootnote(text: "\(models.diskSummary).")
                }
            }
        }
    }

    // MARK: Deepgram key

    @ViewBuilder
    private var deepgramKeyRows: some View {
        let rejected = testResult?.ok == false && testResult?.failure == .rejected
        if changingDeepgramKey {
            SettingsRow(title: "Deepgram key", detail: hasDeepgramKey ? "Stored in Keychain" : nil) {
                SecureField("Paste your API key", text: $deepgramKey)
                    .premiumInputChrome(error: rejected)
                    .frame(width: 230)
                    .disabled(savingKey)
                    .onSubmit(saveKey)
                Button("Save key") { saveKey() }
                    .buttonStyle(.brandPrimary).disabled(savingKey).clickableCursor()
                if hasDeepgramKey {
                    Button("Remove") { removeKey() }
                        .buttonStyle(.brandDanger).disabled(savingKey).clickableCursor()
                }
                Button("Cancel") { changingDeepgramKey = false }
                    .buttonStyle(.brandSecondary).disabled(savingKey).clickableCursor()
            }
            keyStatusRow
        } else if hasDeepgramKey {
            SettingsRow(title: "Deepgram key", detail: "Stored in Keychain") {
                keyBadge
                Button(isTesting ? "Testing" : "Test connection") { testConnection() }
                    .buttonStyle(.brandSecondary).disabled(isTesting).clickableCursor()
                Button("Change key") { changingDeepgramKey = true }
                    .buttonStyle(.brandSecondary).disabled(savingKey).clickableCursor()
            }
            keyStatusRow
        } else {
            SettingsRow(title: "Deepgram key") {
                Text("No key added").font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                Button("Add key") { changingDeepgramKey = true }
                    .buttonStyle(.brandPrimary).clickableCursor()
                Button("Get free credit") { openSignup() }
                    .buttonStyle(.brandSecondary).clickableCursor()
            }
            keyStatusRow
        }
    }

    /// The result of the last connection test, as a badge on the key row.
    @ViewBuilder
    private var keyBadge: some View {
        if let result = testResult, engine == .deepgram || result.providerName == "Deepgram" {
            if result.ok {
                PremiumStatusBadge(kind: .ok, icon: "circle.fill",
                                   text: "Connected, \(result.latencyMilliseconds ?? 0) ms")
            } else if result.failure == .rejected {
                PremiumStatusBadge(kind: .bad, icon: "circle.fill", text: "Deepgram rejected this key")
            } else {
                PremiumStatusBadge(kind: .bad, icon: "circle.fill", text: "Could not connect")
            }
        } else {
            PremiumStatusBadge(kind: .ok, icon: "circle.fill", text: "Key saved")
        }
    }

    /// What a failed test said, and a stored key that could not be read. A key that cannot
    /// be read is not the same as no key: re-entering it would overwrite one that is
    /// probably still fine.
    @ViewBuilder
    private var keyStatusRow: some View {
        if changingDeepgramKey, testResult?.ok == false, testResult?.failure == .rejected {
            SettingsBlock(padding: EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16)) {
                HStack {
                    Spacer(minLength: 0)
                    PremiumStatusBadge(kind: .bad, icon: "circle.fill", text: "Deepgram rejected this key")
                }
            }
        }
        if let result = testResult, !result.ok, result.failure != .rejected, result.providerName == "Deepgram" {
            SettingsBlock(padding: EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16)) {
                Text(result.message).font(.uv(.meta)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let problem = DeepgramKeyStore.shared.lookupProblem {
            SettingsBlock(padding: EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16)) {
                Text("Your saved Deepgram key could not be read: \(problem). Unlock your login keychain and reopen Settings, or enter the key again to replace it.")
                    .font(.uv(.meta)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func testStatusText(for engine: TranscriptionEngineChoice) -> String? {
        guard let result = testResult, result.providerName != "Deepgram" else { return nil }
        return result.ok ? "Connected in \(result.latencyMilliseconds ?? 0) ms." : result.message
    }

    private var testStatusTone: Color {
        testResult.map { $0.ok ? Theme.success : Theme.danger } ?? Theme.inkMuted
    }

    // MARK: Models

    private func modelName(_ model: WhisperModel) -> String {
        model.id.replacingOccurrences(of: "whisper-", with: "")
    }

    @ViewBuilder
    private func modelRows(_ model: WhisperModel) -> some View {
        let state = models.state(for: model)
        let availability = models.availability(of: model)
        let inUse = engine == .whisperLocal && models.isActive(model)
        switch state {
        case .downloading(let received, let total):
            SettingsBlock {
                modelHeader(model) {
                    Button { models.pause(model) } label: {
                        Label("Pause", systemImage: "pause").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.brandSecondary).clickableCursor()
                }
                InsightsMeter(fraction: Double(received) / Double(max(total, 1)), height: 4)
                HStack {
                    Text("\(SettingsFormat.mb(received)) of \(SettingsFormat.gb(total))")
                    Spacer()
                    Text(InsightsFormat.percent(Double(received) / Double(max(total, 1))))
                }
                .font(.uv(.meta)).monospacedDigit().foregroundStyle(Theme.inkMuted)
            }
        case .validating:
            SettingsBlock {
                modelHeader(model) { ProgressView().controlSize(.small) }
                Text("Verifying checksum").font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
            }
        case .paused:
            SettingsBlock {
                modelHeader(model) {
                    Button(models.canResume(model) ? "Resume" : "Download") { models.download(model) }
                        .buttonStyle(.brandPrimary).clickableCursor()
                }
            }
        case .failed(let message, _):
            SettingsBlock {
                modelHeader(model) {
                    PremiumStatusBadge(kind: .bad, icon: "circle.fill", text: "Download failed")
                    Button("Try again") { models.download(model) }
                        .buttonStyle(.brandSecondary).clickableCursor()
                }
                Text(message).font(.uv(.meta)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .idle:
            switch availability {
            case .usable:
                SettingsBlock(padding: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)) {
                    modelHeader(model) {
                        if inUse {
                            PremiumStatusBadge(kind: .ok, icon: "circle.fill", text: "In use")
                        } else {
                            Button("Use") { useModel(model) }
                                .buttonStyle(.brandSecondary).clickableCursor()
                        }
                        Button("Delete") { confirmation = .model(model) }
                            .buttonStyle(.brandDanger).clickableCursor()
                    }
                    .frame(minHeight: 32)
                }
            case .missing:
                SettingsBlock(padding: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)) {
                    modelHeader(model) {
                        Button { models.download(model) } label: {
                            Label(models.canResume(model) ? "Resume" : "Download", systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(.brandPrimary).clickableCursor()
                    }
                    .frame(minHeight: 32)
                }
            case .invalid(let reason):
                SettingsBlock {
                    modelHeader(model) {
                        PremiumStatusBadge(kind: .bad, icon: "circle.fill", text: "Check failed")
                        Button("Download again") { models.download(model) }
                            .buttonStyle(.brandSecondary).clickableCursor()
                        Button("Delete") { confirmation = .model(model) }
                            .buttonStyle(.brandDanger).clickableCursor()
                    }
                    Text("The file didn't pass its check (\(reason)). Download it again.")
                        .font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func modelHeader<Trailing: View>(_ model: WhisperModel,
                                             @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(modelName(model)).font(.uv(.ui, .semibold)).foregroundStyle(Theme.ink)
            Text(SettingsFormat.gb(model.expectedBytes)).font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
            Spacer(minLength: 12)
            trailing()
        }
        .accessibilityElement(children: .contain)
    }

    /// A model that is on this Mac becomes the engine.
    private func useModel(_ model: WhisperModel) {
        models.activate(model)
        engineBinding.wrappedValue = .whisperLocal
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
            if engine == .deepgram {
                // Disclosed because it is charged and was previously invisible: the app sends
                // `keyterm` for every dictionary term, on every request, and Deepgram bills
                // Keyterm Prompting separately. https://deepgram.com/pricing
                SettingsFootnote(text: "Deepgram bills Keyterm Prompting separately: $0,0013 per minute "
                                 + "on top of $0,0043 per minute for Nova-3. That is about 30 % more per "
                                 + "minute while your dictionary is in use. Smart formatting and language "
                                 + "detection are included.")
            } else {
                SettingsFootnote(text: "Whisper (local) formats its own punctuation and capitalization, so "
                                 + "these two apply to Deepgram. Your dictionary still biases recognition "
                                 + "and fixes mistakes afterwards.")
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
                SettingsStepper(value: $recordingsToKeep, range: 0...50, onCommit: {
                    settings.recordingsToKeep = recordingsToKeep
                    viewModel.refreshConfig()
                    saved()
                })
            }
            SettingsRow(title: "Delete all dictations") {
                let count = viewModel.historyStore.all().count
                Button {
                    confirmation = .allDictations(count: count)
                } label: {
                    Label("Delete all dictations...", systemImage: "trash")
                }
                .buttonStyle(.brandDanger)
                .disabled(count == 0)
                .clickableCursor()
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
            .clickableCursor()
    }

    private func export(_ text: String, _ name: String, _ type: UTType) {
        if let url = SettingsFiles.save(text, suggestedName: name, type: type) {
            toasts.show("Exported \(url.lastPathComponent)")
        }
    }

    private func exportVocabularyJSON() {
        export(viewModel.languageMemory.exportSnapshotJSON(), "useful-voice-vocabulary.json", .json)
    }

    private func importVocabularyJSON() {
        guard let json = SettingsFiles.open(types: [.json]) else { return }
        guard let result = viewModel.languageMemory.importSnapshotJSON(json) else {
            toasts.show("The JSON backup could not be read.", kind: .danger)
            return
        }
        report(result)
    }

    private func importCSV(_ run: (String) -> LanguageMemoryImportResult) {
        guard let csv = SettingsFiles.open(types: [.commaSeparatedText, .plainText]) else { return }
        report(run(csv))
    }

    private func report(_ result: LanguageMemoryImportResult) {
        var parts = ["Imported \(result.inserted)", "updated \(result.updated)"]
        if result.duplicates > 0 { parts.append("\(result.duplicates) already there") }
        if !result.invalid.isEmpty { parts.append("\(result.invalid.count) skipped") }
        toasts.show(parts.joined(separator: ", "), kind: result.invalid.isEmpty ? .success : .info)
    }

    private func importNotesJSON() {
        guard let json = SettingsFiles.open(types: [.json]) else { return }
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
                    .buttonStyle(.brandSecondary).clickableCursor()
                Button {
                    diagnostics.copyReport()
                    toasts.show(diagnostics.copyConfirmation ?? "Copied")
                } label: { Label("Copy report", systemImage: "doc.on.doc") }
                    .buttonStyle(.brandSecondary).disabled(!diagnostics.hasEntries).clickableCursor()
                Button("Clear") {
                    diagnostics.clear()
                    toasts.show("Cleared")
                }
                .buttonStyle(.brandSecondary).disabled(!diagnostics.hasEntries).clickableCursor()
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
                    .buttonStyle(.brandSecondary).clickableCursor()
            }
            SettingsRow(title: "Setup") {
                Button("Run setup again") { firstRun.restart() }
                    .buttonStyle(.brandSecondary).clickableCursor()
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
                title: "Delete \(modelName(model))?",
                message: "The weights file is removed from this Mac. You can download it again later.",
                confirmTitle: "Delete",
                onCancel: { confirmation = nil },
                onConfirm: {
                    models.delete(model)
                    viewModel.refreshConfig()
                    confirmation = nil
                })
        case .allDictations(let count):
            SettingsConfirmDialog(
                title: "Delete all dictations?",
                message: "This removes \(InsightsFormat.grouped(count)) dictations and their saved recordings "
                    + "from this Mac. Notes and your vocabulary stay. You can't undo this.",
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

    /// Clears the history and the saved recordings. Notes, vocabulary and the lifetime usage
    /// totals behind Insights are not touched.
    private func deleteAllDictations(count: Int) {
        viewModel.historyStore.clear()
        viewModel.refreshRecent()
        var failed = 0
        let folder = supportFolder.appendingPathComponent("Recordings")
        if FileManager.default.fileExists(atPath: folder.path) {
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
                Diagnostics.shared.error("settings", "could not list recordings: \(error.localizedDescription)")
            }
        }
        if let problem = viewModel.historyStore.lastSaveError {
            toasts.show("Could not delete the dictations: \(problem)", kind: .danger)
        } else if failed > 0 {
            toasts.show("Deleted the dictations, but \(failed) recordings could not be removed.", kind: .danger)
        } else {
            toasts.show("Deleted \(InsightsFormat.grouped(count)) dictations", kind: .info)
        }
    }

    // MARK: - Bindings that save

    private var engineBinding: Binding<TranscriptionEngineChoice> {
        Binding(
            get: { engine },
            set: { newValue in
                // Deepgram without a key opens the key field instead of switching to an
                // engine that cannot run.
                if newValue == .deepgram, !hasDeepgramKey {
                    changingDeepgramKey = true
                    return
                }
                engine = newValue
                settings.transcriptionEngine = newValue
                models.engineChanged(to: newValue)
                viewModel.refreshConfig()
                saved()
            })
    }

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
            get: { launchAtLogin },
            set: { newValue in
                do {
                    try LoginItem.setEnabled(newValue)
                    launchAtLogin = newValue
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
        hasDeepgramKey = DeepgramKeyStore.shared.isConfigured()
        engine = settings.transcriptionEngine
    }

    private func load() {
        // Existence-only check: never returns or decrypts the key, so it cannot block this
        // main-thread SwiftUI update on an authorization prompt.
        hasDeepgramKey = DeepgramKeyStore.shared.isConfigured()
        engine = settings.transcriptionEngine
        models.refreshAvailability()
        formattingEnabled = settings.formattingEnabled
        spokenPunctuationEnabled = settings.spokenPunctuationEnabled
        silenceTimeout = settings.silenceTimeout
        recordingsToKeep = settings.recordingsToKeep
        soundEffectsEnabled = settings.soundEffectsEnabled
        launchAtLogin = LoginItem.isEnabled
        appearance = settings.appearance
        dailyGoal = settings.dailyWordGoal
        refreshPermissions()
    }

    private func refreshPermissions() {
        microphone = Self.microphoneState()
        accessibility = Self.accessibilityState()
    }

    private static func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .blocked
        }
    }

    private static func accessibilityState() -> PermissionState {
        AXIsProcessTrusted() ? .allowed : .pastesCopyOnly
    }

    // MARK: - Deepgram key actions

    private func openSignup() {
        guard let url = URL(string: "https://console.deepgram.com/signup?jump=keys") else { return }
        NSWorkspace.shared.open(url)
    }

    private func saveKey() {
        guard !savingKey else { return }
        let trimmedKey = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }
        // The store writes the keychain and refreshes the cache the dictation pipeline reads
        // in one ordered step, so the new key works without a relaunch and a stale write can
        // never overwrite a newer one.
        savingKey = true
        Task { @MainActor in
            defer { savingKey = false }
            do {
                try await DeepgramKeyStore.shared.save(trimmedKey)
                hasDeepgramKey = true
                // Only the text that was saved is cleared: anything else in the field is a
                // newer edit.
                if deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedKey {
                    deepgramKey = ""
                    changingDeepgramKey = false
                }
                viewModel.refreshConfig()
                saved()
                // Say right away whether Deepgram accepts it.
                if engine == .deepgram { testConnection() }
            } catch {
                toasts.show("Could not save the Keychain value", kind: .danger)
            }
        }
    }

    private func removeKey() {
        guard !savingKey else { return }
        savingKey = true
        Task { @MainActor in
            defer { savingKey = false }
            do {
                try await DeepgramKeyStore.shared.remove()
                hasDeepgramKey = false
                changingDeepgramKey = false
                testResult = nil
                viewModel.refreshConfig()
                saved()
            } catch {
                toasts.show("Couldn't remove the key from your Keychain. Try again.", kind: .danger)
            }
        }
    }

    private func testConnection() {
        testResult = nil
        isTesting = true
        if engine == .whisperLocal {
            testLocalEngine()
            return
        }
        Task {
            let typed = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
            // Read the stored key off the main actor: the keychain call can block on
            // securityd or on a user authorization prompt.
            //
            // `lookup` rather than `get`, because a stored key that cannot be read is not the
            // same as no key: reporting "Enter your Deepgram API key" when the truth is a
            // locked keychain sends the user to re-enter a credential that is already there
            // and fine. Through the store, so the read is ordered with key saves and removals,
            // but as a peek: a test must never change the key dictation uses. A typed key is
            // tested as is, with no keychain read at all.
            let lookup: Keychain.Lookup = typed.isEmpty
                ? await Task.detached(priority: .userInitiated) {
                    DeepgramKeyStore.shared.peek()
                }.value
                : .absent
            let key = typed.isEmpty ? (lookup.value ?? "") : typed
            guard !key.isEmpty else {
                let message: String
                switch lookup {
                case .unavailable(let reason) where typed.isEmpty:
                    message = "Your saved key could not be read (\(reason)). Unlock your login keychain and try again, or enter the key to replace it."
                default:
                    message = "Enter your Deepgram API key."
                }
                await MainActor.run {
                    testResult = ProviderHealthCheck.result(
                        providerName: "Deepgram",
                        endpoint: deepgramEndpoint,
                        ok: false,
                        startedAt: Date(),
                        finishedAt: Date(),
                        message: message)
                    isTesting = false
                }
                return
            }
            let provider = DeepgramProvider(config: .init(
                apiKey: key,
                smartFormat: formattingEnabled,
                spokenPunctuation: spokenPunctuationEnabled))
            let result = await ProviderHealthCheck.check(
                provider: provider,
                endpoint: deepgramEndpoint,
                hint: TranscriptionHint(languagePin: viewModel.languagePin, dictionaryWords: []))
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
    }

    /// Probes the local engine with the same health-check path as Deepgram: a tiny generated
    /// clip through the real provider. First run also loads the model, so it doubles as a
    /// "does the engine actually work" test.
    private func testLocalEngine() {
        Task {
            guard let provider = viewModel.makeTranscriptionProvider?() else {
                await MainActor.run {
                    testResult = ProviderHealthCheck.result(
                        providerName: "Whisper (local)",
                        endpoint: "on-device",
                        ok: false,
                        startedAt: Date(),
                        finishedAt: Date(),
                        message: "No local provider could be built.")
                    isTesting = false
                }
                return
            }
            let result = await ProviderHealthCheck.check(
                provider: provider,
                endpoint: "on-device",
                hint: TranscriptionHint(languagePin: viewModel.languagePin, dictionaryWords: []))
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
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
