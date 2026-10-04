import SwiftUI
import UsefulVoiceCore

/// The first-run flow, covering the whole window. Pages cross-fade with a short
/// slide in the direction of travel: the next page is mounted first, invisible,
/// and the motion starts on the following run-loop turn, so the stage is never
/// blank. Reduce Motion is a plain 0.2 s crossfade.
struct FirstRunView: View {
    @ObservedObject var model: FirstRunModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Layer: Equatable {
        let page: FirstRunModel.Page
        let visit: Int
        var key: String { "\(page.rawValue)#\(visit)" }
    }

    @State private var layers: [Layer]
    @State private var visits = 0
    @State private var opacity: [String: Double] = [:]
    @State private var offset: [String: CGFloat] = [:]
    @State private var yOffset: [String: CGFloat] = [:]
    @State private var pendingDrop: DispatchWorkItem?
    @State private var moving = false
    @State private var shown: FirstRunModel.Page

    init(model: FirstRunModel) {
        self.model = model
        _layers = State(initialValue: [Layer(page: model.page, visit: 0)])
        _shown = State(initialValue: model.page)
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            ZStack {
                Theme.surface
                ZStack {
                    ForEach(layers, id: \.key) { layer in
                        content(layer.page)
                            .opacity(opacity[layer.key] ?? 1)
                            .offset(x: offset[layer.key] ?? 0, y: yOffset[layer.key] ?? 0)
                            .allowsHitTesting(layer == layers.last && !moving)
                            .disabled(layer != layers.last)
                            .accessibilityHidden(layer != layers.last)
                    }
                }
                if model.startedFromSettings {
                    Button(action: model.closeSetup) {
                        Text("Close")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.inkMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .clickableCursor()
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            // The traffic lights sit in the band above the stage.
            .padding(EdgeInsets(top: 34, leading: 10, bottom: 10, trailing: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.page) { _, next in
            move(from: shown, to: next)
            shown = next
        }
    }

    @ViewBuilder
    private func content(_ page: FirstRunModel.Page) -> some View {
        switch page {
        case .welcome: FRWelcomePage { model.go(.engine) }
        case .engine: FREnginePage(model: model, models: model.models)
        case .deepgramKey: FRDeepgramKeyPage(model: model)
        case .localDownload: FRLocalDownloadPage(model: model, models: model.models)
        case .microphone: FRMicrophonePage(model: model)
        case .accessibility: FRAccessibilityPage(model: model)
        case .tryIt: FRTryItPage(model: model, viewModel: model.viewModel)
        case .done: FRDonePage(model: model)
        }
    }

    private func move(from old: FirstRunModel.Page, to next: FirstRunModel.Page) {
        pendingDrop?.cancel()
        moving = true
        let fromWelcome = old == .welcome
        let direction: CGFloat = next.rawValue < old.rawValue ? -1 : 1
        visits += 1
        let incoming = Layer(page: next, visit: visits)
        let outgoing = layers.last
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            layers = (outgoing.map { [$0] } ?? []) + [incoming]
            opacity[incoming.key] = 0
            offset[incoming.key] = reduceMotion ? 0 : (fromWelcome ? 0 : 28 * direction)
            yOffset[incoming.key] = reduceMotion || !fromWelcome ? 0 : 16
        }
        DispatchQueue.main.async {
            let curve: Animation = reduceMotion
                ? .easeOut(duration: 0.2) : BrandMotion.easeOut(duration: 0.32)
            if let outgoing {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : BrandMotion.easeOut(duration: 0.15)) {
                    opacity[outgoing.key] = 0
                    if !reduceMotion && !fromWelcome { offset[outgoing.key] = -20 * direction }
                }
            }
            withAnimation(curve.delay(reduceMotion ? 0 : (fromWelcome ? 0.13 : 0.11))) {
                opacity[incoming.key] = 1
                offset[incoming.key] = 0
                yOffset[incoming.key] = 0
            }
            let drop = DispatchWorkItem {
                layers.removeAll { $0 != incoming }
                opacity = opacity.filter { $0.key == incoming.key }
                offset = offset.filter { $0.key == incoming.key }
                yOffset = yOffset.filter { $0.key == incoming.key }
                moving = false
            }
            pendingDrop = drop
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: drop)
            // Clickable again once the new page is mostly in.
            let settle = visits
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if visits == settle { moving = false }
            }
        }
    }
}
