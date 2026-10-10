import SwiftUI
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
        // "Auto" for the compact badge; the pickers use the full label.
        pin.isAuto ? "Auto" : pin.displayName
    }
}

/// The Stream: every dictation as a bubble on a day-grouped timeline, with search and
/// filters above and the dock below. Replaces Home and Library.
struct StreamPage: View {
    let viewModel: UsefulVoiceViewModel
    let settings: AppSettings
    @StateObject private var store: StreamStore

    /// The one column the header, timeline and dock share, so they keep one left edge.
    private static let columnWidth: CGFloat = 876

    init(viewModel: UsefulVoiceViewModel, settings: AppSettings) {
        self.viewModel = viewModel
        self.settings = settings
        _store = StateObject(wrappedValue: StreamStore(viewModel: viewModel))
    }

    var body: some View {
        VStack(spacing: 0) {
            StreamHeader(store: store)
            if store.storedCount > 0 { StreamFilterRow(store: store) }
            ZStack {
                if store.storedCount == 0 {
                    StreamEmptyState(store: store, viewModel: viewModel)
                } else if store.shownCount == 0 {
                    StreamNoMatches(store: store)
                } else {
                    StreamTimeline(store: store, viewModel: viewModel, settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Group {
                if store.selection.isEmpty {
                    StreamDock(viewModel: viewModel, settings: settings)
                } else {
                    StreamSelectionBar(store: store)
                }
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: Self.columnWidth)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                StreamToastView(toast: toast) { store.dismissToast() }
                    .padding(.bottom, 16 + 64 + 12)
                    .padding(.horizontal, 28)
                    .transition(.brandRise())
            }
        }
        .overlay(alignment: .bottomLeading) { StreamPreviewCard(store: store) }
        .overlay {
            if store.pendingDelete != nil {
                StreamConfirmDialog(
                    title: "Delete this dictation?",
                    message: "This removes it from this Mac. You can't undo this.",
                    confirmTitle: "Delete",
                    onCancel: { store.pendingDelete = nil },
                    onConfirm: { store.confirmDelete() })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }
}

/// Offscreen renders only (`UV_STREAM_PREVIEW=teach|note|menu|datejump`): a popover is a
/// separate window, so a snapshot cannot capture it. This draws its content inline.
private struct StreamPreviewCard: View {
    @ObservedObject var store: StreamStore

    var body: some View {
        if StreamStore.sample, let kind = StreamStore.preview {
            Group {
                switch kind {
                case "teach": StreamTeachPopover(heard: "the Barry", writeAs: "Tabari", onSave: { _ in }, onCorrectOne: { _ in })
                case "note": StreamNotePicker(scratchpad: store.viewModel.scratchpad, onPick: { _ in }, onNew: {})
                case "menu": StreamMenuList(items: [
                    .init(id: "r", title: "Reprocess", icon: "arrow.triangle.2.circlepath") {},
                    .init(id: "o", title: "Show original", icon: "clock.arrow.circlepath") {},
                    .init(id: "d", title: "Delete", icon: "trash", destructive: true) {},
                ], close: {})
                case "datejump": StreamDateJump(days: store.days, onPick: { _ in })
                default: EmptyView()
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
            .themeShadow(.pop)
            .padding(.leading, 120)
            .padding(.bottom, 190)
        }
    }
}

// MARK: - Header

private struct StreamHeader: View {
    @ObservedObject var store: StreamStore

    var body: some View {
        HStack(spacing: 12) {
            Text("Stream")
                .font(.uv(.title, .semibold))
                .foregroundStyle(Theme.ink)
            if !store.query.isEmpty, store.shownCount > 0 {
                Text(store.shownCount == 1 ? "1 dictation matches" : "\(StreamFormat.count(store.shownCount)) dictations match")
                    .font(.uv(.body))
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 12)
            if store.storedCount > 0 {
                PremiumSearchField(placeholder: "Search dictations", text: $store.query)
                    .frame(width: 220)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 56)
    }
}

private struct StreamFilterRow: View {
    @ObservedObject var store: StreamStore

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", .all)
                    chip("Today", .today)
                    chip("This week", .week)
                    ForEach(store.languageChips) { language in
                        chip(language.name, .language(language.key))
                    }
                }
                .padding(.vertical, 1)
                .padding(.horizontal, 2)
            }
            Button { store.exportShown() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(PremiumIconButtonStyle())
            .help("Copy as text")
            .accessibilityLabel("Export")
            .disabled(store.shownCount == 0)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    private func chip(_ title: String, _ scope: StreamStore.Scope) -> some View {
        let selected = store.scope == scope
        return Button { store.scope = scope } label: {
            Text(title)
                .font(.uv(.ui))
                .lineLimit(1)
                .foregroundStyle(selected ? Theme.accentInk : Theme.inkMuted)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    // A filled ring rather than a stroke: a 1 pt stroke left slivers at the
                    // chip ends in offscreen renders.
                    ZStack {
                        Capsule().fill(selected ? Theme.accent : Theme.lineStrong)
                        Capsule().fill(selected ? Theme.accent : Theme.surface).padding(1)
                    }
                }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .clickableCursor()
        .brandAnimation(BrandMotion.control, value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Empty states

/// A card with a heading and a sentence, top left under the header.
private struct StreamNote<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.uv(.title, .semibold))
                .foregroundStyle(Theme.ink)
            content()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: 520, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(Theme.line, lineWidth: 1))
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// First launch, and after Delete all dictations. No button: the dock below is live.
private struct StreamEmptyState: View {
    @ObservedObject var store: StreamStore
    @ObservedObject var viewModel: UsefulVoiceViewModel

    var body: some View {
        if store.everDictated {
            StreamNote(title: "All dictations deleted") {
                Text("Notes and vocabulary are untouched. The next dictation shows up here.")
                    .font(.uv(.body))
                    .foregroundStyle(Theme.inkMuted)
                    .lineSpacing(3)
            }
        } else {
            StreamNote(title: "Nothing here yet") {
                HStack(spacing: 6) {
                    Text("Tap")
                    BrandKbd(StreamFormat.keyName(viewModel.hotkeyKeycode))
                    Text("in any app and start talking.")
                }
                .font(.uv(.body))
                .foregroundStyle(Theme.inkMuted)
                Text("Your dictations land here, newest at the bottom.")
                    .font(.uv(.body))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
    }
}

private struct StreamNoMatches: View {
    @ObservedObject var store: StreamStore

    var body: some View {
        let needle = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
        StreamNote(title: needle.isEmpty ? "No dictations here" : "No dictations match \u{201C}\(needle)\u{201D}") {
            Text("Check the spelling or clear the filters.")
                .font(.uv(.body))
                .foregroundStyle(Theme.inkMuted)
            Button(needle.isEmpty ? "Clear filters" : "Clear search") { store.clearFilters() }
                .buttonStyle(.brandPrimary)
                .padding(.top, 8)
        }
    }
}
