import AVFoundation
import ApplicationServices
import SwiftUI
import UsefulVoiceCore

/// What the system says about the two permissions the app needs. Refreshed when the
/// app becomes active again, which is when someone comes back from System Settings.
@MainActor
final class SystemAccess: ObservableObject {
    enum Microphone { case allowed, denied, notDetermined }

    @Published private(set) var microphone: Microphone = .allowed
    @Published private(set) var accessibilityTrusted = true
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .allowed
        case .notDetermined: microphone = .notDetermined
        default: microphone = .denied
        }
        accessibilityTrusted = AXIsProcessTrusted()
        // Snapshot-only forcing, so a banner can be rendered on any machine.
        if ProcessInfo.processInfo.environment["UV_SNAPSHOT"] != nil {
            switch ProcessInfo.processInfo.environment["UV_BANNER"] {
            case "mic": microphone = .denied
            case "accessibility": accessibilityTrusted = false
            default: break
            }
        }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }
}

/// Everything the status button, the popover and the banners agree on.
struct ShellHealth {
    enum Engine: Equatable {
        case ready(String)
        case needsKey
        case needsModel(name: String, size: String)
        case rejected
        case offline
    }

    enum Level { case ready, needsAccess, problem }

    private(set) var engine: Engine
    let microphone: SystemAccess.Microphone
    let accessibilityOn: Bool
    let issue: DictationIssue?

    @MainActor
    init(viewModel: UsefulVoiceViewModel, settings: AppSettings, access: SystemAccess) {
        microphone = access.microphone
        accessibilityOn = viewModel.hotkeyActive || access.accessibilityTrusted
        issue = viewModel.lastIssue
        if !viewModel.providerConfigured {
            if settings.transcriptionEngine == .deepgram {
                engine = .needsKey
            } else {
                let model = viewModel.models.activeModel
                // The board writes sizes with a decimal comma.
                let size = model.sizeDescription.replacingOccurrences(of: ".", with: ",")
                engine = .needsModel(name: model.displayName, size: size)
            }
        } else if case .error(let error)? = viewModel.lastIssue, error.kind == .keyRejected {
            engine = .rejected
        } else if case .error(let error)? = viewModel.lastIssue, error.kind == .offline {
            engine = .offline
        } else {
            let name = viewModel.providerName
            engine = .ready(name.hasPrefix("Deepgram") ? "Deepgram Nova-3" : name)
        }
        // Snapshot-only forcing of the engine banners.
        if ProcessInfo.processInfo.environment["UV_SNAPSHOT"] != nil {
            switch ProcessInfo.processInfo.environment["UV_BANNER"] {
            case "keyMissing": engine = .needsKey
            case "keyInvalid": engine = .rejected
            case "offline": engine = .offline
            case "modelMissing": engine = .needsModel(name: "large-v3-turbo", size: "1,6 GB")
            default: break
            }
        }
    }

    var engineReady: Bool {
        if case .ready = engine { return true }
        return false
    }

    var level: Level {
        if !engineReady { return .problem }
        if microphone != .allowed || !accessibilityOn { return .needsAccess }
        return .ready
    }

    var word: String {
        switch level {
        case .ready: return "Ready"
        case .needsAccess: return "Needs access"
        case .problem: return "Problem"
        }
    }

    var systemImage: String {
        switch level {
        case .ready: return "checkmark.circle"
        case .needsAccess: return "exclamationmark.triangle"
        case .problem: return "xmark.circle"
        }
    }

    var tint: Color {
        switch level {
        case .ready: return Theme.success
        case .needsAccess: return Theme.warning
        case .problem: return Theme.danger
        }
    }
}

/// The popover behind the rail's status button: Engine, Microphone and Accessibility,
/// each with its state in words and a fix verb when it needs one.
struct StatusPopover: View {
    let health: ShellHealth
    let viewModel: UsefulVoiceViewModel
    let access: SystemAccess
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Status")
                .font(.uv(.ui, .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            row("Engine", engineBadge)
            row("Microphone", microphoneBadge)
            row("Accessibility", accessibilityBadge)
            ForEach(fixes, id: \.title) { fix in
                Button {
                    onClose()
                    fix.run()
                } label: {
                    Text(fix.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(.brandSecondary)
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Theme.edge, lineWidth: 1))
        .themeShadow(.pop)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
    }

    private func row(_ title: String, _ badge: PremiumStatusBadge) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.uv(.ui))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            badge
        }
        .accessibilityElement(children: .combine)
    }

    private var engineBadge: PremiumStatusBadge {
        switch health.engine {
        case .ready(let name): return .init(kind: .ok, icon: "checkmark.circle", text: name)
        case .needsKey: return .init(kind: .warn, icon: "exclamationmark.triangle", text: "Needs key")
        case .needsModel: return .init(kind: .warn, icon: "exclamationmark.triangle", text: "Needs model")
        case .rejected: return .init(kind: .bad, icon: "xmark.circle", text: "Key rejected")
        case .offline: return .init(kind: .bad, icon: "xmark.circle", text: "Offline")
        }
    }

    private var microphoneBadge: PremiumStatusBadge {
        switch health.microphone {
        case .allowed: return .init(kind: .ok, icon: "checkmark.circle", text: "Allowed")
        case .notDetermined: return .init(kind: .warn, icon: "exclamationmark.triangle", text: "Not asked yet")
        case .denied: return .init(kind: .warn, icon: "exclamationmark.triangle", text: "Off")
        }
    }

    private var accessibilityBadge: PremiumStatusBadge {
        health.accessibilityOn
            ? .init(kind: .ok, icon: "checkmark.circle", text: "On")
            : .init(kind: .warn, icon: "exclamationmark.triangle", text: "Off")
    }

    private struct Fix {
        let title: String
        let run: () -> Void
    }

    /// One button per thing that needs fixing. A single one says "Open settings", as the
    /// board does; several name what they open.
    private var fixes: [Fix] {
        var list: [(general: String, specific: String, run: () -> Void)] = []
        switch health.engine {
        case .ready: break
        case .offline:
            list.append(("Retry last recording", "Retry last recording",
                         { viewModel.perform(.retry) }))
        default:
            list.append(("Open Engine settings", "Open Engine settings",
                         { viewModel.perform(.openEngineSettings) }))
        }
        switch health.microphone {
        case .allowed: break
        case .notDetermined:
            list.append(("Allow microphone", "Allow microphone", { access.requestMicrophone() }))
        case .denied:
            list.append(("Open settings", "Open Microphone settings",
                         { viewModel.perform(.openMicrophoneSettings) }))
        }
        if !health.accessibilityOn {
            list.append(("Open settings", "Open Accessibility settings",
                         { viewModel.perform(.openAccessibilitySettings) }))
        }
        let single = list.count == 1
        return list.map { Fix(title: single ? $0.general : $0.specific, run: $0.run) }
    }
}
