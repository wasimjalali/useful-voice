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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The section the rail highlights. Moves the instant you click, so the
    /// sidebar never feels laggy.
    @State private var selection: SidebarSection = .home
    /// The section actually on the stage. Lags `selection` by the length of the
    /// exit fade so the old page can leave before the new one arrives.
    @State private var displayed: SidebarSection = .home
    @State private var pageOpacity: Double = 1
    @State private var pageOffset: CGFloat = 0
    @State private var pendingPageSwitch: DispatchWorkItem?
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
            AppIconMark()
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
                    select(section)
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

    /// Runs the section change as two beats instead of one. A single cross-fade
    /// shows both dense pages at half opacity at the same time (a ghosted double
    /// image) and, on this curve, is over before the eye can follow it. Receding
    /// the old page first and then rising the new one reads as a clean
    /// transition. Reduce Motion swaps instantly.
    private func select(_ section: SidebarSection) {
        guard section != selection else { return }
        selection = section
        pendingPageSwitch?.cancel()

        guard !reduceMotion else {
            displayed = section
            pageOpacity = 1
            pageOffset = 0
            return
        }

        withAnimation(BrandMotion.pageExit) {
            pageOpacity = 0
            pageOffset = -6
        }

        let work = DispatchWorkItem {
            displayed = section
            pageOffset = 8
            withAnimation(BrandMotion.page) {
                pageOpacity = 1
                pageOffset = 0
            }
        }
        pendingPageSwitch = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BrandMotion.pageExitDuration,
            execute: work
        )
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
        ZStack {
            detail
                .opacity(pageOpacity)
                .offset(y: pageOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
        switch displayed {
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

/// The same dark waveform tile as the macOS app icon.
private struct AppIconMark: View {
    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.ink)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private static let image: NSImage? = {
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
