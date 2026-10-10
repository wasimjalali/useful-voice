import SwiftUI
import UsefulVoiceCore

// MARK: - What the dock shows

/// The warning or failure row: bold lead, one more sentence, one fix verb.
struct DockIssue: Equatable {
    enum Tone { case warning, danger }

    let lead: String
    let rest: String
    let icon: String
    let tone: Tone
    let fix: DictationFix?
    /// The engine's own message, for the tooltip.
    let detail: String
    /// The mic button wears a slash while the microphone is the problem.
    let micOff: Bool

    init(_ issue: DictationIssue, canRetry: Bool) {
        detail = issue.message
        fix = issue.fix
        switch issue {
        case .copiedNotPasted:
            (lead, rest, icon, tone, micOff) = ("Copied.", "Press \u{2318}V to paste.", "exclamationmark.triangle", .warning, false)
        case .error(let error):
            let saved = canRetry ? "Your recording is saved on this Mac." : ""
            micOff = error.kind == .micUnavailable
            switch error.kind {
            case .secureField:
                (lead, rest, icon, tone) = ("Secure field active.", "Dictation is off here.", "lock", .warning)
            case .micUnavailable:
                (lead, rest, icon, tone) = ("Microphone access is off.", "Dictation can't start.", "exclamationmark.triangle", .warning)
            case .diskFull:
                (lead, rest, icon, tone) = ("The disk is full.", "Free up space, then dictate again.", "exclamationmark.triangle", .danger)
            case .recordingFailed:
                (lead, rest, icon, tone) = ("Couldn't start recording.", "", "exclamationmark.triangle", .danger)
            case .deliveryFailed:
                (lead, rest, icon, tone) = ("Couldn't copy the text.", "It's saved in Useful Voice.", "exclamationmark.triangle", .danger)
            case .stopFailed:
                (lead, rest, icon, tone) = ("Couldn't stop recording.", saved, "exclamationmark.triangle", .danger)
            case .noSpeech:
                (lead, rest, icon, tone) = ("No speech detected.", "Try again a little closer to the mic.", "waveform.slash", .warning)
            case .tooShort:
                (lead, rest, icon, tone) = ("Recording was too short.", "Hold on a little longer.", "exclamationmark.triangle", .warning)
            case .noProvider:
                (lead, rest, icon, tone) = ("No engine is set up.", "Add a key or download a model.", "exclamationmark.triangle", .warning)
            case .keyRejected:
                (lead, rest, icon, tone) = ("Deepgram rejected your key.", saved, "key", .warning)
            case .outOfCredits:
                (lead, rest, icon, tone) = ("Deepgram is out of credit.", saved, "exclamationmark.triangle", .warning)
            case .offline:
                (lead, rest, icon, tone) = ("No connection.", saved, "wifi.slash", .danger)
            case .timedOut:
                (lead, rest, icon, tone) = ("The engine didn't answer in time.", saved, "clock.badge.exclamationmark", .danger)
            case .providerFailed:
                (lead, rest, icon, tone) = ("Transcription failed.", saved, "exclamationmark.triangle", .danger)
            case .engineFailed:
                (lead, rest, icon, tone) = ("Whisper (local) failed.", saved, "exclamationmark.triangle", .danger)
            }
        }
    }

    init(lead: String, rest: String, icon: String, tone: Tone, fix: DictationFix?, micOff: Bool = false) {
        self.lead = lead
        self.rest = rest
        self.icon = icon
        self.tone = tone
        self.fix = fix
        self.detail = lead + " " + rest
        self.micOff = micOff
    }
}

enum DockPhase: Equatable {
    case idle
    case recording
    case transcribing(local: Bool)
    case done(words: Int, destination: String)
    case issue(DockIssue)

    /// Changes when the dock's content must cross-fade; recording ticks do not.
    var key: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .done: return "done"
        case .issue: return "issue"
        }
    }
}

extension DictationFix {
    /// The verb on the dock's fix button.
    var dockVerb: String {
        switch self {
        case .openMicrophoneSettings, .openAccessibilitySettings, .openEngineSettings: return "Open settings"
        case .retry: return "Retry last recording"
        }
    }
}

// MARK: - Offscreen samples

/// `UV_DOCK_STATE=idle|recording|silence|transcribing|local|doneHotkey|doneWindow|errorMic|copied|offline`
/// feeds sample data into the dock for offscreen renders. It only works together with
/// `UV_SNAPSHOT`, so it can never change a real window.
enum DockSnapshot {
    struct Sample {
        let phase: DockPhase
        var elapsed = 7
        var level: Float = 0.06
        var silence: Int?
        var partial: String?
        var local = false
    }

    static let current: Sample? = {
        let env = ProcessInfo.processInfo.environment
        guard env["UV_SNAPSHOT"] != nil, let name = env["UV_DOCK_STATE"] else { return nil }
        switch name {
        case "idle": return Sample(phase: .idle)
        case "recording": return Sample(phase: .recording)
        case "silence": return Sample(phase: .recording, level: 0, silence: 5)
        case "transcribing": return Sample(phase: .transcribing(local: false))
        case "local":
            return Sample(phase: .transcribing(local: true),
                          partial: "skip the Devin VM and run it on this computer, I'll keep the computer quiet so you can run the performance check here",
                          local: true)
        case "doneHotkey": return Sample(phase: .done(words: 24, destination: "Inserted into Slack"))
        case "doneWindow": return Sample(phase: .done(words: 24, destination: "Saved and copied"))
        case "errorMic":
            return Sample(phase: .issue(DockIssue(lead: "Microphone access is off.", rest: "Dictation can't start.",
                                                  icon: "exclamationmark.triangle", tone: .warning,
                                                  fix: .openMicrophoneSettings, micOff: true)))
        case "copied":
            return Sample(phase: .issue(DockIssue(.copiedNotPasted, canRetry: false)))
        case "offline":
            return Sample(phase: .issue(DockIssue(lead: "No connection.", rest: "Your recording is saved on this Mac.",
                                                  icon: "wifi.slash", tone: .danger, fix: .retry)))
        default:
            fputs("Unknown UV_DOCK_STATE \(name)\n", stderr)
            return nil
        }
    }()
}

// MARK: - Dock

/// The dock: one bar pinned to the bottom of the stage in every state. Observes the view
/// model (state, issue, outcome); the 30 Hz telemetry is observed only inside
/// `DockRecordingLive`.
struct StreamDock: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    let settings: AppSettings

    @State private var doneVisible = false
    @State private var doneToken = UUID()
    @State private var languageOpen = false
    @State private var formatTick = 0

    private var sample: DockSnapshot.Sample? { DockSnapshot.current }
    private var engineIsLocal: Bool { sample?.local ?? (settings.transcriptionEngine == .whisperLocal) }

    private var phase: DockPhase {
        if let sample { return sample.phase }
        switch viewModel.dictationState {
        case .recording: return .recording
        case .transcribing, .delivering: return .transcribing(local: engineIsLocal)
        case .idle, .error:
            if let issue = viewModel.lastIssue { return .issue(DockIssue(issue, canRetry: viewModel.canRetry)) }
            if doneVisible, case .delivered(let words, let mode, let app) = viewModel.lastOutcome {
                switch mode {
                case .pasted: return .done(words: words, destination: app.map { "Inserted into \($0)" } ?? "Inserted")
                case .copied: return .done(words: words, destination: "Saved and copied")
                case .copiedNotPasted: break
                }
            }
            return .idle
        }
    }

    var body: some View {
        let phase = phase
        let issue: DockIssue? = { if case .issue(let issue) = phase { return issue }; return nil }()
        HStack(spacing: 12) {
            micButton(phase: phase, issue: issue)
            ZStack(alignment: .leading) {
                content(phase: phase, issue: issue)
                    .id(phase.key)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing(phase: phase, issue: issue)
                .fixedSize(horizontal: true, vertical: false)
                .id(phase.key + "-trailing")
                .transition(.opacity)
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .background(background(issue), in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
            .strokeBorder(border(issue), lineWidth: 1))
        .themeShadow(.raise)
        .brandAnimation(BrandMotion.morph, value: phase.key)
        .accessibilityElement(children: .contain)
        .onChange(of: viewModel.lastOutcome) { _, outcome in
            guard case .delivered = outcome else { return }
            let token = UUID()
            doneToken = token
            doneVisible = true
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if doneToken == token { doneVisible = false }
            }
        }
    }

    // MARK: Parts

    private func background(_ issue: DockIssue?) -> Color {
        switch issue?.tone {
        case .warning: return Theme.warningSoft
        case .danger: return Theme.dangerSoft
        case nil: return Theme.bubble
        }
    }

    private func border(_ issue: DockIssue?) -> Color {
        switch issue?.tone {
        case .warning: return Theme.warning.opacity(0.4)
        case .danger: return Theme.danger.opacity(0.4)
        case nil: return Theme.lineStrong
        }
    }

    private func micButton(phase: DockPhase, issue: DockIssue?) -> some View {
        let recording = phase == .recording
        let busy: Bool = { if case .transcribing = phase { return true }; return false }()
        return Button { viewModel.toggle() } label: {
            ZStack {
                Circle().fill(busy || issue?.micOff == true ? Theme.sunken : Theme.brand)
                if recording {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.brandInk)
                        .frame(width: 13, height: 13)
                } else {
                    Image(systemName: issue?.micOff == true ? "mic.slash" : "mic")
                        .font(.uv(.title, .medium))
                        .foregroundStyle(busy || issue?.micOff == true ? Theme.inkMuted : Theme.brandInk)
                }
            }
            .frame(width: 40, height: 40)
            .shadow(color: Theme.ink.opacity(busy ? 0 : 0.18), radius: 1.5, y: 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .clickableCursor()
        .accessibilityLabel(recording ? "Stop dictation" : "Start dictation")
    }

    @ViewBuilder
    private func content(phase: DockPhase, issue: DockIssue?) -> some View {
        switch phase {
        case .idle:
            HStack(spacing: 8) {
                Text("Ready. Tap")
                BrandKbd(StreamFormat.keyName(viewModel.hotkeyKeycode))
                Text("to dictate")
            }
            .font(.uv(.body))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        case .recording:
            if let sample {
                DockRecordingLine(elapsed: sample.elapsed, level: sample.level, silence: sample.silence)
            } else {
                DockRecordingLive(telemetry: viewModel.telemetry)
            }
        case .transcribing(let local):
            HStack(spacing: 10) {
                DockSpinner()
                Text(local ? "Transcribing locally" : "Transcribing")
                    .font(.uv(.body, .semibold))
                    .foregroundStyle(Theme.ink)
            }
        case .done(let words, let destination):
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.uv(.ui, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(destination)
                    .font(.uv(.body, .semibold))
                    .foregroundStyle(Theme.ink)
                Text(StreamFormat.words(words))
                    .font(.uv(.body))
                    .foregroundStyle(Theme.inkMuted)
            }
            .lineLimit(1)
        case .issue:
            if let issue {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: issue.icon)
                        .font(.uv(.body))
                        .foregroundStyle(issue.tone == .warning ? Theme.warning : Theme.danger)
                    (Text(issue.lead).fontWeight(.semibold) + Text(issue.rest.isEmpty ? "" : " " + issue.rest))
                        .font(.uv(.body))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help(issue.detail)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func trailing(phase: DockPhase, issue: DockIssue?) -> some View {
        switch phase {
        case .issue:
            if let fix = issue?.fix {
                Button(fix.dockVerb) { viewModel.perform(fix) }
                    .buttonStyle(DockFixButtonStyle())
                    .clickableCursor()
            }
        case .recording:
            HStack(spacing: 10) {
                languageChip
                BrandKbd(StreamFormat.keyName(viewModel.languageSwitchKeycode))
                HStack(spacing: 8) {
                    BrandKbd("Esc")
                    Text("to cancel")
                        .font(.uv(.ui))
                        .foregroundStyle(Theme.inkMuted)
                }
            }
        default:
            HStack(spacing: 8) {
                languageChip
                engineChip
                formatToggle
            }
        }
    }

    private var languageChip: some View {
        let pin = viewModel.languagePin
        let name: String = pin.isAuto ? "Auto" : (StreamFormat.language(forCode: pin.rawValue)?.name ?? pin.displayName)
        return Button { languageOpen.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.uv(.ui))
                Text(name)
                    .font(.uv(.meta, .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.uv(.label, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.sunken, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .popover(isPresented: $languageOpen, arrowEdge: .top) {
            LanguagePicker(selection: Binding(
                get: { viewModel.languagePin },
                set: {
                    settings.languagePin = $0
                    viewModel.refreshConfig()
                }
            ))
        }
        .accessibilityLabel("Language")
        .accessibilityValue(name)
        .help(phaseIsRecording ? "Applies to this recording" : "Language")
    }

    private var phaseIsRecording: Bool { viewModel.dictationState == .recording }

    private var engineChip: some View {
        let local = engineIsLocal
        return Button { viewModel.navigate(to: "settings", anchor: "engine") } label: {
            HStack(spacing: 6) {
                Image(systemName: local ? "internaldrive" : "cloud")
                    .font(.uv(.ui))
                Text(local ? "Whisper (local)" : "Deepgram Nova-3")
                    .font(.uv(.meta, .medium))
                    .lineLimit(1)
                if local {
                    Text(Self.modelName(viewModel.models.activeModel))
                        .font(.uv(.meta))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.sunken, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .accessibilityLabel("Engine")
        .accessibilityValue(local ? "Whisper (local)" : "Deepgram Nova-3")
        .help("Engine settings")
    }

    private static func modelName(_ model: WhisperModel) -> String {
        model.id.hasPrefix("whisper-") ? String(model.id.dropFirst("whisper-".count)) : model.id
    }

    private var formatToggle: some View {
        let on = { _ = formatTick; return settings.formattingEnabled }()
        return Button {
            settings.formattingEnabled.toggle()
            formatTick += 1
        } label: {
            Text("Aa")
                .font(.uv(.meta, .semibold))
                .foregroundStyle(on ? Theme.ink : Theme.inkMuted)
                .frame(width: 30, height: 30)
                .background(on ? Theme.sunken : Color.clear,
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(on ? Theme.lineStrong : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .accessibilityLabel("Auto-format")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .help(on ? "Auto-format is on" : "Auto-format is off")
    }
}

// MARK: - Recording

/// Observes the 30 Hz telemetry so nothing else in the window redraws with it.
private struct DockRecordingLive: View {
    @ObservedObject var telemetry: DictationTelemetry

    var body: some View {
        DockRecordingLine(elapsed: telemetry.elapsedSeconds, level: telemetry.level,
                          silence: [telemetry.silenceRemaining, telemetry.maxRemaining].compactMap { $0 }.min())
    }
}

private struct DockRecordingLine: View {
    let elapsed: Int
    let level: Float
    let silence: Int?

    var body: some View {
        HStack(spacing: 12) {
            DockRecordDot()
            LandingMark(level: level, size: 32)
            Text(StreamFormat.timer(elapsed))
                .font(.uv(.figure, .medium).monospacedDigit())
                .foregroundStyle(Theme.ink)
            if let silence {
                Text("Stops in \(silence) s")
                    .font(.uv(.ui))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(StreamFormat.timer(elapsed))")
    }
}

/// The record dot: breathes between full and 0.8 opacity, solid under Reduce Motion.
private struct DockRecordDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.8 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

/// A 14 pt ring with a turning arc. A still ring under Reduce Motion.
struct DockSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.lineStrong, lineWidth: 2)
            Circle()
                .trim(from: 0, to: reduceMotion ? 1 : 0.28)
                .stroke(Theme.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .frame(width: 14, height: 14)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityHidden(true)
    }
}

private struct DockFixButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.uv(.ui, .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Theme.surface.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(Theme.edge, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

// MARK: - Ghost bubble

/// While the local engine transcribes, its partial text shows as a ghost bubble at the
/// end of the timeline, at 60 % ink, until the real bubble replaces it.
struct StreamGhostBubble: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    @ObservedObject var telemetry: DictationTelemetry
    let settings: AppSettings

    var body: some View {
        let partial: String? = DockSnapshot.current.flatMap(\.partial) ?? telemetry.localPartial
        let active = DockSnapshot.current != nil
            || (viewModel.dictationState == .transcribing && settings.transcriptionEngine == .whisperLocal)
        if active, let partial, !partial.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(partial)
                    .font(.uv(.body))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .multilineTextAlignment(StreamFormat.isRTL(partial) ? .trailing : .leading)
                Text("Transcribing locally")
                    .font(.uv(.meta, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 640, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Theme.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Transcribing locally: \(partial)")
        }
    }
}
