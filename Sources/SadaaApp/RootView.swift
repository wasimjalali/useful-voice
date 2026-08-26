import AppKit
import SwiftUI
import SadaaCore

/// Sections in the main window sidebar. String-raw + Identifiable makes it
/// usable directly as the selection value for `List(selection:)`.
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

/// The windowed shell: a fixed navy sidebar and a white working canvas. Each section
/// resolves to a dedicated page composed from the shared view model.
struct RootView: View {
    @ObservedObject var viewModel: SadaaViewModel
    let settings: AppSettings

    @State private var selection: SidebarSection = .home
    @StateObject private var toasts = AppToastCenter()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)
                .overlay { PremiumToastHost() }
        }
        .environmentObject(toasts)
        // Sadaa wears a fixed light cream/navy brand. Pin the window to the
        // light scheme so default text resolves dark and stays readable on
        // cream even when macOS is in Dark Mode.
        .preferredColorScheme(.light)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            brand
            Text("Workspace")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.white.opacity(0.46))
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 2)
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
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(minWidth: 196, maxWidth: 196, maxHeight: .infinity, alignment: .top)
        .background(
            Rectangle()
                .fill(Theme.navy800)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(Theme.white.opacity(0.08))
                        .frame(width: 1)
                }
        )
    }

    private var brand: some View {
        HStack(spacing: 10) {
            BrandMark()
            VStack(alignment: .leading, spacing: 1) {
                Text("Useful Voice")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.white)
                Text("Voice dictation")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.white.opacity(0.58))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.hotkeyActive ? Theme.success : Theme.accent)
                    .frame(width: 7, height: 7)
                Text(viewModel.hotkeyActive ? "Hotkeys active" : "Needs access")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.white.opacity(0.78))
            }
            Text(viewModel.providerName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.white.opacity(0.45))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }

    // MARK: - Detail

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

private struct BrandMark: View {
    var body: some View {
        Group {
            if let logo = Self.logoImage {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.navy800)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.cream)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.gold.opacity(0.22), lineWidth: 1)
        )
    }

    private static let logoImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "SadaaLogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: "Sadaa", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let appIcon = NSApplication.shared.applicationIconImage, appIcon.isValid {
            return appIcon
        }
        return nil
    }()
}
