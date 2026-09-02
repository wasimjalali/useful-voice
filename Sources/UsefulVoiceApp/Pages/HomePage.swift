import SwiftUI
import AppKit
import UsefulVoiceCore

enum PageFormat {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func relativeTime(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: Date())
    }

    static func languageLabel(_ pin: LanguagePin) -> String {
        switch pin {
        case .auto: return "Auto"
        case .en: return "English"
        case .de: return "German"
        }
    }

}

struct HomePage: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    @EnvironmentObject private var toasts: AppToastCenter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                readiness
                dictateStage
                latestTranscript
                recentTranscripts
            }
            .padding(32)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.surface)
    }

    private var header: some View {
        CommandPageHeader(
            title: "Dictate"
        ) {
            HStack(spacing: 8) {
                quietStatus(
                    icon: "globe",
                    text: PageFormat.languageLabel(viewModel.languagePin),
                    color: Theme.brand
                )
                quietStatus(
                    icon: viewModel.hotkeyActive ? "keyboard" : "exclamationmark.triangle",
                    text: viewModel.hotkeyActive ? HotkeyOption.label(for: viewModel.hotkeyKeycode) : "Grant access",
                    color: viewModel.hotkeyActive ? Theme.brand : Theme.warning
                )
            }
        }
    }

    private var readiness: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(viewModel.providerConfigured ? Theme.success : Theme.warning)
                .frame(width: 8, height: 8)
            Text(viewModel.providerConfigured
                 ? "\(viewModel.providerName) is ready"
                 : "Add your Deepgram key in Settings")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 12))
    }

    private var dictateStage: some View {
        VStack(spacing: 18) {
            MicButton(state: viewModel.dictationState) { viewModel.toggle() }

            VStack(spacing: 5) {
                Text(stageTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(stageDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(stageDetailColor)
                    .multilineTextAlignment(.center)
            }

            if viewModel.canRetry {
                Button("Retry last recording") { viewModel.retry() }
                    .buttonStyle(.bordered)
                    .tint(Theme.brand)
                    .controlSize(.large)
                    .clickableCursor()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .padding(.horizontal, 24)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.lineStrong, lineWidth: 1))
    }

    @ViewBuilder
    private var latestTranscript: some View {
        if let latest = viewModel.recent.first {
            CommandPanel("Latest transcript") {
                VStack(alignment: .leading, spacing: 14) {
                    Text(latest.text)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Text(PageFormat.relativeTime(latest.createdAt))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Button("Send to notes") {
                            viewModel.sendToScratchpad(latest)
                            toasts.show("Sent to notes")
                        }
                        .buttonStyle(.borderless)
                        .clickableCursor()
                        Button("Copy") { copy(latest.text) }
                            .buttonStyle(.bordered)
                            .tint(Theme.brand)
                            .clickableCursor()
                    }
                }
            }
        }
    }

    private var recentTranscripts: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)

            if viewModel.recent.isEmpty {
                CommandEmptyState(
                    icon: "waveform",
                    title: "No transcripts yet",
                    detail: "Start a dictation to keep a local copy here."
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.recent.prefix(3).enumerated()), id: \.element.id) { index, record in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(2)
                                Text(PageFormat.relativeTime(record.createdAt))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button {
                                copy(record.text)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(PremiumIconButtonStyle())
                            .help("Copy transcript")
                        }
                        .padding(.vertical, 13)
                        if index < min(viewModel.recent.count, 3) - 1 {
                            Divider().overlay(Theme.line)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
            }
        }
    }

    private var stageTitle: String {
        switch viewModel.dictationState {
        case .idle: return "Ready when you are"
        case .recording: return "Listening"
        case .transcribing: return "Turning speech into text"
        case .delivering: return "Inserting text"
        case .error: return "Dictation needs attention"
        }
    }

    private var stageDetail: String {
        switch viewModel.dictationState {
        case .idle:
            return "Tap \(HotkeyOption.label(for: viewModel.hotkeyKeycode)) once to start and again to stop."
        case .recording: return "Speak naturally. Press Esc to cancel."
        case .transcribing: return "Your recording is being transcribed."
        case .delivering: return "Useful Voice is placing the transcript at your cursor."
        case .error(let message): return message
        }
    }

    private var stageDetailColor: Color {
        if case .error = viewModel.dictationState { return Theme.danger }
        return Theme.muted
    }

    private func quietStatus(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toasts.show("Copied")
    }
}
