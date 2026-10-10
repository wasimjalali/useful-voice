import AppKit
import SwiftUI
import UsefulVoiceCore

/// The four places plus Settings, in rail order. String-raw + Identifiable makes it
/// usable directly as the selection value for `ForEach`.
enum SidebarSection: String, CaseIterable, Identifiable {
    case stream, notes, vocabulary, insights, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stream: return "Stream"
        case .notes: return "Notes"
        case .vocabulary: return "Vocabulary"
        case .insights: return "Insights"
        case .settings: return "Settings"
        }
    }

    /// SF Symbols closest to the board's icons (waveform, notebook-pen, book-a,
    /// chart-column, settings).
    var systemImage: String {
        switch self {
        case .stream: return "waveform"
        case .notes: return "square.and.pencil"
        case .vocabulary: return "character.book.closed"
        case .insights: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        }
    }

    /// A raw value from `navigate(to:)` or `UV_START_SECTION`, accepting the names
    /// the sections had before the redesign.
    static func resolve(_ raw: String) -> SidebarSection? {
        if let section = SidebarSection(rawValue: raw) { return section }
        switch raw {
        case "home", "history": return .stream
        case "scratchpad": return .notes
        case "languageMemory": return .vocabulary
        default: return nil
        }
    }
}

/// The 84 pt icon rail plus a white stage. Banners sit on top of the stage, the status
/// popover on top of both.
struct RootView: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    let settings: AppSettings
    @ObservedObject var firstRun: FirstRunModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The section the rail highlights. Moves the instant you click, so the
    /// rail never feels laggy.
    @State private var selection: SidebarSection = RootView.startSection
    /// The section actually on the stage. Lags `selection` by the length of the
    /// exit fade so the old page can leave before the new one arrives.
    @State private var displayed: SidebarSection = RootView.startSection
    @State private var pageOpacity: Double = 1
    @State private var pageOffset: CGFloat = 0
    @State private var pendingPageSwitch: DispatchWorkItem?
    /// The Settings group a navigation request asked for; SettingsPage scrolls to it
    /// and sets it back to nil.
    @State private var settingsAnchor: String?
    @State private var statusOpen = RootView.snapshotShowsStatus
    @StateObject private var access = SystemAccess()
    @StateObject private var toasts = AppToastCenter()

    /// Where the window opens. `UV_START_SECTION` (a section's raw value, for example
    /// `insights`) lets a screenshot or a demo open on any page without clicking through.
    private static let startSection: SidebarSection =
        ProcessInfo.processInfo.environment["UV_START_SECTION"]
            .flatMap(SidebarSection.resolve) ?? .stream

    /// `UV_STATUS_POPOVER=1` opens the status popover in an offscreen render.
    private static let snapshotShowsStatus: Bool =
        ProcessInfo.processInfo.environment["UV_SNAPSHOT"] != nil
            && ProcessInfo.processInfo.environment["UV_STATUS_POPOVER"] == "1"

    private var health: ShellHealth {
        ShellHealth(viewModel: viewModel, settings: settings, access: access)
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
                .disabled(viewModel.modalPresented)
                .accessibilityHidden(viewModel.modalPresented)
            stage
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .overlay(alignment: .bottomLeading) { statusLayer }
        // Under the flow nothing can be reached by VoiceOver or Tab.
        .accessibilityHidden(firstRun.active)
        .disabled(firstRun.active)
        .overlay {
            // Covers the rail too: setup is the only thing on screen.
            if firstRun.active {
                FirstRunView(model: firstRun)
                    .transition(.opacity)
            }
        }
        .onChange(of: firstRun.finishCount) { _, _ in
            // Finishing lands on Stream, whatever page was open before.
            pendingPageSwitch?.cancel()
            selection = .stream
            displayed = .stream
            pageOpacity = 1
            pageOffset = 0
        }
        .onChange(of: viewModel.navigationRequest) { _, request in consume(request) }
        .onAppear { consume(viewModel.navigationRequest) }
        .environmentObject(toasts)
        .tint(Theme.ink)
        .toggleStyle(BrandSwitchToggleStyle())
    }

    // MARK: - Rail

    private var rail: some View {
        let health = health
        return VStack(spacing: 6) {
            LandingTile(size: 36, radius: Radius.sm)
                .padding(.bottom, 14)
                .accessibilityLabel("Useful Voice")
            ForEach(SidebarSection.allCases.filter { $0 != .settings }) { section in
                railButton(section)
            }
            Spacer(minLength: 0)
            railButton(.settings)
            Button {
                withAnimation(BrandMotion.resolved(BrandMotion.morph)) { statusOpen.toggle() }
            } label: {
                RailItem(title: health.word, systemImage: health.systemImage,
                         glyphTint: health.tint)
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .accessibilityLabel("Status: \(health.word)")
            .accessibilityHint("Opens engine, microphone and accessibility status")
        }
        .padding(.top, 44)
        .padding(.bottom, 12)
        .frame(width: 84)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.rail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    private func railButton(_ section: SidebarSection) -> some View {
        Button {
            select(section)
        } label: {
            RailItem(title: section.title, systemImage: section.systemImage,
                     isSelected: selection == section)
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selection == section ? [.isSelected] : [])
    }

    /// The popover and the transparent layer that closes it on an outside click or Esc.
    @ViewBuilder
    private var statusLayer: some View {
        if statusOpen {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { closeStatus() }
                StatusPopover(health: health, viewModel: viewModel, access: access,
                              onClose: closeStatus)
                    .padding(.leading, 96)
                    .padding(.bottom, 12)
                    .transition(.brandRise(enter: 6, exit: 6))
                Button("Close status", action: closeStatus)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    private func closeStatus() {
        withAnimation(BrandMotion.resolved(BrandMotion.hudExit)) { statusOpen = false }
    }

    /// Handles a `viewModel.navigate(to:anchor:)` request, then clears it.
    private func consume(_ request: UsefulVoiceViewModel.NavigationRequest?) {
        guard let request else { return }
        defer { viewModel.navigationRequest = nil }
        guard let section = SidebarSection.resolve(request.section) else { return }
        if section == .settings { settingsAnchor = request.anchor }
        select(section)
    }

    /// Runs the section change as two beats instead of one (board motion table: exit
    /// 120 ms, fade and 6 pt up, swap at opacity 0, enter 260 ms, 8 pt rise and fade).
    /// A single cross-fade shows both dense pages at half opacity at the same time (a
    /// ghosted double image). Reduce Motion swaps instantly.
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

    // MARK: - Stage

    private var stage: some View {
        let banner = firstRun.active ? nil : WindowBanner.current(
            health: health, canRetry: viewModel.canRetry)
        return VStack(spacing: 0) {
            if let banner {
                BannerView(banner: banner, onAction: run)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .transition(.brandRise())
            }
            detail
                .opacity(pageOpacity)
                .offset(y: pageOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .brandAnimation(BrandMotion.rise, value: banner)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xxl, style: .continuous))
        .overlay { PremiumToastHost() }
        .themeShadow(.card)
        .padding(.top, 6)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
    }

    private func run(_ action: WindowBanner.Action) {
        switch action {
        case .fix(let fix):
            viewModel.perform(fix)
        case .downloadModel:
            // Starts the download, then shows its progress in the Engine group.
            viewModel.models.download(viewModel.models.activeModel)
            viewModel.navigate(to: SidebarSection.settings.rawValue, anchor: "engine")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch displayed {
        case .stream:
            StreamPage(viewModel: viewModel, settings: settings)
        case .notes:
            NotesPage(viewModel: viewModel)
        case .vocabulary:
            VocabularyPage(viewModel: viewModel)
        case .insights:
            InsightsPage(viewModel: viewModel, settings: settings)
        case .settings:
            SettingsPage(settings: settings, viewModel: viewModel, firstRun: firstRun,
                         anchor: $settingsAnchor)
        }
    }
}
