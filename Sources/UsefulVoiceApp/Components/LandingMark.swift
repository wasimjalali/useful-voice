import SwiftUI

/// The Useful Voice mark: three round sound bars landing on a square-cut I-beam caret,
/// drawn on the board's 24u grid (logo-1, "Chosen: Landing, refined"). Below
/// `hintedBelow` points it switches to the hand-hinted 16u cut so edges stay on pixels.
///
/// - `.live(levels:)`: each bar scales on its own channel (0...1.35 around its centre line).
/// - `.live(level:)`: derives the three channels from one mic level (see `channels`).
/// - `.idle`: bars at rest, the caret blinks (1.06 s period, on for the first 55 %).
/// - `.still`: static mark.
/// Reduce Motion: bars follow the level with no ripple, the caret does not blink.
struct LandingMark: View {
    enum Style: Equatable {
        case live(levels: [Float])
        case idle
        case still

        /// One mic level in, three bar channels out. Loudness sets each channel's reach
        /// (quiet bars stay near their floor, loud ones open up), and `phase` adds a
        /// per-bar sine ripple at a different speed and offset so the bars never move in
        /// lockstep. `phase` nil means no ripple (Reduce Motion).
        static func channels(level: Float, phase: Double?) -> [Float] {
            let norm = Double(min(max(level * 11, 0), 1))
            return (0..<3).map { k in
                let range = Self.ranges[k]
                var value = range.lo + norm * (range.hi - range.lo) * 0.85
                if let phase {
                    let ripple = sin(phase * (6 + 5 * norm) * range.speed + Double(k) * 1.3)
                    value += ripple * (0.04 + 0.18 * norm)
                }
                return Float(min(max(value, range.lo), range.hi))
            }
        }
        private static let ranges: [(lo: Double, hi: Double, speed: Double)] = [
            (0.30, 1.35, 1.0), (0.35, 1.15, 1.17), (0.40, 1.10, 0.89)
        ]
    }

    let style: Style
    var size: CGFloat = 24
    var fill: Color = Theme.ink
    /// Source levels (raw mic level) when the three channels should be derived.
    var derivedFrom: Float? = nil
    var hintedBelow: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var smoother = Smoother()

    /// Live mark fed by a single mic level (the HUD today).
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
            case .still:
                Canvas { ctx, sz in Self.draw(ctx, sz, hinted: size < hintedBelow, fill: fill,
                                              scales: [1, 1, 1], caret: true) }
            case .idle:
                if reduceMotion {
                    Canvas { ctx, sz in Self.draw(ctx, sz, hinted: size < hintedBelow, fill: fill,
                                                  scales: [1, 1, 1], caret: true) }
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
                        let t = timeline.date.timeIntervalSinceReferenceDate
                        let on = t.truncatingRemainder(dividingBy: 1.06) < 1.06 * 0.55
                        Canvas { ctx, sz in Self.draw(ctx, sz, hinted: size < hintedBelow, fill: fill,
                                                      scales: [1, 1, 1], caret: on) }
                    }
                }
            case .live(let levels):
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let target = targets(levels: levels, t: t)
                    let scales = smoother.step(to: target, at: t)
                    Canvas { ctx, sz in Self.draw(ctx, sz, hinted: size < hintedBelow, fill: fill,
                                                  scales: scales, caret: true) }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func targets(levels: [Float], t: Double) -> [Float] {
        if let level = derivedFrom {
            return Style.channels(level: level, phase: reduceMotion ? nil : t)
        }
        return levels.count == 3 ? levels : [1, 1, 1]
    }

    /// Eases each channel toward its target in about 160 ms (the board's transition).
    final class Smoother {
        private var value: [Float] = [0.3, 0.35, 0.4]
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
            for i in 0..<3 { value[i] += (target[i] - value[i]) * k }
            return value
        }
    }

    // 24u master and 16u hinted cut (bars x, width, height; caret path).
    private static let bars24: [(x: CGFloat, w: CGFloat, h: CGFloat)] = [(1, 3, 6), (6, 3, 10), (11, 3, 14)]
    private static let bars16: [(x: CGFloat, w: CGFloat, h: CGFloat)] = [(1, 2, 4), (4, 2, 6), (7, 2, 10)]

    private static func caret(hinted: Bool) -> Path {
        var p = Path()
        let pts: [(CGFloat, CGFloat)] = hinted
            ? [(11, 1), (15, 1), (15, 3), (14, 3), (14, 13), (15, 13), (15, 15), (11, 15), (11, 13), (12, 13), (12, 3), (11, 3)]
            : [(16, 2), (23, 2), (23, 5), (21, 5), (21, 19), (23, 19), (23, 22), (16, 22), (16, 19), (18, 19), (18, 5), (16, 5)]
        p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
        p.closeSubpath()
        return p
    }

    private static func draw(_ ctx: GraphicsContext, _ size: CGSize, hinted: Bool, fill: Color,
                             scales: [Float], caret drawCaret: Bool) {
        let grid: CGFloat = hinted ? 16 : 24
        let s = min(size.width, size.height) / grid
        let ox = (size.width - grid * s) / 2
        let oy = (size.height - grid * s) / 2
        let centre: CGFloat = grid / 2
        for (i, bar) in (hinted ? bars16 : bars24).enumerated() {
            let h = bar.h * CGFloat(scales[i])
            let rect = CGRect(x: ox + bar.x * s, y: oy + (centre - h / 2) * s, width: bar.w * s, height: h * s)
            ctx.fill(Path(roundedRect: rect, cornerRadius: bar.w * s / 2), with: .color(fill))
        }
        if drawCaret {
            let transform = CGAffineTransform(scaleX: s, y: s).translatedBy(x: ox / s, y: oy / s)
            ctx.fill(caret(hinted: hinted).applying(transform), with: .color(fill))
        }
    }
}

/// The dark app-icon tile with the mark in it (rail logo, first run).
struct LandingTile: View {
    let size: CGFloat
    var radius: CGFloat? = nil
    var animated = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let r = radius ?? size * 0.25
        LandingMark(style: animated && !reduceMotion ? .idle : .still,
                    size: size * 0.55, fill: Theme.hudInk)
            .frame(width: size, height: size)
            // The tile is dark in both appearances (the board's dark default
            // tile); on a dark canvas a 1px tone ring keeps its edge visible.
            .background(Theme.markTile, in: RoundedRectangle(cornerRadius: r, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous)
                .strokeBorder(Theme.tone, lineWidth: 1))
            .accessibilityElement()
            .accessibilityLabel("Useful Voice")
    }
}
