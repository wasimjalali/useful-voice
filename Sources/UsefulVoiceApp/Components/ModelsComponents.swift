import SwiftUI
import AppKit
import UsefulVoiceCore

// MARK: - Small marks

/// A 28 pt monochrome tile with the provider's monogram. No vendor logos.
struct ModelMonogram: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: text.count > 1 ? 11 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.ink)
            .frame(width: 28, height: 28)
            .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// "EN" or "NEW" next to a model name.
struct ModelBadge: View {
    let text: String

    var body: some View {
        let isNew = text == "NEW"
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(isNew ? Theme.accentInk : Theme.inkMuted)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(isNew ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.sunken), in: Capsule())
            .accessibilityHidden(true)
    }
}

/// Five segments, filled up to the rating.
struct ModelMeter: View {
    let value: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < value ? Theme.ink : Theme.lineStrong)
                    .frame(width: 9, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The selection mark: a ring, with a dot when chosen.
private struct ModelRadio: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(selected ? Theme.ink : Theme.controlEdge, lineWidth: 1.5)
            if selected { Circle().fill(Theme.ink).padding(4) }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Column header

/// Speed and Accuracy over the meter columns. Hidden when the rows wrap.
struct ModelListHeader: View {
    let title: String
    let compact: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.uv(.ui, .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if !compact {
                Text("Speed").frame(width: ModelRow.meterColumn, alignment: .leading)
                Text("Accuracy").frame(width: ModelRow.meterColumn, alignment: .leading)
                Color.clear.frame(width: ModelRow.trailingColumn, height: 1)
            }
        }
        .font(.uv(.label, .medium))
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, 16)
        .frame(minHeight: 36)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

// MARK: - One model row

/// A model: the whole left side selects, the right side holds that model's own
/// actions (Add key, Download, Delete), which are separate buttons.
struct ModelRow: View {
    static let meterColumn: CGFloat = 70
    static let trailingColumn: CGFloat = 168

    let entry: ModelEntry
    let selected: Bool
    let compact: Bool
    let needsKey: Bool
    let status: LocalModelStatus?
    let select: () -> Void
    let addKey: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    @State private var hovering = false

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    selectButton(includeMeters: false)
                    HStack(spacing: 14) {
                        labelledMeter("Speed", entry.speed)
                        labelledMeter("Accuracy", entry.accuracy)
                    }
                    .padding(.leading, 16 + 12 + 28 + 12)
                    trailing
                        .padding(.leading, 16 + 12 + 28 + 12)
                }
            } else {
                HStack(spacing: 12) {
                    selectButton(includeMeters: true)
                    trailing.frame(width: Self.trailingColumn, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .background(selected ? Theme.sunken.opacity(0.55) : (hovering ? Theme.sunken.opacity(0.3) : Color.clear))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onHover { hovering = $0 }
        .animation(BrandMotion.resolved(BrandMotion.control), value: selected)
    }

    private func selectButton(includeMeters: Bool) -> some View {
        Button(action: select) {
            HStack(spacing: 12) {
                ModelRadio(selected: selected)
                ModelMonogram(text: entry.monogram)
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.uv(.ui, .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(compact ? 2 : 1)
                        .fixedSize(horizontal: compact ? false : true, vertical: true)
                    if let badge = entry.badge { ModelBadge(text: badge) }
                }
                if includeMeters {
                    Spacer(minLength: 8)
                    ModelMeter(value: entry.speed).frame(width: Self.meterColumn, alignment: .leading)
                    ModelMeter(value: entry.accuracy).frame(width: Self.meterColumn, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityLabel: String {
        var parts = [entry.name]
        if let badge = entry.badge { parts.append(badge == "EN" ? "English only" : "New") }
        parts.append(entry.isLocal ? "on this Mac" : "cloud, \(entry.providerName)")
        parts.append("speed \(entry.speed) of 5")
        parts.append("accuracy \(entry.accuracy) of 5")
        if needsKey { parts.append("needs a key") }
        return parts.joined(separator: ", ")
    }

    private func labelledMeter(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.uv(.label)).foregroundStyle(Theme.inkMuted)
            ModelMeter(value: value)
        }
    }

    // MARK: Right column

    @ViewBuilder
    private var trailing: some View {
        if needsKey {
            Button("Add key", action: addKey)
                .buttonStyle(.brandSecondary).controlSize(.small)
        } else if let status {
            localTrailing(status)
        } else {
            Text("Cloud").font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
        }
    }

    @ViewBuilder
    private func localTrailing(_ status: LocalModelStatus) -> some View {
        switch status {
        case .notDownloaded(let bytes):
            HStack(spacing: 8) {
                Text(SettingsFormat.size(bytes)).font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                Button("Download", action: download).buttonStyle(.brandSecondary).controlSize(.small)
            }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                if let fraction {
                    InsightsMeter(fraction: fraction, height: 4).frame(width: 64)
                    Text(InsightsFormat.percent(fraction))
                        .font(.uv(.meta)).monospacedDigit().foregroundStyle(Theme.inkMuted)
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel", action: cancel).buttonStyle(.brandGhost).controlSize(.small)
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying").font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
            }
        case .paused(let canResume):
            Button(canResume ? "Resume" : "Download", action: download)
                .buttonStyle(.brandSecondary).controlSize(.small)
        case .ready(let bytes):
            HStack(spacing: 8) {
                if let bytes {
                    Text(SettingsFormat.size(bytes)).font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                }
                Button("Delete", action: delete).buttonStyle(.brandGhost).controlSize(.small)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                PremiumStatusBadge(kind: .bad, text: "Failed")
                    .help(message)
                Button("Try again", action: download).buttonStyle(.brandSecondary).controlSize(.small)
            }
        }
    }
}

/// The "Off" row that starts the AI formatting list.
struct ModelOffRow: View {
    let selected: Bool
    let compact: Bool
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                ModelRadio(selected: selected)
                Text("Off")
                    .font(.uv(.ui, .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 28, alignment: .leading)
                    .padding(.leading, 0)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .background(selected ? Theme.sunken.opacity(0.55) : (hovering ? Theme.sunken.opacity(0.3) : Color.clear))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onHover { hovering = $0 }
        .accessibilityLabel("Off")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - API key row

/// One provider's key: add or change it, remove it, test it, or open the page that makes one.
struct ApiKeyRow: View {
    let provider: KeyProvider
    @ObservedObject var models: ModelsViewModel

    @State private var editing = false
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private var stored: Bool { models.hasKey(provider) }
    private var saving: Bool { models.savingKey != nil }
    private var test: KeyTestState { models.keyTests[provider] ?? .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Text("\(provider.displayName) key")
                    .font(.uv(.ui, .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 110, alignment: .leading)
                Spacer(minLength: 8)
                WrappingHStack(horizontalSpacing: 8, verticalSpacing: 6) { controls }
                    .frame(maxWidth: 440, alignment: .trailing)
            }
            if let problem = models.keyProblem[provider] {
                Text("Your saved \(provider.displayName) key could not be read: \(problem). Unlock your login keychain and reopen Settings, or enter the key again to replace it.")
                    .font(.uv(.meta)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = test {
                Text(message).font(.uv(.meta)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .onChange(of: models.focusRequest) { _, requested in
            if requested == provider { open() }
        }
        .onAppear { if models.focusRequest == provider { open() } }
        // A key typed and abandoned must not sit in memory behind a closed editor.
        .onChange(of: editing) { _, open in if !open { text = "" } }
    }

    private func open() {
        editing = true
        models.focusRequest = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            fieldFocused = true
        }
    }

    private func save() {
        let value = text
        Task { @MainActor in
            if await models.saveKey(provider, value: value) {
                if text == value { text = "" }
                editing = false
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        if editing {
            SecureField("Paste your API key", text: $text)
                .premiumInputChrome(error: test == .rejected)
                .frame(width: 200)
                .focused($fieldFocused)
                .disabled(saving)
                .onSubmit(save)
                .accessibilityLabel("\(provider.displayName) API key")
            Button("Save", action: save)
                .buttonStyle(.brandPrimary).disabled(saving || text.trimmingCharacters(in: .whitespaces).isEmpty)
            if stored {
                Button("Remove") { Task { await models.removeKey(provider); editing = false } }
                    .buttonStyle(.brandDanger).disabled(saving)
            }
            Button("Cancel") { editing = false }
                .buttonStyle(.brandSecondary).disabled(saving)
        } else if stored {
            statusBadge
            Button(test == .testing ? "Testing" : "Test") { models.test(provider) }
                .buttonStyle(.brandSecondary).disabled(test == .testing || saving)
            Button("Change") { open() }
                .buttonStyle(.brandSecondary).disabled(saving)
        } else {
            Text("No key").font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
            Button("Add key") { open() }.buttonStyle(.brandPrimary)
            Button("Get a key") { NSWorkspace.shared.open(provider.getKeyURL) }
                .buttonStyle(.brandSecondary)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch test {
        case .ok(let ms):
            PremiumStatusBadge(kind: .ok, icon: "circle.fill", text: "Connected, \(ms) ms")
        case .rejected:
            PremiumStatusBadge(kind: .bad, icon: "circle.fill", text: "Key rejected")
        case .offline:
            PremiumStatusBadge(kind: .bad, icon: "circle.fill", text: "Offline")
        case .failed:
            PremiumStatusBadge(kind: .bad, icon: "circle.fill", text: "Could not connect")
        case .testing:
            PremiumStatusBadge(kind: .neutral, text: "Testing")
        case .idle:
            PremiumStatusBadge(kind: .ok, icon: "circle.fill", text: "Key saved")
        }
    }
}

// MARK: - The two lists

/// Voice model, AI formatting and the keys, the content of Settings > Models and API keys.
struct ModelsLists: View {
    @ObservedObject var models: ModelsViewModel
    let requestDelete: (ModelEntry) -> Void

    @State private var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModelListHeader(title: "Voice model", compact: compact)
            ForEach(ModelCatalog.voice) { entry in
                row(entry, kind: .voice)
            }
            ModelListHeader(title: "AI formatting", compact: compact)
                .padding(.top, 8)
            ModelOffRow(selected: models.formatterID == nil, compact: compact) {
                models.selectFormatter(nil)
            }
            ForEach(ModelCatalog.language) { entry in
                row(entry, kind: .formatter)
            }
        }
        .accessibilityElement(children: .contain)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ModelListWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(ModelListWidthKey.self) { width in
            let next = width < 560
            if next != compact { compact = next }
        }
    }

    private func row(_ entry: ModelEntry, kind: ModelsViewModel.ModelKind) -> some View {
        ModelRow(
            entry: entry,
            selected: models.isSelected(entry, kind: kind),
            compact: compact,
            needsKey: models.needsKey(entry),
            status: kind == .voice ? models.status(of: entry) : nil,
            select: { kind == .voice ? models.selectVoice(entry) : models.selectFormatter(entry) },
            addKey: { models.addKey(for: entry, kind: kind) },
            download: { models.download(entry) },
            cancel: { models.cancelDownload(entry) },
            delete: { requestDelete(entry) })
    }
}

private struct ModelListWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 1000
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
