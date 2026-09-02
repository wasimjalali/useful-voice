import AppKit
import SwiftUI
import UsefulVoiceCore

/// Sections in the main window sidebar. String-raw + Identifiable makes it
/// usable directly as the selection value for `ForEach`.
enum SidebarSection: String, CaseIterable, Identifiable {
    case home, languageMemory, scratchpad, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Dictate"
        case .languageMemory: return "Dictionary"
        case .scratchpad: return "Notes"
        case .history: return "Library"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "waveform"
        case .languageMemory: return "character.book.closed"
        case .scratchpad: return "note.text"
        case .history: return "text.page"
        case .settings: return "gearshape"
        }
    }
}

/// Light rail plus a white stage, matching the Useful Brain workspace shell.
struct RootView: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    let settings: AppSettings

    @State private var selection: SidebarSection = .home
    @StateObject private var toasts = AppToastCenter()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            stage
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .environmentObject(toasts)
        .tint(Theme.ink)
        .preferredColorScheme(.light)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            brand
            nav
            Spacer(minLength: 0)
            footer
        }
        .padding(.top, 44)
        .padding(.bottom, 12)
        .padding(.horizontal, 12)
        .frame(width: 232)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.rail)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.ink)
                UsefulVoiceWaveBars(
                    style: .still,
                    barHeight: 16,
                    barWidth: 3,
                    spacing: 2.5,
                    fill: Theme.brandInk,
                    peakFill: Theme.hudMark
                )
            }
            .frame(width: 28, height: 28)
            Text("Useful Voice")
                .font(.system(size: 14, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Useful Voice")
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    SidebarItem(
                        title: section.title,
                        systemImage: section.systemImage,
                        isSelected: selection == section
                    )
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(selection == section ? [.isSelected] : [])
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.hotkeyActive ? Theme.success : Theme.inkFaint)
                .frame(width: 7, height: 7)
            Text(viewModel.hotkeyActive ? "Hotkeys active" : "Needs access")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    // MARK: - Stage

    private var stage: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { PremiumToastHost() }
            .shadow(color: Theme.ink.opacity(0.06), radius: 18, y: 8)
            .padding(.top, 6)
            .padding(.trailing, 10)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home:
            HomePage(viewModel: viewModel)
        case .languageMemory:
            LanguageMemoryPage(viewModel: viewModel.languageMemory)
        case .scratchpad:
            ScratchpadPage(viewModel: viewModel)
        case .history:
            HistoryPage(viewModel: viewModel)
        case .settings:
            SettingsPage(settings: settings, viewModel: viewModel)
        }
    }
}
