import SwiftUI
import AppKit
import UsefulVoiceCore

struct SettingsPage: View {
    let settings: AppSettings
    @ObservedObject var viewModel: UsefulVoiceViewModel

    @State private var deepgramKey = ""
    @State private var hasDeepgramKey = false
    @State private var formattingEnabled = true

    @State private var silenceTimeout = 60.0
    @State private var recordingsToKeep = 10
    @State private var soundEffectsEnabled = true
    @State private var launchAtLogin = false

    @State private var saveMessage = ""
    @State private var saveIsError = false
    @State private var isTesting = false
    @State private var testResult: ProviderHealthResult?

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
            }
            .padding(32)
            .frame(maxWidth: 920, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.surface)
        .onAppear(perform: load)
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
        }
        .padding(14)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12))
    }

    private var generalSection: some View {
        settingsSection(title: "General") {
            VStack(spacing: 16) {
                settingsRow("Language", detail: "Auto-detect, English or German") {
                    BrandedMenuPicker(
                        title: "Language",
                        selection: languageBinding,
                        options: [
                            ("Auto-detect", LanguagePin.auto),
                            ("English", LanguagePin.en),
                            ("German", LanguagePin.de),
                        ]
                    )
                    .frame(width: 170)
                }

                Divider().overlay(Theme.line)

                settingsRow("Dictation hotkey", detail: "Tap once to start and again to stop") {
                    hotkeyPicker(selection: hotkeyBinding)
                }

                settingsRow("Language hotkey", detail: "Quickly switch between English and German") {
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
            }
        }
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
        hasDeepgramKey = Keychain.exists(account: "deepgram-key")
        formattingEnabled = settings.formattingEnabled
        silenceTimeout = settings.silenceTimeout
        recordingsToKeep = settings.recordingsToKeep
        soundEffectsEnabled = settings.soundEffectsEnabled
        launchAtLogin = LoginItem.isEnabled
    }

    private func save() {
        saveMessage = ""
        saveIsError = false

        settings.formattingEnabled = formattingEnabled
        settings.silenceTimeout = silenceTimeout
        settings.recordingsToKeep = recordingsToKeep
        settings.soundEffectsEnabled = soundEffectsEnabled

        do {
            let trimmedKey = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try Keychain.set(trimmedKey, account: "deepgram-key")
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
        Task {
            let typed = deepgramKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = typed.isEmpty ? (Keychain.get(account: "deepgram-key") ?? "") : typed
            guard !key.isEmpty else {
                await MainActor.run {
                    testResult = ProviderHealthCheck.result(
                        providerName: "Deepgram",
                        endpoint: deepgramEndpoint,
                        ok: false,
                        startedAt: Date(),
                        finishedAt: Date(),
                        message: "Enter your Deepgram API key."
                    )
                    isTesting = false
                }
                return
            }
            let provider = DeepgramProvider(config: .init(apiKey: key, smartFormat: formattingEnabled))
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

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
