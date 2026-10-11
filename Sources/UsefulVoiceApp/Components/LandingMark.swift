import SwiftUI

/// The Useful Voice mark, Swell: five round bars (heights 7, 13, 19, 13, 7) on a 24u
/// grid. Below `hintedBelow` points it switches to the hand-hinted 16u cut so edges
/// stay on pixels.
///
/// - `.live(levels:)`: each of the five bars scales on its own channel.
/// - `init(level:)`: one raw mic level is mapped to dB, smoothed and spread over the
///   five channels (see `scales`).
/// - `.idle` and `.still`: the static mark.
/// Reduce Motion: bars follow the level with no ripple.
struct LandingMark: View {
    enum Style: Equatable {
        case live(levels: [Float])
        case idle
        case still

        /// Five bar scales from one mapped level `a` (0...1). Loudness sets each bar's
        /// reach, and a per-bar sine at its own speed and offset keeps the bars out of
        /// lockstep. `time` nil means no ripple (Reduce Motion).
        static func scales(level a: Double, time: Double?) -> [Float] {
            (0..<5).map { i in
                var v = 0.32 + 0.95 * a
                if let time {
                    let rate = (5 + 4 * a) * (1 + 0.13 * Double(i))
                    v += sin(time * rate + 1.3 * Double(i)) * (0.05 + 0.2 * a)
                }
                return Float(min(max(v, 0.28), 1.2))
            }
        }
    }

    let style: Style
    var size: CGFloat = 24
    var fill: Color = Theme.ink
    /// Raw mic level when the five channels should be derived.
    var derivedFrom: Float? = nil
    var hintedBelow: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoother = Smoother()
    @State private var levelSmoother = MicLevel.Smoother()

    /// Live mark fed by a single raw mic level.
    init(level: Float, size: CGFloat = 24, fill: Color = Theme.ink) {
        self.style = .live(levels: [])
        self.derivedFrom = level
        self.size = size
        self.fill = fill
    }

    init(style: Style, size: CGFloat = 24, fill: Color = Theme.ink) {
        self.style = style
        self.size = size
        self.fill = fill
    }

    var body: some View {
        Group {
            switch style {
            case .still, .idle:
                Canvas { ctx, sz in Self.draw(ctx, sz, hinted: size < hintedBelow, fill: fill,
                                              scales: [1, 1, 1, 1, 1]) }
            case .live(let levels):
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let target = targets(levels: levels, t: t)
                    let scales = smoother.step(to: target, at: t)
                    Canvas { ctx, sz in Self.draw(ctx, sz, hinted: size < hintedBelow, fill: fill,
                                                  scales: scales) }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func targets(levels: [Float], t: Double) -> [Float] {
        if let level = derivedFrom {
            let a = levelSmoother.step(rms: level, at: t)
            return Style.scales(level: a, time: reduceMotion ? nil : t)
        }
        return levels.count == 5 ? levels : [1, 1, 1, 1, 1]
    }

    /// Eases each channel toward its target in about 55 ms.
    final class Smoother {
        private var value: [Float] = [0.4, 0.4, 0.4, 0.4, 0.4]
        private var last: Double?
        func step(to target: [Float], at time: Double) -> [Float] {
            guard let previous = last else {
                last = time
                value = target
                return value
            }
            let dt = min(max(time - previous, 0), 0.1)
            last = time
            let k = Float(1 - exp(-dt / 0.055))
            for i in 0..<5 { value[i] += (target[i] - value[i]) * k }
            return value
        }
    }

    // 24u master (centre y 12) and 16u hinted cut (centre y 8): bar x, width, height.
    private static let bars24: [(x: CGFloat, w: CGFloat, h: CGFloat)] = [
        (1.6, 2.8, 7), (6.1, 2.8, 13), (10.6, 2.8, 19), (15.1, 2.8, 13), (19.6, 2.8, 7)]
    private static let bars16: [(x: CGFloat, w: CGFloat, h: CGFloat)] = [
        (1, 2, 4), (4, 2, 8), (7, 2, 12), (10, 2, 8), (13, 2, 4)]

    private static func draw(_ ctx: GraphicsContext, _ size: CGSize, hinted: Bool, fill: Color,
                             scales: [Float]) {
        let grid: CGFloat = hinted ? 16 : 24
        let s = min(size.width, size.height) / grid
        let ox = (size.width - grid * s) / 2
        let oy = (size.height - grid * s) / 2
        let centre: CGFloat = grid / 2
        for (i, bar) in (hinted ? bars16 : bars24).enumerated() {
            let h = min(max(bar.h * CGFloat(scales[i]), bar.w), grid)
            let rect = CGRect(x: ox + bar.x * s, y: oy + (centre - h / 2) * s, width: bar.w * s, height: h * s)
            ctx.fill(Path(roundedRect: rect, cornerRadius: bar.w * s / 2), with: .color(fill))
        }
    }
}

/// The app-icon tile with the Swell mark in it (rail logo, first run): the dark tile
/// (`app-icon-dark.svg`) in the light appearance and the light tile
/// (`app-icon-light.svg`) in the dark one, so the logo always stands out from
/// the canvas instead of sinking into a dark rail.
struct LandingTile: View {
    let size: CGFloat
    var radius: CGFloat? = nil
    var animated = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let r = radius ?? size * 0.25
        let dark = colorScheme == .dark
        LandingMark(style: animated && !reduceMotion ? .idle : .still,
                    size: size * 0.55, fill: dark ? Theme.markTile : Theme.hudInk)
            .frame(width: size, height: size)
            .background(dark ? Theme.hudInk : Theme.markTile,
                        in: RoundedRectangle(cornerRadius: r, style: .continuous))
            .accessibilityElement()
            .accessibilityLabel("Useful Voice")
    }
}
