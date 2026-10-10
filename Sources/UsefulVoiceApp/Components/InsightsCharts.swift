import SwiftUI
import Charts
import UsefulVoiceCore

/// The three ink steps of the board's data colors. All clear 3:1 on their tile, in both
/// themes: k1 is ink, k2 is ink at 64 % and k3 is ink at 50 % over the tile (the dark
/// values are re-mixed against the dark tile, as the board does). `track` is the empty
/// groove, ink at 7 %, and `k4` the lightest step for a fourth series.
enum InsightsInk {
    static let k1 = Theme.ink
    static let k2 = Theme.dynamic(light: 0x6A6A6A, dark: 0xA3A3A3)
    static let k3 = Theme.dynamic(light: 0x8B8B8B, dark: 0x868686)
    static let k4 = Theme.dynamic(light: 0xB5B5B5, dark: 0x626262)
    static let track = Theme.dynamic(light: 0xEFEFEF, dark: 0x2E2E2E)

    static func step(_ i: Int) -> Color {
        [k1, k2, k3, k4][min(max(i, 0), 3)]
    }
}

// MARK: - Geometry

extension Path {
    /// A smooth curve through the points that never overshoots between them (monotone
    /// cubic, Fritsch-Carlson), so a day of zero words never dips below the axis.
    static func monotone(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        let n = points.count
        if n == 1 { return path }
        if n == 2 { path.addLine(to: points[1]); return path }
        let xs = points.map(\.x), ys = points.map(\.y)
        let h = (0..<(n - 1)).map { xs[$0 + 1] - xs[$0] }
        let d = (0..<(n - 1)).map { (ys[$0 + 1] - ys[$0]) / h[$0] }
        var m = [CGFloat](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            if d[i - 1] * d[i] <= 0 {
                m[i] = 0
            } else {
                let p = (d[i - 1] * h[i] + d[i] * h[i - 1]) / (h[i - 1] + h[i])
                let s: CGFloat = d[i] > 0 ? 1 : -1
                m[i] = s * min(abs(d[i - 1]), abs(d[i]), 0.5 * abs(p)) * 2
            }
        }
        m[0] = (3 * d[0] - m[1]) / 2
        m[n - 1] = (3 * d[n - 2] - m[n - 2]) / 2
        if m[0] * d[0] < 0 { m[0] = 0 }
        if m[n - 1] * d[n - 2] < 0 { m[n - 1] = 0 }
        for i in 0..<(n - 1) {
            path.addCurve(
                to: points[i + 1],
                control1: CGPoint(x: xs[i] + h[i] / 3, y: ys[i] + m[i] * h[i] / 3),
                control2: CGPoint(x: xs[i + 1] - h[i] / 3, y: ys[i + 1] - m[i + 1] * h[i] / 3))
        }
        return path
    }
}

// MARK: - Hero chart

/// Words per day or per week: a smooth area with a dashed average, the best point and
/// today annotated, and a hover readout. Drawn in Canvas so every label sits exactly where
/// the board puts it.
struct InsightsHeroChartView: View {
    let chart: InsightsHeroChart
    @State private var hover: Int?

    /// Room for the widest y label ("40.000"), never less than the board's 44.
    private var left: CGFloat {
        max(44, CGFloat(InsightsFormat.grouped(Int(chart.yMax)).count) * 6.8 + 16)
    }
    private let right: CGFloat = 14
    private let top: CGFloat = 34
    private let bottom: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                draw(&context, size: size, hover: hover)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hover = nearestIndex(x: point.x, width: proxy.size.width)
                case .ended:
                    hover = nil
                }
            }
        }
        .frame(height: 254)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard !chart.values.isEmpty else { return "\(chart.title), no dictations yet" }
        let peak = chart.values[chart.bestIndex]
        return "\(chart.title). \(chart.bestTitle) with \(InsightsFormat.grouped(peak)) words. "
            + "\(chart.todayTitle) \(chart.todaySubtitle)."
    }

    private func nearestIndex(x: CGFloat, width: CGFloat) -> Int? {
        guard chart.values.count > 0 else { return nil }
        let plot = width - left - right
        guard plot > 0, chart.slots > 1 else { return 0 }
        let i = Int(((x - left) / (plot / CGFloat(chart.slots - 1))).rounded())
        return min(max(i, 0), chart.values.count - 1)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, hover: Int?) {
        let plotW = size.width - left - right
        let plotH = size.height - top - bottom
        let slots = max(chart.slots, 2)
        let step = plotW / CGFloat(slots - 1)
        func x(_ i: Int) -> CGFloat { left + CGFloat(i) * step }
        func y(_ v: Double) -> CGFloat { top + plotH * (1 - CGFloat(v / chart.yMax)) }
        let baseline = y(0)

        // Grid and y labels.
        for g in [0, chart.yMax / 2, chart.yMax] {
            var line = Path()
            line.move(to: CGPoint(x: left, y: y(g)))
            line.addLine(to: CGPoint(x: size.width - right, y: y(g)))
            ctx.stroke(line, with: .color(Theme.line), lineWidth: 1)
            label(&ctx, InsightsFormat.grouped(Int(g)), at: CGPoint(x: left - 10, y: y(g)),
                  anchor: .trailing, font: .uv(.label), color: Theme.inkMuted)
        }

        // X labels.
        for item in chart.xLabels {
            let anchor: UnitPoint = item.index == 0 ? .bottomLeading
                : (item.index == slots - 1 ? .bottomTrailing : .bottom)
            label(&ctx, item.text, at: CGPoint(x: x(item.index), y: size.height - 3), anchor: anchor,
                  font: .uv(.label), color: Theme.inkMuted)
        }

        guard !chart.values.isEmpty else {
            // No data: the axes stay, with a dashed baseline.
            var base = Path()
            base.move(to: CGPoint(x: left, y: baseline))
            base.addLine(to: CGPoint(x: size.width - right, y: baseline))
            ctx.stroke(base, with: .color(Theme.inkMuted),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
            return
        }

        let points = chart.values.enumerated().map { CGPoint(x: x($0.offset), y: y(Double($0.element))) }

        if points.count > 1 {
            let curve = Path.monotone(points)
            var area = curve
            area.addLine(to: CGPoint(x: points.last!.x, y: baseline))
            area.addLine(to: CGPoint(x: points[0].x, y: baseline))
            area.closeSubpath()
            ctx.fill(area, with: .color(Theme.ink.opacity(0.07)))
        }

        if chart.futureSlots > 0 {
            var future = Path()
            future.move(to: CGPoint(x: points.last!.x, y: baseline))
            future.addLine(to: CGPoint(x: x(slots - 1), y: baseline))
            ctx.stroke(future, with: .color(Theme.inkMuted),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
        }

        // Average rule.
        if let average = chart.average {
            let ay = y(Double(average))
            var rule = Path()
            rule.move(to: CGPoint(x: left, y: ay))
            rule.addLine(to: CGPoint(x: size.width - right, y: ay))
            ctx.stroke(rule, with: .color(Theme.inkMuted), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            let text = "Average \(InsightsFormat.grouped(average))"
            if chart.slots <= 7 {
                label(&ctx, text, at: CGPoint(x: size.width - right, y: ay - 11), anchor: .trailing,
                      font: .uv(.label), color: Theme.inkMuted, halo: true)
            } else {
                label(&ctx, text, at: CGPoint(x: left + 4, y: ay - 11), anchor: .leading,
                      font: .uv(.label), color: Theme.inkMuted, halo: true)
            }
        }

        if points.count > 1 {
            ctx.stroke(Path.monotone(points), with: .color(Theme.ink),
                       style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
        }
        if chart.showDots {
            for p in points { dot(&ctx, p, radius: 3, ring: 2) }
        }

        // Best point: a drop line, the dot and two lines of text.
        let best = points[chart.bestIndex]
        var drop = Path()
        drop.move(to: CGPoint(x: best.x, y: best.y + 6))
        drop.addLine(to: CGPoint(x: best.x, y: baseline))
        ctx.stroke(drop, with: .color(Theme.inkMuted), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        dot(&ctx, best, radius: 4.5, ring: 2.5)

        let valueText = InsightsFormat.grouped(chart.values[chart.bestIndex])
        let sideLabel = chart.title == "Words per day" && slots >= 20
        if sideLabel {
            let onRight = chart.bestIndex <= slots - 8
            let dx: CGFloat = onRight ? 11 : -11
            let anchor: UnitPoint = onRight ? .leading : .trailing
            label(&ctx, valueText, at: CGPoint(x: best.x + dx, y: best.y - 2), anchor: anchor,
                  font: .uv(.ui, .semibold), color: Theme.ink, halo: true)
            label(&ctx, chart.bestTitle, at: CGPoint(x: best.x + dx, y: best.y + 14), anchor: anchor,
                  font: .uv(.label), color: Theme.inkMuted, halo: true)
        } else {
            let edge: UnitPoint = chart.bestIndex == 0 ? .leading
                : (chart.bestIndex == slots - 1 ? .trailing : .center)
            let ox: CGFloat = chart.bestIndex == 0 ? -4 : 0
            label(&ctx, valueText, at: CGPoint(x: best.x + ox, y: best.y - 34), anchor: edge,
                  font: .uv(.ui, .semibold), color: Theme.ink, halo: true)
            label(&ctx, chart.bestTitle, at: CGPoint(x: best.x + ox, y: best.y - 18), anchor: edge,
                  font: .uv(.label), color: Theme.inkMuted, halo: true)
        }

        // Today (or this week): a dot and its figure, unless it is the best point itself.
        let lastIndex = points.count - 1
        if lastIndex != chart.bestIndex {
            let p = points[lastIndex]
            dot(&ctx, p, radius: 4.5, ring: 2.5)
            let anchor: UnitPoint = lastIndex >= slots - 2 ? .trailing : .center
            let ox: CGFloat = anchor == .trailing ? -2 : 0
            let below = p.y + 38 < baseline + 4
            let nameY = below ? p.y + 17 : p.y - 34
            let subY = below ? p.y + 32 : p.y - 18
            label(&ctx, chart.todayTitle, at: CGPoint(x: p.x + ox, y: nameY), anchor: anchor,
                  font: .uv(.ui, .semibold), color: Theme.ink, halo: true)
            label(&ctx, chart.todaySubtitle, at: CGPoint(x: p.x + ox, y: subY), anchor: anchor,
                  font: .uv(.label), color: Theme.inkMuted, halo: true)
        }

        // Hover readout.
        if let hover, hover < points.count {
            let p = points[hover]
            var guide = Path()
            guide.move(to: CGPoint(x: p.x, y: top - 6))
            guide.addLine(to: CGPoint(x: p.x, y: baseline))
            ctx.stroke(guide, with: .color(Theme.inkMuted.opacity(0.6)), lineWidth: 1)
            dot(&ctx, p, radius: 4.5, ring: 2.5)
            let text = "\(chart.valueLabels[hover])  \(InsightsFormat.grouped(chart.values[hover]))"
            let anchor: UnitPoint = p.x > size.width * 0.6 ? .topTrailing : .topLeading
            label(&ctx, text, at: CGPoint(x: p.x + (anchor == .topTrailing ? -8 : 8), y: top - 24),
                  anchor: anchor, font: .uv(.meta, .semibold), color: Theme.ink, halo: true)
        }
    }

    private func dot(_ ctx: inout GraphicsContext, _ p: CGPoint, radius: CGFloat, ring: CGFloat) {
        let outer = CGRect(x: p.x - radius - ring / 2, y: p.y - radius - ring / 2,
                           width: (radius + ring / 2) * 2, height: (radius + ring / 2) * 2)
        ctx.fill(Path(ellipseIn: outer), with: .color(Theme.bubble))
        let inner = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
        ctx.fill(Path(ellipseIn: inner), with: .color(Theme.ink))
    }

    private func label(_ ctx: inout GraphicsContext, _ string: String, at point: CGPoint, anchor: UnitPoint,
                       font: Font, color: Color, halo: Bool = false) {
        if halo {
            let ring = ctx.resolve(Text(string).font(font).monospacedDigit().foregroundStyle(Theme.bubble))
            for k in 0..<8 {
                let a = Double(k) * .pi / 4
                ctx.draw(ring, at: CGPoint(x: point.x + 2 * cos(a), y: point.y + 2 * sin(a)), anchor: anchor)
            }
        }
        ctx.draw(ctx.resolve(Text(string).font(font).monospacedDigit().foregroundStyle(color)),
                 at: point, anchor: anchor)
    }
}

// MARK: - Rings

/// Daily goal on the outside, streak inside: two stroked circles trimmed to their fraction.
struct InsightsRings: View {
    let goal: Double
    let streak: Double

    var body: some View {
        ZStack {
            ring(radius: 76, fraction: goal, color: InsightsInk.k1)
            ring(radius: 52, fraction: streak, color: InsightsInk.k2)
        }
        .frame(width: 170, height: 170)
        .accessibilityElement()
        .accessibilityLabel(
            "Daily goal \(Int((goal * 100).rounded())) percent done, streak at \(Int((streak * 100).rounded())) percent of your best")
    }

    private func ring(radius: CGFloat, fraction: Double, color: Color) -> some View {
        ZStack {
            Circle().stroke(InsightsInk.track, lineWidth: 18)
            if fraction > 0 {
                Circle()
                    .trim(from: 0, to: min(fraction, 1))
                    .stroke(color, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

// MARK: - 24 hour radial

/// Words by hour of day: 24 wedges around a hollow centre, length by words, the busiest
/// hour in ink. Canvas, because a sector mark encodes angle and these encode length.
struct InsightsRadial: View {
    let hours: [Int]
    var empty = false

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let inner: CGFloat = 22, outer: CGFloat = 78
            let peak = max(hours.max() ?? 0, 1)
            let peakHour = empty ? -1 : (hours.firstIndex(of: hours.max() ?? 0) ?? -1)

            if empty {
                for h in 0..<24 {
                    ctx.fill(Self.sector(c, inner, outer, Double(h) * 15 + 1.8, Double(h) * 15 + 13.2),
                             with: .color(InsightsInk.track))
                }
            } else {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2)),
                           with: .color(Theme.line), lineWidth: 1)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - inner + 4, y: c.y - inner + 4,
                                                  width: (inner - 4) * 2, height: (inner - 4) * 2)),
                           with: .color(Theme.line), lineWidth: 1)
                for (h, v) in hours.enumerated() where v > 0 {
                    let r1 = inner + max(5, (outer - inner) * CGFloat(v) / CGFloat(peak))
                    let path = Self.sector(c, inner, r1, Double(h) * 15 + 1.8, Double(h) * 15 + 13.2)
                    let color = h == peakHour ? InsightsInk.k1 : InsightsInk.k3
                    ctx.fill(path, with: .color(color))
                    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            for (h, t) in [(0, "00"), (6, "06"), (12, "12"), (18, "18")] {
                let a = Double(h) * 15 * .pi / 180
                let p = CGPoint(x: c.x + (outer + 10) * CGFloat(sin(a)), y: c.y - (outer + 10) * CGFloat(cos(a)))
                ctx.draw(ctx.resolve(Text(t).font(.uv(.label)).monospacedDigit().foregroundStyle(Theme.inkMuted)),
                         at: p, anchor: .center)
            }
        }
        .frame(width: 192, height: 192)
        .accessibilityElement()
        .accessibilityLabel(empty ? "Words by hour of day, no data yet"
                            : "Words by hour of day, busiest at \(InsightsFormat.hour(hours.firstIndex(of: hours.max() ?? 0) ?? 0))")
    }

    /// An annular sector from `a0` to `a1` degrees clockwise from the top.
    static func sector(_ c: CGPoint, _ r0: CGFloat, _ r1: CGFloat, _ a0: Double, _ a1: Double) -> Path {
        func point(_ r: CGFloat, _ deg: Double) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
        }
        let steps = max(2, Int(((a1 - a0) / 1.5).rounded(.up)))
        var path = Path()
        path.move(to: point(r1, a0))
        for s in 1...steps { path.addLine(to: point(r1, a0 + (a1 - a0) * Double(s) / Double(steps))) }
        for s in stride(from: steps, through: 0, by: -1) {
            path.addLine(to: point(r0, a0 + (a1 - a0) * Double(s) / Double(steps)))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Speed trend

/// Words per minute over time, a Swift Charts line with the two end values labelled.
struct InsightsSpeedTrend: View {
    let values: [Double]

    var body: some View {
        let lo = (values.min() ?? 0), hi = (values.max() ?? 1)
        let pad = max((hi - lo) * 0.25, 4)
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("Day", i), y: .value("Words per minute", v))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Theme.ink)
            }
            if let first = values.first {
                PointMark(x: .value("Day", 0), y: .value("Words per minute", first))
                    .symbolSize(40).foregroundStyle(Theme.ink)
                    .annotation(position: .top, alignment: .leading, spacing: 4) {
                        Text("\(Int(first.rounded()))").font(.uv(.label)).monospacedDigit()
                            .foregroundStyle(Theme.inkMuted)
                    }
            }
            if let last = values.last, values.count > 1 {
                PointMark(x: .value("Day", values.count - 1), y: .value("Words per minute", last))
                    .symbolSize(40).foregroundStyle(Theme.ink)
                    .annotation(position: .top, alignment: .trailing, spacing: 4) {
                        Text("\(Int(last.rounded()))").font(.uv(.label)).monospacedDigit()
                            .foregroundStyle(Theme.inkMuted)
                    }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: (lo - pad)...(hi + pad))
        .chartXScale(domain: 0...Double(max(values.count - 1, 1)))
        .chartPlotStyle { $0.padding(.horizontal, 4) }
        .frame(height: 92)
        .accessibilityLabel("Words per minute, from \(Int((values.first ?? 0).rounded())) to \(Int((values.last ?? 0).rounded()))")
    }
}
