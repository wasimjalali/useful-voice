import SwiftUI
import AppKit
import UsefulVoiceCore

struct SettingsPage: View {
    let settings: AppSettings
    @ObservedObject var viewModel: UsefulVoiceViewModel
    /// The same manager instance the app layer wired up — observed here so
    /// download progress and availability redraw this page live.
    @ObservedObject private var models: LocalModelManager

    @State private var engine: TranscriptionEngineChoice = .deepgram
    @State private var deepgramKey = ""
    @State private var hasDeepgramKey = false
    @State private var formattingEnabled = true
    @State private var spokenPunctuationEnabled = false
    /// Set when the user asks to delete a model, driving the confirmation.
    @State private var modelPendingDeletion: WhisperModel?

    @State private var silenceTimeout = 60.0
    @State private var recordingsToKeep = 10
    @State private var soundEffectsEnabled = true
    @State private var launchAtLogin = false

    @State private var saveMessage = ""
    @State private var saveIsError = false
    @State private var isTesting = false
    @State private var testResult: ProviderHealthResult?
    @StateObject private var diagnostics = DiagnosticsViewModel()

    init(settings: AppSettings, viewModel: UsefulVoiceViewModel) {
        self.settings = settings
        self.viewModel = viewModel
        _models = ObservedObject(wrappedValue: viewModel.models)
    }

    /// The Deepgram listen endpoint, shown (redacted) in the connection test.
    private let deepgramEndpoint = "https://api.deepgram.com/v1/listen"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statusLine
                generalSection
                speechSection
                dataSection
                diagnosticsSection
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .pageColumn(maxWidth: 920)
        }
        .background(Theme.surface)
        .onAppear(perform: load)
        .confirmationDialog(
            "Delete \(modelPendingDeletion?.displayName ?? "model")?",
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let model = modelPendingDeletion {
                    models.delete(model)
                    viewModel.refreshConfig()
                }
                modelPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { modelPendingDeletion = nil }
        } message: {
            Text("The weights file is removed from this Mac. You can download it again later.")
        }
    }

    private var header: some View {
        CommandPageHeader(
            title: "Settings"
        ) {
            WrappingHStack(horizontalSpacing: 10, verticalSpacing: 8) {
                Button(isTesting ? "Testing" : "Test connection") { testConnection() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brand)
                    .controlSize(.large)
                    .clickableCursor()
                    .disabled(isTesting)
                Button("Save settings") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .controlSize(.large)
                    .clickableCursor()
            }
        }
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(viewModel.providerConfigured ? Theme.success : Theme.warning)
                    .frame(width: 8, height: 8)
                Text(viewModel.providerConfigured
                     ? "\(viewModel.providerName) is ready"
                     : "Speech provider needs setup")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if !saveMessage.isEmpty {
                    Text(saveMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(saveIsError ? Theme.danger : Theme.success)
                }
            }

            if let result = testResult {
                Text(result.ok
                     ? "Connected to \(result.providerName) in \(result.latencyMilliseconds ?? 0) ms."
                     : result.message)
                    .font(.system(size: 12))
                    .foregroundStyle(result.ok ? Theme.success : Theme.danger)
            }

            // A stored key that cannot be read is NOT the same as no key, and the
            // user's next move is different: re-entering it would overwrite a key
            // that is probably still fine. Say what actually happened.
            if let problem = DeepgramKeyStore.shared.lookupProblem {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.danger)
                    Text("Your saved Deepgram key could not be read: \(problem). Unlock your login keychain and reopen Settings, or enter the key again to replace it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Says what the current selection actually does. The old copy hardcoded
    /// "Auto-detect, English or German", which became wrong the moment the
    /// catalogue grew.
    private var languageDetail: String {
        let pin = viewModel.languagePin
        if pin.isAuto {
            return "Detects the language as you speak, from \(DeepgramLanguageCatalog.all.count) supported languages"
        }
        return "Transcribing \(pin.displayName). Use the language hotkey to change it."
    }

    private var generalSection: some View {
        settingsSection(title: "General") {
            VStack(spacing: 16) {
                settingsRow("Language", detail: languageDetail) {
                    LanguagePickerButton(selection: languageBinding)
                        .frame(width: 190)
                }

                Divider().overlay(Theme.line)

                settingsRow("Dictation hotkey", detail: "Tap once to start and again to stop") {
                    hotkeyPicker(selection: hotkeyBinding)
                }

                settingsRow("Language hotkey", detail: "Opens the language picker while you dictate") {
                    hotkeyPicker(selection: languageSwitchBinding)
                }

                Divider().overlay(Theme.line)

                settingsRow("Start at login", detail: "Keep Useful Voice ready in the menu bar") {
                    Toggle("", isOn: launchBinding).labelsHidden()
                }
                settingsRow("Sound cues", detail: "Play a quiet tone when recording starts and stops") {
                    Toggle("", isOn: $soundEffectsEnabled).labelsHidden()
                }

                HStack(spacing: 10) {
                    Button("Microphone settings") { openPrivacyPane("Privacy_Microphone") }
                        .clickableCursor()
                    Button("Accessibility settings") { openPrivacyPane("Privacy_Accessibility") }
                        .clickableCursor()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var speechSection: some View {
        settingsSection(title: "Speech") {
            VStack(alignment: .leading, spacing: 16) {
                settingsRow(
                    "Transcription engine",
                    detail: engineDetail
                ) {
                    BrandedMenuPicker(
                        title: "Engine",
                        selection: engineBinding,
                        options: TranscriptionEngineChoice.allCases.map {
                            ($0.displayName, $0)
                        }
                    )
                    .frame(width: 190)
                }

                Divider().overlay(Theme.line)

                switch engine {
                case .deepgram:
                    deepgramContent
                case .whisperLocal:
                    localContent
                }
            }
        }
    }

    private var engineDetail: String {
        switch engine {
        case .deepgram:
            return "Audio is transcribed by Deepgram's Nova-3 API"
        case .whisperLocal:
            return "Transcribes on this Mac. No key, and nothing leaves the device"
        }
    }

    private var engineBinding: Binding<TranscriptionEngineChoice> {
        Binding(
            get: { engine },
            set: { newValue in
                engine = newValue
                settings.transcriptionEngine = newValue
                models.engineChanged(to: newValue)
                viewModel.refreshConfig()
            }
        )
    }

    private var deepgramContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            secretField(
                title: "Deepgram API key",
                placeholder: hasDeepgramKey
                    ? "Saved in Keychain. Enter a new key to replace it."
                    : "Enter your Deepgram API key",
                value: $deepgramKey,
                hasSavedValue: hasDeepgramKey,
                clear: {
                    Keychain.delete(account: "deepgram-key")
                    hasDeepgramKey = false
                    viewModel.refreshConfig()
                }
            )

            Divider().overlay(Theme.line)

            settingsRow(
                "Auto-format transcript",
                detail: "Adds punctuation, capitalization and formatted numbers"
            ) {
                Toggle("", isOn: $formattingEnabled).labelsHidden()
            }

            Divider().overlay(Theme.line)

            settingsRow(
                "Speak punctuation",
                detail: "Say “period”, “comma” or “new line” to insert it. English only."
            ) {
                Toggle("", isOn: $spokenPunctuationEnabled).labelsHidden()
            }

            Divider().overlay(Theme.line)

            // Disclosed because it is charged and was previously invisible:
            // the app sends `keyterm` for every dictionary term, on every
            // request, and Deepgram bills Keyterm Prompting separately.
            // https://deepgram.com/pricing
            InlineNote(
                text: "Deepgram bills Keyterm Prompting separately from transcription: "
                    + "$0.0013 per minute on pay-as-you-go, on top of $0.0043 per minute "
                    + "for Nova-3. That is about 30% more per minute while your dictionary "
                    + "is in use. Smart formatting and language detection are included."
            )
        }
    }

    // MARK: - Local models

    /// The local branch: every catalog model with its download state, plus the
    /// download prompt when the active model is missing — per the spec, the
    /// prompt lives on the same screen as the engine choice.
    private var localContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(models.models) { model in
                modelRow(model)
                if model.id != models.models.last?.id {
                    Divider().overlay(Theme.line)
                }
            }

            Divider().overlay(Theme.line)

            if let deleteError = models.deleteError {
                Text(deleteError)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
            }

            if models.availability(of: models.activeModel) != .usable {
                InlineNote(
                    text: "\(models.activeModel.displayName) is not downloaded yet. "
                        + "Dictation with the local engine will ask you to download it first."
                )
            }

            InlineNote(
                text: "Local models format their own punctuation and capitalization. "
                    + "Your dictionary still biases recognition and fixes mistakes afterwards. "
                    + models.diskSummary + "."
            )
        }
    }

    private func modelRow(_ model: WhisperModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if model.isRecommended {
                    Text("Recommended")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.success)
                }
                Spacer(minLength: 8)
                if models.isActive(model), models.availability(of: model) == .usable {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.success)
                        Text("Active")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.success)
                    }
                }
            }

            Text(modelMetadata(model))
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let note = model.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            modelControls(model)
        }
    }

    /// "809M params · 99 languages · MIT · 1.6 GB on disk"
    private func modelMetadata(_ model: WhisperModel) -> String {
        var parts = [
            "\(model.parameterCount) params",
            "\(model.languageCount) languages",
            model.licenseName,
            model.sizeDescription,
        ]
        if let bytes = models.installedBytes(for: model) {
            parts.append("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) downloaded")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func modelControls(_ model: WhisperModel) -> some View {
        let availability = models.availability(of: model)
        let state = models.state(for: model)

        HStack(spacing: 10) {
            switch state {
            case .downloading(let received, let total):
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 200)
                Text(Self.progressDescription(received: received, total: total))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                Button("Pause") { models.pause(model) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .clickableCursor()
            case .validating:
                ProgressView()
                    .controlSize(.small)
                Text("Verifying checksum")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            case .paused:
                Button("Resume download") { models.download(model) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .clickableCursor()
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
                Button("Try again") { models.download(model) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .clickableCursor()
            case .idle:
                switch availability {
                case .usable:
                    if !models.isActive(model) {
                        Button("Use this model") { models.activate(model) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .medium))
                            .clickableCursor()
                    }
                    Button("Delete", role: .destructive) {
                        modelPendingDeletion = model
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .clickableCursor()
                case .missing:
                    if models.canResume(model) {
                        Button("Resume download") { models.download(model) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .medium))
                            .clickableCursor()
                    } else {
                        Button("Download \(model.sizeDescription)") { models.download(model) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12, weight: .medium))
                            .clickableCursor()
                    }
                case .invalid:
                    Button("Download again") { models.download(model) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .clickableCursor()
                    Button("Delete", role: .destructive) {
                        modelPendingDeletion = model
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .clickableCursor()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private static func progressDescription(received: Int64, total: Int64) -> String {
        let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        let whole = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(done) of \(whole)"
    }

    private var dataSection: some View {
        settingsSection(title: "Data and recording") {
            VStack(spacing: 16) {
                settingsRow("Stop after silence", detail: "Automatically finish a recording after this many seconds") {
                    HStack(spacing: 8) {
                        Slider(value: $silenceTimeout, in: 15...120, step: 5).frame(width: 150)
                        Text("\(Int(silenceTimeout)) sec")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                settingsRow("Keep recordings", detail: "Retained audio enables retry and reprocessing") {
                    Stepper("\(recordingsToKeep)", value: $recordingsToKeep, in: 0...50)
                        .frame(width: 110)
                }
            }
        }
    }

    /// Recent problems, so a failure that has already scrolled past in the HUD is
    /// still answerable afterwards.
    ///
    /// The log records descriptions only — never a transcript, never the API key —
    /// which is why it is safe to show and to copy into a bug report.
    private var diagnosticsSection: some View {
        settingsSection(title: "Diagnostics") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(diagnostics.errorCount > 0 ? Theme.warning : Theme.success)
                        .frame(width: 7, height: 7)
                    Text(diagnosticsSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 12)
                    Button("Refresh") { diagnostics.reload() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .clickableCursor()
                    Button("Copy report") { diagnostics.copyReport() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .clickableCursor()
                        .disabled(!diagnostics.hasEntries)
                    Button("Clear") { diagnostics.clear() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .medium))
                        .clickableCursor()
                        .disabled(!diagnostics.hasEntries)
                }

                if let confirmation = diagnostics.copyConfirmation {
                    Text(confirmation)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }

                if diagnostics.hasEntries {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diagnostics.entries.enumerated()), id: \.offset) { index, entry in
                            if index > 0 {
                                Divider().overlay(Theme.line)
                            }
                            diagnosticsRow(entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text("Nothing has gone wrong. Errors are recorded here when something fails, so you can copy the details into a report.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(dataLocationSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .onAppear { diagnostics.reload() }
    }

    private func diagnosticsRow(_ entry: Diagnostics.Entry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.level.rawValue.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(entry.level == .error ? Theme.danger : Theme.muted)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.category)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(entry.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 8)
    }

    private var diagnosticsSummary: String {
        let total = diagnostics.entries.count
        guard total > 0 else { return "No problems recorded" }
        let errors = diagnostics.errorCount
        if errors == 0 {
            return "\(total) recent event\(total == 1 ? "" : "s"), none of them errors"
        }
        return "\(errors) error\(errors == 1 ? "" : "s") in the last \(total) events"
    }

    /// States plainly where the user's data and their audio live, since both are
    /// theirs to inspect or delete and neither is discoverable otherwise.
    private var dataLocationSummary: String {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sadaa")
        return "Your dictionary, notes and transcripts are in \(support.path), readable only by you. Recordings are in the Recordings folder inside it and are deleted as newer ones replace them."
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            content()
        }
        .padding(20)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func settingsRow<Accessory: View>(
        _ title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 20)
            accessory()
        }
    }

    private func secretField(
        title: String,
        placeholder: String,
        value: Binding<String>,
        hasSavedValue: Bool,
        clear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if hasSavedValue {
                    Text("Stored in Keychain")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.success)
                }
                Spacer()
                if hasSavedValue {
                    Button("Remove saved key", role: .destructive, action: clear)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .clickableCursor()
                }
            }
            SecureField(placeholder, text: value).premiumInputChrome()
        }
    }

    private func hotkeyPicker(selection: Binding<Int>) -> some View {
        BrandedMenuPicker(
            title: "Hotkey",
            selection: selection,
            options: HotkeyOption.all.map { ($0.label, $0.keycode) }
        )
        .frame(width: 170)
    }

    private var languageBinding: Binding<LanguagePin> {
        Binding(
            get: { viewModel.languagePin },
            set: {
                settings.languagePin = $0
                viewModel.refreshConfig()
            }
        )
    }

    private var hotkeyBinding: Binding<Int> {
        Binding(get: { viewModel.hotkeyKeycode }, set: { viewModel.setHotkeyKeycode($0) })
    }

    private var languageSwitchBinding: Binding<Int> {
        Binding(get: { viewModel.languageSwitchKeycode }, set: { viewModel.setLanguageSwitchKeycode($0) })
    }

    private var launchBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                do {
                    try LoginItem.setEnabled(newValue)
                    launchAtLogin = newValue
                    saveMessage = "Login setting updated"
                    saveIsError = false
                } catch {
                    saveMessage = "Could not update login setting"
                    saveIsError = true
                }
            }
        )
    }

    private func load() {
        // Existence-only check: never returns or decrypts the key, so it cannot
        // block this main-thread SwiftUI update on an authorization prompt.
        hasDeepgramKey = DeepgramKeyStore.shared.isConfigured()
        engine = settings.transcriptionEngine
        models.refreshAvailability()
        formattingEnabled = settings.formattingEnabled
        spokenPunctuationEnabled = settings.spokenPunctuationEnabled
        silenceTimeout = settings.silenceTimeout
        recordingsToKeep = settings.recordingsToKeep
        soundEffectsEnabled = settings.soundEffectsEnabled
        launchAtLogin = LoginItem.isEnabled
    }

    private func save() {
        saveMessage = ""
        saveIsError = false

        settings.formattingEnabled = formattingEnabled
        settings.spokenPunctuationEnabled = spokenPunctuationEnabled
        settings.silenceTimeout = silenceTimeout
        settings.recordingsToKeep = recordingsToKeep
        settings.soundEffectsEnabled = soundEffectsEnabled

        do {
            let trimmedKey = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try Keychain.set(trimmedKey, account: DeepgramKeyStore.account)
                // Keep the in-memory cache the dictation pipeline reads in step
                // with the keychain, so the new key works without a relaunch.
                DeepgramKeyStore.shared.update(trimmedKey)
                hasDeepgramKey = true
                deepgramKey = ""
            }
            viewModel.refreshConfig()
            saveMessage = "Settings saved"
        } catch {
            saveMessage = "Could not save the Keychain value"
            saveIsError = true
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
            // Read the stored key off the main actor: the keychain call can
            // block on securityd or on a user authorization prompt.
            //
            // `lookup` rather than `get`, because a stored key that cannot be read
            // is not the same as no key: reporting "Enter your Deepgram API key"
            // when the truth is a locked keychain sends the user to re-enter a
            // credential that is already there and fine.
            let lookup = await Task.detached(priority: .userInitiated) {
                Keychain.lookup(account: DeepgramKeyStore.account)
            }.value
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
                        message: message
                    )
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
                hint: TranscriptionHint(languagePin: viewModel.languagePin, dictionaryWords: [])
            )
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
    }

    /// Probes the local engine with the same health-check path as Deepgram:
    /// a tiny generated clip through the real provider. First run also loads
    /// the model, so it doubles as a "does the engine actually work" test.
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
                        message: "No local provider could be built."
                    )
                    isTesting = false
                }
                return
            }
            let result = await ProviderHealthCheck.check(
                provider: provider,
                endpoint: "on-device",
                hint: TranscriptionHint(languagePin: viewModel.languagePin, dictionaryWords: [])
            )
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
