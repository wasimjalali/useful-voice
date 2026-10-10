import AppKit
import SwiftUI
import UsefulVoiceCore

/// Sections in the main window sidebar. String-raw + Identifiable makes it
/// usable directly as the selection value for `ForEach`.
enum SidebarSection: String, CaseIterable, Identifiable {
    case home, languageMemory, insights, scratchpad, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Dictate"
        case .languageMemory: return "Dictionary"
        case .insights: return "Insights"
        case .scratchpad: return "Notes"
        case .history: return "Library"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "waveform"
        case .languageMemory: return "character.book.closed"
        case .insights: return "chart.bar.xaxis"
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
    @ObservedObject var firstRun: FirstRunModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The section the rail highlights. Moves the instant you click, so the
    /// sidebar never feels laggy.
    @State private var selection: SidebarSection = RootView.startSection
    /// The section actually on the stage. Lags `selection` by the length of the
    /// exit fade so the old page can leave before the new one arrives.
    @State private var displayed: SidebarSection = RootView.startSection
    @State private var pageOpacity: Double = 1
    @State private var pageOffset: CGFloat = 0
    @State private var pendingPageSwitch: DispatchWorkItem?
    @StateObject private var toasts = AppToastCenter()

    /// Where the window opens. `UV_START_SECTION` (a section's raw value, for example
    /// `insights`) lets a screenshot or a demo open on any page without clicking through.
    private static let startSection: SidebarSection =
        ProcessInfo.processInfo.environment["UV_START_SECTION"]
            .flatMap(SidebarSection.init(rawValue:)) ?? .home

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            stage
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        // Under the flow nothing can be reached by VoiceOver or Tab.
        .accessibilityHidden(firstRun.active)
        .disabled(firstRun.active)
        .overlay {
            // Covers the sidebar too: setup is the only thing on screen.
            if firstRun.active {
                FirstRunView(model: firstRun)
                    .transition(.opacity)
            }
        }
        .onChange(of: firstRun.finishCount) { _, _ in
            // Finishing lands on Dictate, whatever page was open before.
            pendingPageSwitch?.cancel()
            selection = .home
            displayed = .home
            pageOpacity = 1
            pageOffset = 0
        }
        .environmentObject(toasts)
        .tint(Theme.ink)
        .toggleStyle(BrandSwitchToggleStyle())
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            brand
            nav
            Spacer(minLength: 0)
            footer
        }
        .padding(.top, 40)
        .padding(.bottom, 12)
        .padding(.horizontal, 12)
        .frame(width: 232)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.rail)
    }

    private var brand: some View {
        HStack(spacing: 12) {
            AppIconMark()
            Text("Useful Voice")
                .font(.system(size: 15, weight: .bold))
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
                .fill(viewModel.hotkeyActive ? Theme.success : Theme.inkMuted)
                .frame(width: 7, height: 7)
            Text(viewModel.hotkeyActive ? "Hotkeys active" : "Needs access")
                .font(.uv(.meta, .medium))
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xxl, style: .continuous))
        .overlay { PremiumToastHost() }
        .themeShadow(.card)
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
        case .insights:
            InsightsPage(viewModel: viewModel, settings: settings) // TEMP until merge
        case .scratchpad:
            ScratchpadPage(viewModel: viewModel)
        case .history:
            HistoryPage(viewModel: viewModel)
        case .settings:
            SettingsPage(settings: settings, viewModel: viewModel, firstRun: firstRun, anchor: .constant(nil)) // TEMP until merge
        }
    }
}

/// The app icon tile: the Landing mark on the dark tile.
private struct AppIconMark: View {
    var body: some View {
        LandingTile(size: 44, radius: 11)
    }
}
