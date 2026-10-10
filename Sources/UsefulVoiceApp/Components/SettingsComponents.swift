import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UsefulVoiceCore

// MARK: - Groups and rows

/// One settings group: a 13 pt heading over one surface, rows divided by hairlines.
struct SettingsGroup<Content: View, Footer: View>: View {
    let id: String
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.uv(.ui, .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            // Each row draws a hairline on its top edge. The container is pulled up by
            // that 1 pt and clips it, so the first row has none.
            VStack(spacing: 0, content: content)
                .padding(.top, -1)
                .frame(maxWidth: .infinity)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1))
            footer()
        }
        .padding(.top, 20)
        .id(id)
    }
}

extension SettingsGroup where Footer == EmptyView {
    init(id: String, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(id: id, title: title, content: content, footer: { EmptyView() })
    }
}

/// A 48 pt row: the label on the left, the control on the right. A second line is for
/// the few places where it prevents a mistake.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var detailTone: Color = Theme.inkMuted
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.uv(.ui, .medium))
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(.uv(.meta))
                        .foregroundStyle(detailTone)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8, content: control)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// A row whose content spans the full width (a progress bar, a log, a field and its status).
struct SettingsBlock<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// A quiet 12 pt note under a group.
struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.uv(.meta))
            .foregroundStyle(Theme.inkMuted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The index

/// The left in-page index: one row per group, the current one with a 2 pt ink bar and a tint.
struct SettingsIndex: View {
    let groups: [(id: String, title: String)]
    let active: String
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(groups, id: \.id) { group in
                SettingsIndexRow(title: group.title, isActive: group.id == active) { select(group.id) }
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 0, trailing: 12))
        .frame(width: 184)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }
}

private struct SettingsIndexRow: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.uv(.ui, isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Theme.ink : Theme.inkMuted)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(isActive ? Theme.sunken : (hovering ? Theme.sunken.opacity(0.5) : Color.clear),
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(alignment: .leading) {
                    if isActive {
                        Capsule().fill(Theme.ink).frame(width: 2, height: 16).padding(.leading, -8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .clickableCursor()
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .brandAnimation(BrandMotion.control, value: isActive)
    }
}

// MARK: - Controls

/// The board's stepper: a track holding minus, the value and plus.
struct SettingsStepper: View {
    /// Read by VoiceOver ("Daily goal").
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var format: (Int) -> String = { "\($0)" }
    /// Lets the value be typed, with or without the thousands dot.
    var editable = false
    var onCommit: () -> Void = {}
    @State private var text = ""

    var body: some View {
        HStack(spacing: 2) {
            stepButton("minus", delta: -step)
            center
            stepButton("plus", delta: step)
        }
        .padding(2)
        .background(Theme.line, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(step)
            case .decrement: nudge(-step)
            @unknown default: break
            }
        }
    }

    @FocusState private var focused: Bool
    @State private var editing = false

    @ViewBuilder
    private var center: some View {
        Group {
            if editable && editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit { commitText(); editing = false }
                    .onChange(of: focused) { _, now in
                        if !now { commitText(); editing = false }
                    }
            } else {
                Text(format(value))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard editable else { return }
                        text = format(value)
                        editing = true
                        focused = true
                    }
            }
        }
        .font(.uv(.ui, .semibold))
        .monospacedDigit()
        .foregroundStyle(Theme.ink)
        .frame(minWidth: 52, minHeight: 26)
        .frame(width: editable ? 64 : nil)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .onChange(of: value) { _, new in if !editing { text = format(new) } }
    }

    private func commitText() {
        let digits = text.filter(\.isNumber)
        guard let typed = Int(digits) else { text = format(value); return }
        let clamped = min(max(typed, range.lowerBound), range.upperBound)
        text = format(clamped)
        guard clamped != value else { return }
        value = clamped
        onCommit()
    }

    private func stepButton(_ symbol: String, delta: Int) -> some View {
        let next = value + delta
        return Button { nudge(delta) } label: {
            Image(systemName: symbol)
                .font(.uv(.meta, .semibold))
                .foregroundStyle(Theme.inkMuted)
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!range.contains(next))
        .opacity(range.contains(next) ? 1 : 0.4)
        .clickableCursor()
        .accessibilityLabel(delta > 0 ? "Increase" : "Decrease")
    }

    private func nudge(_ delta: Int) {
        let next = min(max(value + delta, range.lowerBound), range.upperBound)
        guard next != value else { return }
        value = next
        onCommit()
    }
}

/// The solid danger button of the confirmation dialog.
struct SettingsDangerSolidButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.uv(.ui, .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Theme.danger.opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// The destructive confirmation: a solid scrim, a 22 pt dialog, Cancel focused, and a danger
/// button that names exactly what it will do.
struct SettingsConfirmDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        ZStack {
            Theme.scrim
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.uv(.title, .semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.uv(.ui))
                    .foregroundStyle(Theme.inkMuted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.brandSecondary)
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                        .focused($cancelFocused)
                        .clickableCursor()
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(SettingsDangerSolidButtonStyle())
                        .clickableCursor()
                }
                .padding(.top, 12)
            }
            .padding(24)
            .frame(width: 440)
            .background(Theme.bubble, in: RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(Theme.edge, lineWidth: 1))
            .themeShadow(.pop)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { cancelFocused = true }
        .transition(.opacity)
    }
}

// MARK: - Hotkey capture (preview)

/// A field that listens for the next modifier key. Only the keys the hotkey engine can
/// register are accepted; anything else is refused with one line. Preview only: it ships
/// behind `UV_PREVIEW_FEATURES=1`.
struct HotkeyCaptureField: View {
    let currentLabel: String
    let onCapture: (Int) -> Void
    @State private var capturing = false
    @State private var refusal: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                capturing ? stop() : start()
            } label: {
                HStack {
                    Text(capturing ? "Press a key" : currentLabel)
                        .foregroundStyle(capturing ? Theme.ink : Theme.ink)
                    Spacer(minLength: 8)
                    if capturing {
                        Text("Esc to cancel").foregroundStyle(Theme.inkMuted)
                    }
                }
                .font(.uv(.ui, capturing ? .regular : .medium))
                .padding(.horizontal, 10)
                .frame(width: 200, height: 32)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(refusal != nil ? Theme.danger : (capturing ? Theme.ink : Theme.controlEdge),
                                  lineWidth: 1))
            }
            .buttonStyle(.plain)
            .clickableCursor()
            if capturing {
                Button("Cancel") { stop() }
                    .buttonStyle(.brandSecondary)
                    .clickableCursor()
            }
        }
        .onDisappear { stop() }
        .overlay(alignment: .bottomTrailing) {
            if let refusal {
                Text(refusal)
                    .font(.uv(.meta))
                    .foregroundStyle(Theme.danger)
                    .fixedSize()
                    .offset(y: 22)
            }
        }
    }

    private func start() {
        refusal = nil
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            // Command shortcuts (quit, close window) keep working while listening.
            if event.type == .keyDown, event.modifierFlags.contains(.command) { return event }
            handle(event)
            return event.type == .keyDown ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 { stop(); refusal = nil; return }
            refusal = "Pick a key you don't type with, like Right Option."
            return
        }
        let code = Int(event.keyCode)
        guard HotkeyOption.all.contains(where: { $0.keycode == code }) else {
            refusal = "Pick a key you don't type with, like Right Option."
            return
        }
        // flagsChanged fires on release too; a pressed modifier has its flag set.
        guard !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return }
        stop()
        refusal = nil
        onCapture(code)
    }
}

// MARK: - Files

/// What a save or open panel did: finished, was cancelled, or failed with a reason.
enum SettingsFileResult<Value> {
    case done(Value)
    case cancelled
    case failed(String)
}

/// Save panels and open panels for the Import and export group.
enum SettingsFiles {
    @MainActor
    static func save(_ text: String, suggestedName: String, type: UTType) -> SettingsFileResult<URL> {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return .done(url)
        } catch {
            Diagnostics.shared.error("export", "could not write \(url.lastPathComponent): \(error.localizedDescription)")
            return .failed("\(url.lastPathComponent) could not be written. \(error.localizedDescription)")
        }
    }

    @MainActor
    static func open(types: [UTType]) -> SettingsFileResult<String> {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        do {
            return .done(try String(contentsOf: url, encoding: .utf8))
        } catch {
            Diagnostics.shared.error("import", "could not read \(url.lastPathComponent): \(error.localizedDescription)")
            return .failed("\(url.lastPathComponent) could not be read. \(error.localizedDescription)")
        }
    }
}

/// German-region size and percent formats for the engine rows.
enum SettingsFormat {
    static func gb(_ bytes: Int64) -> String {
        InsightsFormat.decimal(Double(bytes) / 1_000_000_000, digits: 1) + " GB"
    }

    static func mb(_ bytes: Int64) -> String {
        "\(InsightsFormat.grouped(Int((Double(bytes) / 1_000_000).rounded()))) MB"
    }

    static func number(_ n: Int) -> String { InsightsFormat.grouped(n) }
}
