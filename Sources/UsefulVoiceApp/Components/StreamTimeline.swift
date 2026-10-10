import SwiftUI
import UsefulVoiceCore

/// All stored dictations grouped by day, newest at the bottom. Rows are lazy, so 1.000
/// dictations cost what the screen shows. It opens at the bottom and follows a new
/// dictation only when you were already there.
struct StreamTimeline: View {
    @ObservedObject var store: StreamStore
    @ObservedObject var viewModel: UsefulVoiceViewModel
    let settings: AppSettings

    @FocusState private var focused: Bool
    @State private var atBottom = true

    private static let bottomID = "stream-bottom"
    static let scrollSpace = "stream-scroll"

    var body: some View {
        ZStack {
            keySink
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                        ForEach(store.days) { day in
                            Section {
                                ForEach(day.records) { record in
                                    StreamBubble(record: record, store: store)
                                        .id(record.id)
                                        .transition(.brandRise())
                                }
                            } header: {
                                StreamDayBand(day: day, store: store) { target in
                                    withAnimation(BrandMotion.resolved(BrandMotion.rise)) {
                                        proxy.scrollTo(target, anchor: .top)
                                    }
                                }
                                .id(day.id)
                            }
                        }
                        StreamGhostBubble(viewModel: viewModel, telemetry: viewModel.telemetry, settings: settings)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
                .coordinateSpace(name: Self.scrollSpace)
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.focusedID) { _, id in
                    guard let id else { return }
                    focused = true
                    withAnimation(BrandMotion.resolved(BrandMotion.control)) { proxy.scrollTo(id) }
                }
                .onChange(of: store.selection) { _, selection in
                    // Esc clears the selection, so the list must hold the keyboard.
                    if !selection.isEmpty { focused = true }
                }
                .onChange(of: store.arrivals) { _, _ in
                    guard atBottom else { return }
                    withAnimation(BrandMotion.resolved(BrandMotion.rise)) {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: store.query) { _, _ in scrollToBottom(proxy) }
                .onChange(of: store.scope) { _, _ in scrollToBottom(proxy) }
                .onAppear { scrollToBottom(proxy) }
            }
        }
    }

    /// The list's one tab stop. It is a separate view, not `.focusable()` on the scroll
    /// view, because focus on a container makes every button inside it draw a focus ring.
    /// Arrow keys move from bubble to bubble, Enter opens the action menu, Esc clears.
    private var keySink: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .accessibilityLabel("Dictations")
            .onKeyPress(.upArrow) { store.moveFocus(-1); return .handled }
            .onKeyPress(.downArrow) { store.moveFocus(1); return .handled }
            .onKeyPress(.return) {
                guard let id = store.focusedID else { return .ignored }
                store.menuID = id
                return .handled
            }
            .onKeyPress(.escape) {
                if !store.selection.isEmpty { store.clearSelection(); return .handled }
                if store.teachSelectID != nil { store.teachSelectID = nil; return .handled }
                if store.focusedID != nil { store.focusedID = nil; return .handled }
                return .ignored
            }
    }

    /// Lazy rows are positioned by estimate until they are laid out, so one jump can land
    /// short. Jumping again as the rows settle lands on the real bottom.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        for delay in [0.0, 0.1, 0.35] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }
}

/// The sticky day band: opaque, and a button that opens the date jump.
private struct StreamDayBand: View {
    let day: StreamDay
    @ObservedObject var store: StreamStore
    let jump: (Date) -> Void

    @State private var open = false
    /// True while the band is stuck to the top of the list: the hairline shows then.
    @State private var pinned = false

    var body: some View {
        HStack(spacing: 0) {
            Button { open = true } label: {
                HStack(spacing: 6) {
                    Text(StreamFormat.dayTitle(day.day))
                        .font(.uv(.meta, .semibold))
                    Image(systemName: "chevron.down")
                        .font(.uv(.label, .semibold))
                }
                .foregroundStyle(Theme.inkMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .popover(isPresented: $open, arrowEdge: .bottom) {
                StreamDateJump(days: store.days) { picked in
                    open = false
                    jump(picked)
                }
            }
            .accessibilityLabel("\(StreamFormat.dayTitle(day.day)), jump to a date")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1).opacity(pinned ? 1 : 0)
        }
        .padding(.horizontal, -28)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.frame(in: .named(StreamTimeline.scrollSpace)).minY) { _, y in
                        pinned = y <= 1
                    }
            }
        }
    }
}
