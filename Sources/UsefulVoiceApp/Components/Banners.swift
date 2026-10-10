import SwiftUI
import UsefulVoiceCore

/// One window banner (board a-73..a-81): what happened, then one verb. The window
/// shows at most one, the most blocking.
struct WindowBanner: Equatable {
    enum Tone { case warn, bad }

    enum Action: Equatable {
        case fix(DictationFix)
        case downloadModel
    }

    let systemImage: String
    let tone: Tone
    let title: String
    let detail: String
    let verb: String?
    let action: Action?

    /// The most blocking banner for the current health, or nil. Order: no microphone,
    /// no usable engine, a failed last dictation, then Accessibility (dictations still
    /// work, they are copied instead of pasted).
    @MainActor
    static func current(health: ShellHealth, canRetry: Bool) -> WindowBanner? {
        if health.microphone == .denied {
            return WindowBanner(
                systemImage: "mic.slash", tone: .warn,
                title: "Microphone access is off.", detail: "Useful Voice can't hear you.",
                verb: "Open settings", action: .fix(.openMicrophoneSettings))
        }
        switch health.engine {
        case .ready:
            break
        case .needsKey:
            return WindowBanner(
                systemImage: "key", tone: .warn,
                title: "No Deepgram key.", detail: "Add one to start dictating.",
                verb: "Add key", action: .fix(.openEngineSettings))
        case .rejected:
            return WindowBanner(
                systemImage: "key", tone: .bad,
                title: "Deepgram rejected your key.", detail: "Check it and try again.",
                verb: "Open Engine settings", action: .fix(.openEngineSettings))
        case .offline:
            return WindowBanner(
                systemImage: "wifi.slash", tone: .bad,
                title: "You're offline.",
                detail: canRetry ? "Your last recording is saved." : "Check your connection.",
                verb: canRetry ? "Retry last recording" : nil,
                action: canRetry ? .fix(.retry) : nil)
        case .needsModel(let name, let size):
            return WindowBanner(
                systemImage: "arrow.down.circle", tone: .warn,
                title: "\(name) isn't downloaded.", detail: "Download it to dictate locally.",
                verb: "Download \(size)", action: .downloadModel)
        }
        if case .error(let error)? = health.issue, let banner = issueBanner(error) {
            return banner
        }
        if !health.accessibilityOn {
            return WindowBanner(
                systemImage: "exclamationmark.triangle", tone: .warn,
                title: "Accessibility is off.", detail: "Dictations are copied, not pasted.",
                verb: "Open settings", action: .fix(.openAccessibilitySettings))
        }
        return nil
    }

    /// Failures that persist until the next recording. Quiet ones (no speech, too
    /// short, a password field) stay in the dock and the HUD.
    static func isPersistent(_ kind: DictationError.Kind) -> Bool {
        switch kind {
        case .outOfCredits, .timedOut, .providerFailed, .engineFailed, .stopFailed, .micUnavailable:
            return true
        default:
            return false
        }
    }

    private static func issueBanner(_ error: DictationError) -> WindowBanner? {
        switch error.kind {
        case .outOfCredits, .timedOut, .providerFailed, .engineFailed, .stopFailed, .micUnavailable:
            let verb: String?
            switch error.fix {
            case .retry: verb = "Retry last recording"
            case .openEngineSettings: verb = "Open Engine settings"
            case .openMicrophoneSettings, .openAccessibilitySettings: verb = "Open settings"
            case nil: verb = nil
            }
            return WindowBanner(
                systemImage: "exclamationmark.triangle", tone: .bad,
                title: error.message, detail: "",
                verb: verb, action: error.fix.map { .fix($0) })
        default:
            return nil
        }
    }
}

/// The banner strip: tinted wash, a hairline in the same tone, glyph, sentence, verb.
struct BannerView: View {
    let banner: WindowBanner
    let onAction: (WindowBanner.Action) -> Void

    private var tint: Color { banner.tone == .bad ? Theme.danger : Theme.warning }
    private var wash: Color { banner.tone == .bad ? Theme.dangerSoft : Theme.warningSoft }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            (Text(banner.title).fontWeight(.semibold)
                + Text(banner.detail.isEmpty ? "" : " " + banner.detail))
                .font(.uv(.ui))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let verb = banner.verb, let action = banner.action {
                Button(verb) { onAction(action) }
                    .buttonStyle(.brandSecondary)
                    .controlSize(.small)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(wash, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(tint.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(banner.detail.isEmpty ? banner.title : "\(banner.title) \(banner.detail)")
    }
}
