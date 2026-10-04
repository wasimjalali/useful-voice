import AppKit
import SwiftUI
import UsefulVoiceCore

// MARK: - Welcome

struct FRWelcomePage: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            WaveMark(size: 104, radius: 26, barWidth: 9, gap: 8,
                     heights: [22, 38, 56, 38, 22], animated: true)
            VStack(spacing: 10) {
                Text("Welcome to Useful Voice")
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Tap a key and speak. Your words land wherever you're typing.")
                    .font(.system(size: 15))
                    .lineSpacing(3.5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.inkMuted)
            }
            FRPrimaryButton(title: "Get started", action: onStart)
                .frame(width: 280)
        }
        .frame(width: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Engine

struct FREnginePage: View {
    @ObservedObject var model: FirstRunModel
    @ObservedObject var models: LocalModelManager
    @FocusState private var keyFocused: Bool

    var body: some View {
        FRColumn(spacing: 16) {
            FRBackLink { model.go(.welcome) }
            FRHeader(step: 1, title: "Choose how it listens")
            deepgramCard
            Text("Or keep everything on this Mac")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.inkMuted)
                .padding(.top, 2)
                .padding(.bottom, -6)
            VStack(spacing: 0) {
                ForEach(models.models) { whisper in
                    FRLocalRow(model: whisper) { model.chooseLocal(whisper) }
                }
            }
            .padding(3)
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Deepgram receives your audio to transcribe it. Local models keep it on this Mac. You can switch anytime in Settings.")
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var showsConnected: Bool { model.keyConnected && !model.changingKey }

    private var deepgramCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Deepgram Nova-3")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Suggested")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkFaint)
            }
            Text("In the cloud. Fastest and most accurate.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.accentOnDark)
                .padding(.top, -6)
            Rectangle().fill(FRColor.darkRule).frame(height: 1)
            if showsConnected {
                connectedBlock
            } else {
                claimBlock
            }
        }
        .foregroundStyle(Theme.brandInk)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deepgram Nova-3")
    }

    private var claimBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("$200")
                    .font(.system(size: 40, weight: .bold))
                    .tracking(-1.2)
                Text("free credit for new accounts")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("No card needed. That's 500+ hours of dictation.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.accentOnDark)
                .padding(.top, -4)
            Button(action: model.claimCredit) {
                HStack(spacing: 8) {
                    Text("Claim your $200")
                        .font(.system(size: 14, weight: .semibold))
                    ExternalArrowGlyph()
                }
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(Theme.brandInk, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .clickableCursor()
            HStack(spacing: 16) {
                step(1, "Sign up")
                step(2, "Create an API key")
                step(3, "Paste it here")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.inkFaint)
            keyRow
            if let message = keyMessage {
                FRErrorBanner(text: message)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text("\(number)").fontWeight(.semibold).foregroundStyle(Theme.brandInk)
            Text(text)
        }
    }

    private var rejected: Bool { model.keyCheck == .rejected }
    private var checking: Bool { model.keyCheck == .checking }
    private var canConnect: Bool { !model.trimmedKey.isEmpty && !checking }

    private var keyRow: some View {
        HStack(spacing: 8) {
            SecureField("", text: $model.keyText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.brandInk)
                .focused($keyFocused)
                .overlay(alignment: .leading) {
                    if model.keyText.isEmpty {
                        Text("Paste your API key")
                            .font(.system(size: 14))
                            .foregroundStyle(FRColor.quiet)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(FRColor.darkField, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(rejected ? Theme.danger : FRColor.darkFieldLine, lineWidth: 1))
                .onSubmit { if canConnect { model.connect() } }
                .onChange(of: model.keyText) { _, _ in model.keyTextEdited() }
                .onChange(of: model.focusKeyRequest) { _, _ in keyFocused = true }
                .accessibilityLabel("Deepgram API key")
            Button(action: model.connect) {
                Text(checking ? "Checking the key…" : "Connect")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(canConnect ? Theme.ink : FRColor.quiet)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(canConnect ? Theme.brandInk : FRColor.darkButton,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .disabled(!canConnect)
            .clickableCursor(canConnect)
        }
    }

    private var keyMessage: String? {
        switch model.keyCheck {
        case .rejected:
            return "Deepgram didn't accept this key. Copy it again from console.deepgram.com and paste the whole key."
        case .network:
            return "Couldn't reach Deepgram. Check your connection, then try again."
        case .failed(let reason):
            return "Couldn't check the key: \(reason)"
        case .idle, .checking:
            return nil
        }
    }

    private var connectedBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                CheckGlyph(size: 18, color: Theme.brandInk)
                Text("Key saved in your Keychain.")
                    .font(.system(size: 14, weight: .semibold))
            }
            HStack(spacing: 8) {
                Button(action: model.changeKey) {
                    Text("Change key")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.brandInk)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(FRColor.darkButton, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .clickableCursor()
                Button(action: model.continueWithDeepgram) {
                    Text("Continue")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Theme.brandInk, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .clickableCursor()
            }
        }
    }
}

private struct FRLocalRow: View {
    let model: WhisperModel
    let action: () -> Void
    @State private var hovering = false

    private var detail: String {
        model.isRecommended
            ? "Works offline. \(model.gbDescription)"
            : "Most accurate offline. \(model.gbDescription)"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(model.shortName).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("›").foregroundStyle(Theme.inkMuted)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(hovering ? FRColor.hover : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .clickableCursor()
        .accessibilityLabel("\(model.shortName). \(detail)")
    }
}

// MARK: - Deepgram connected

struct FRDeepgramKeyPage: View {
    @ObservedObject var model: FirstRunModel

    var body: some View {
        FRColumn {
            FRBackLink { model.go(.engine) }
            FRHeader(step: 1, title: "Connect Deepgram")
            VStack(alignment: .leading, spacing: 6) {
                Text("API key")
                    .font(.system(size: 13, weight: .semibold))
                Text(String(repeating: "•", count: 40))
                    .font(.system(size: 15))
                    .tracking(1.8)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.lineStrong, lineWidth: 1.5))
                    .accessibilityLabel("API key, hidden")
            }
            HStack(spacing: 8) {
                CheckGlyph()
                Text("Key works. It's saved in your Keychain.")
                    .font(.system(size: 13))
            }
            .foregroundStyle(Theme.success)
            .frame(minHeight: 20)
            FRPrimaryButton(title: "Continue", action: model.continueWithDeepgram)
        }
    }
}

// MARK: - Local download

struct FRLocalDownloadPage: View {
    @ObservedObject var model: FirstRunModel
    @ObservedObject var models: LocalModelManager

    private var whisper: WhisperModel { model.selectedModel }

    /// What the page is showing, from the manager (or sample numbers in a forced run).
    fileprivate enum Phase {
        case ready
        case downloading(received: Int64, total: Int64)
        case checking
        case stopped(received: Int64, kind: Stop)
    }

    fileprivate enum Stop { case generic, disk, check }

    private var phase: Phase {
        let total = whisper.expectedBytes
        if model.forced {
            let fraction = model.preview == .errDownload ? 0.38 : 0.62
            let bytes = Int64(Double(total) * fraction)
            return model.preview == .errDownload
                ? .stopped(received: bytes, kind: .generic)
                : .downloading(received: bytes, total: total)
        }
        if model.diskMessage != nil, models.availability(of: whisper) != .usable {
            return .stopped(received: models.installedBytes(for: whisper) ?? 0, kind: .disk)
        }
        switch models.state(for: whisper) {
        case .downloading(let received, let total):
            return .downloading(received: received, total: total)
        case .validating:
            return .checking
        case .paused:
            return .stopped(received: partialBytes, kind: .generic)
        case .failed(let message):
            let lowered = message.lowercased()
            if lowered.contains("space") { return .stopped(received: partialBytes, kind: .disk) }
            if lowered.contains("validation") || lowered.contains("install") {
                return .stopped(received: 0, kind: .check)
            }
            return .stopped(received: partialBytes, kind: .generic)
        case .idle:
            return models.availability(of: whisper) == .usable
                ? .ready
                : .stopped(received: partialBytes, kind: .generic)
        }
    }

    /// Bytes kept from an earlier attempt, for the "stopped at" line.
    @State private var lastSeenBytes: Int64 = 0
    private var partialBytes: Int64 { max(lastSeenBytes, models.installedBytes(for: whisper) ?? 0) }

    var body: some View {
        let current = phase
        FRColumn {
            FRBackLink { model.go(.engine) }
            FRHeader(step: 1, title: title(for: current))
            card(for: current)
            if case .stopped(let received, let kind) = current {
                FRErrorBanner(text: stopMessage(received: received, kind: kind))
                FRPrimaryButton(title: "Resume download") { model.startDownload(whisper) }
                FRTextLink(title: "Use Deepgram instead", action: model.useDeepgramInstead)
                    .frame(maxWidth: .infinity)
            } else {
                if case .ready = current {} else {
                    Text("Keep setting up. It finishes in the background and checks the file before first use.")
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FRPrimaryButton(title: "Continue") { model.go(.microphone) }
                if case .ready = current {} else {
                    FRTextLink(title: "Cancel download", action: model.cancelDownload)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: current.receivedBytes) { _, bytes in
            if bytes > lastSeenBytes { lastSeenBytes = bytes }
            model.noteProgress(received: bytes)
        }
    }

    private func title(for phase: Phase) -> String {
        if case .ready = phase { return "\(whisper.shortName) is ready" }
        return "Downloading \(whisper.shortName)"
    }

    private func card(for phase: Phase) -> some View {
        let total = whisper.expectedBytes
        var fraction = 0.0
        var trailing = ""
        var footer: String?
        var fill = Theme.ink
        var trailingColor = Theme.inkMuted
        switch phase {
        case .ready:
            fraction = 1
            trailing = "Ready"
            trailingColor = Theme.success
        case .downloading(let received, let whole):
            fraction = Double(received) / Double(max(whole, 1))
            trailing = "\(Self.gb(received)) of \(Self.gb(whole, unit: true))"
            footer = timeLeft(received: received, total: whole)
        case .checking:
            fraction = 1
            trailing = "\(Self.gb(total, unit: true))"
            footer = "Checking the file"
        case .stopped(let received, _):
            fraction = Double(received) / Double(max(total, 1))
            trailing = "\(Self.gb(received)) of \(Self.gb(total, unit: true))"
            fill = Theme.inkFaint
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(whisper.shortName).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(trailing)
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(trailingColor)
            }
            .foregroundStyle(Theme.ink)
            FRProgressTrack(fraction: fraction, fill: fill)
            if let footer {
                Text(footer)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func timeLeft(received: Int64, total: Int64) -> String {
        guard !model.forced else { return "About a minute left" }
        guard let start = model.downloadStart else { return "Getting started" }
        let elapsed = Date().timeIntervalSince(start.time)
        let gained = received - start.bytes
        guard elapsed >= 3, gained > 0 else { return "Getting started" }
        let seconds = Double(total - received) / (Double(gained) / elapsed)
        if seconds < 30 { return "Less than a minute left" }
        if seconds < 90 { return "About a minute left" }
        return "About \(Int((seconds / 60).rounded())) minutes left"
    }

    private func stopMessage(received: Int64, kind: Stop) -> String {
        switch kind {
        case .disk:
            return model.diskMessage
                ?? "There isn't enough space on this Mac for \(whisper.shortName). Free up some space, then resume."
        case .check:
            return "The file didn't pass its check, so it was removed. Download it again."
        case .generic:
            return "The download stopped at \(Self.gb(received, unit: true)). Check your connection, then resume. What's downloaded so far is kept."
        }
    }

    static func gb(_ bytes: Int64, unit: Bool = false) -> String {
        let value = String(format: "%.1f", Double(bytes) / 1_000_000_000)
        return unit ? "\(value) GB" : value
    }
}

private extension FRLocalDownloadPage.Phase {
    var receivedBytes: Int64 {
        switch self {
        case .downloading(let received, _): return received
        default: return 0
        }
    }
}

// MARK: - Microphone

struct FRMicrophonePage: View {
    @ObservedObject var model: FirstRunModel

    var body: some View {
        FRColumn {
            FRBackLink { model.go(.engine) }
            FRHeader(step: 2, title: "Let it hear you")
            switch model.micStatus {
            case .denied:
                denied
            case .notDetermined, .authorized:
                allowed
            }
        }
    }

    @ViewBuilder
    private var allowed: some View {
        let authorized = model.micStatus == .authorized
        Text("Useful Voice only listens while you're dictating.")
            .font(.system(size: 14))
            .lineSpacing(3)
            .foregroundStyle(Theme.inkMuted)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MicGlyph()
                    .frame(width: 40, height: 40)
                    .background(Theme.ink, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.micDeviceName).font(.system(size: 14, weight: .semibold))
                    if authorized {
                        Text("Say something to test it")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                Spacer(minLength: 8)
                if authorized {
                    HStack(spacing: 8) {
                        CheckGlyph(size: 16)
                        Text("Allowed")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.success)
                }
            }
            .foregroundStyle(Theme.ink)
            FRLevelMeter(levels: model.micLevels)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        if authorized {
            FRPrimaryButton(title: "Continue") { model.go(.accessibility) }
        } else {
            FRPrimaryButton(title: "Allow microphone", action: model.requestMic)
        }
    }

    @ViewBuilder
    private var denied: some View {
        FRErrorBanner(text: "Microphone access is off for Useful Voice.")
        Text("Turn it on in System Settings › Privacy & Security › Microphone.")
            .font(.system(size: 14))
            .lineSpacing(3)
            .foregroundStyle(Theme.inkMuted)
        FRPrimaryButton(title: "Open System Settings", action: model.openMicSettings)
        FRWaitingStatus()
    }
}

struct FRWaitingStatus: View {
    var body: some View {
        HStack(spacing: 8) {
            WaitingSpinner()
            Text("Waiting for access. This moves on by itself.")
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.inkMuted)
        .frame(maxWidth: .infinity)
    }
}

struct FRLevelMeter: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                let height = max(4, CGFloat(level) * 28)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(height > 4 ? Theme.ink : FRColor.meterQuiet)
                    .frame(width: 4, height: height)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 32)
        .animation(.linear(duration: 0.08), value: levels)
        .accessibilityElement()
        .accessibilityLabel("Input level")
    }
}

// MARK: - Accessibility

struct FRAccessibilityPage: View {
    @ObservedObject var model: FirstRunModel

    var body: some View {
        FRColumn {
            FRBackLink { model.go(.microphone) }
            FRHeader(step: 3, title: "Let it type for you")
            Text("macOS needs Accessibility access so your key works in every app and your words land at the cursor.")
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("System Settings › Privacy & Security › Accessibility")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkMuted)
                HStack(spacing: 10) {
                    WaveMark(size: 28, radius: 7, barWidth: 2.5, gap: 2,
                             heights: [6, 10, 14, 10, 6])
                    Text("Useful Voice")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.accessibilityGranted ? "On" : "Turn this on")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkMuted)
                    FRSwitchPicture(on: model.accessibilityGranted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            FRPrimaryButton(title: "Open System Settings", action: model.openAccessibilitySettings)
            if model.accessibilityGranted {
                HStack(spacing: 8) {
                    CheckGlyph(size: 16)
                    Text("Allowed")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.success)
                .frame(maxWidth: .infinity)
            } else {
                FRWaitingStatus()
            }
        }
    }
}

/// The System Settings switch drawn in the mockup. A picture, not a control.
private struct FRSwitchPicture: View {
    let on: Bool

    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? Theme.ink : FRColor.toggleOff)
            Circle().fill(Color.white)
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                .padding(2)
        }
        .frame(width: 38, height: 22)
        .padding(3)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.ink, lineWidth: 1.5)
            .frame(width: 47, height: 31))
        .frame(width: 47, height: 31)
        .accessibilityElement()
        .accessibilityLabel(on ? "Switch, on" : "Switch, off")
    }
}

// MARK: - Try it

struct FRTryItPage: View {
    @ObservedObject var model: FirstRunModel
    @ObservedObject var viewModel: UsefulVoiceViewModel
    @FocusState private var padFocused: Bool
    @State private var changingKey = false

    var body: some View {
        FRColumn {
            FRBackLink { model.go(.accessibility) }
            FRHeader(step: 4, title: "Try it once")
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("Your key").frame(maxWidth: .infinity, alignment: .leading)
                    if changingKey {
                        BrandedMenuPicker(
                            title: "Hotkey",
                            selection: Binding(get: { viewModel.hotkeyKeycode },
                                               set: { viewModel.setHotkeyKeycode($0) }),
                            options: HotkeyOption.all.map { ($0.label, $0.keycode) })
                            .frame(width: 170)
                    } else {
                        FRKeyCap(label: model.keyLabel)
                        Button { changingKey = true } label: {
                            Text("Change").font(.system(size: 13)).underline()
                        }
                        .buttonStyle(.plain)
                        .clickableCursor()
                    }
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                Rectangle().fill(FRColor.rowLine).frame(height: 1)
                HStack(spacing: 10) {
                    Text("Language").frame(maxWidth: .infinity, alignment: .leading)
                    LanguagePickerButton(selection: Binding(
                        get: { viewModel.languagePin },
                        set: { model.setLanguage($0) }))
                        .frame(width: 190)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
            }
            .font(.system(size: 14))
            .foregroundStyle(Theme.ink)
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onChange(of: viewModel.hotkeyKeycode) { _, _ in changingKey = false }

            pad
            if model.practiceWorked {
                HStack(spacing: 8) {
                    CheckGlyph()
                    Text("It worked. That's all there is to it.")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.success)
                .accessibilityElement(children: .combine)
                FRPrimaryButton(title: "Finish setup", action: model.finish)
            } else {
                if case .error(let text) = viewModel.dictationState {
                    FRErrorBanner(text: text)
                    if viewModel.canRetry {
                        FRPrimaryButton(title: "Retry", action: viewModel.retry)
                    }
                }
                FRTextLink(title: "Skip for now") { model.go(.done) }
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear { padFocused = true }
    }

    private var pad: some View {
        let worked = model.practiceWorked
        return TextEditor(text: $model.practiceText)
            .font(.system(size: 15))
            .lineSpacing(3)
            .scrollContentBackground(.hidden)
            .foregroundStyle(Theme.ink)
            .focused($padFocused)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(height: 96)
            .overlay(alignment: .topLeading) {
                if model.practiceText.isEmpty {
                    Text("Tap \(model.keyLabel), say \"Hello from Useful Voice\", then tap it again.")
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.inkFaint)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(worked ? Theme.lineStrong : Theme.ink, lineWidth: 1.5))
            .onChange(of: model.practiceText) { _, _ in model.practiceTextChanged() }
            .accessibilityLabel("Practice area")
    }
}

// MARK: - Done

struct FRDonePage: View {
    @ObservedObject var model: FirstRunModel

    var body: some View {
        VStack(spacing: 22) {
            WaveMark(size: 72, radius: 18, barWidth: 6, gap: 5,
                     heights: [16, 27, 40, 27, 16])
            Text("You're all set")
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.56)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                row(lead: AnyView(FRKeyCap(label: model.keyLabel)),
                    text: "Start and stop dictation in any app")
                divider
                row(lead: AnyView(FRKeyCap(label: "Esc")), text: "Cancel a recording")
                divider
                row(lead: AnyView(WaveMark(size: 26, radius: 6, barWidth: 2.5, gap: 2,
                                           heights: [5, 9, 13, 9, 5])),
                    text: "Find Useful Voice in your menu bar. It has no Dock icon.")
                divider
                row(lead: AnyView(FRKeyCap(label: "Dictionary")),
                    text: "Teach it names and words it gets wrong")
            }
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            FRPrimaryButton(title: "Open Useful Voice", action: model.finish)
        }
        .frame(width: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(FRColor.rowLine).frame(height: 1)
    }

    private func row(lead: AnyView, text: String) -> some View {
        HStack(spacing: 14) {
            lead.frame(width: 76, alignment: .leading)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
