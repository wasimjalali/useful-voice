import SwiftUI

/// The pill's live waveform: 16 bars, 2 pt wide, in a 44 by 14 pt box. Every 50 ms
/// the smoothed, dB-mapped mic level is pushed into the history (newest on the
/// right). A bar is 2 pt at silence up to 14 pt, and fades from 0.45 to 1 with its level.
/// The history starts empty for each recording. It is data, so Reduce Motion does
/// not change it.
struct HUDWaveform: View {
    /// Raw mic RMS.
    let level: Float
    let color: Color
    /// Snapshot only: a ready-made history (mapped values, oldest first).
    var fixture: [Double]? = nil

    static let barCount = 16
    static let size = CGSize(width: 44, height: 14)
    private static let barWidth: CGFloat = 2
    private static let minHeight: CGFloat = 2

    @State private var model = Model()

    final class Model {
        var history = [Double](repeating: 0, count: HUDWaveform.barCount)
        let smoother = MicLevel.Smoother()
        var lastPush: Double?

        func advance(rms: Float, at t: Double) {
            let v = smoother.step(rms: rms, at: t)
            guard let last = lastPush else { lastPush = t; return }
            if t - last > 0.5 {
                history = [Double](repeating: 0, count: HUDWaveform.barCount)
                lastPush = t
                return
            }
            var next = last
            while t - next >= 0.05 {
                next += 0.05
                history.removeFirst()
                history.append(v)
            }
            lastPush = next
        }
    }

    var body: some View {
        Group {
            if let fixture {
                Canvas { ctx, size in Self.draw(ctx, size, history: fixture, color: color) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let _ = model.advance(rms: level, at: timeline.date.timeIntervalSinceReferenceDate)
                    Canvas { ctx, size in Self.draw(ctx, size, history: model.history, color: color) }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }

    private static func draw(_ ctx: GraphicsContext, _ size: CGSize, history: [Double], color: Color) {
        let n = history.count
        guard n > 1 else { return }
        let step = (size.width - barWidth) / CGFloat(n - 1)
        for (i, raw) in history.enumerated() {
            let v = CGFloat(min(max(raw, 0), 1))
            let h = minHeight + (size.height - minHeight) * v
            let rect = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: barWidth, height: h)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(0.45 + 0.55 * Double(v))))
        }
    }
}

/// Three round dots that circle and fuse while the words are worked on (the Useful
/// agent-working mark). Overlapping dots join into one blob: blur, then threshold.
/// Still and apart under Reduce Motion.
struct HUDDotsMark: View {
    /// Seconds on any steady clock.
    let time: Double
    let color: Color
    var animated = true
    var size: CGFloat = 16

    var body: some View {
        Canvas { ctx, canvas in
            let scale = canvas.width / 24
            // Filters run last-added first: blur, then threshold.
            ctx.addFilter(.alphaThreshold(min: 0.4, color: color))
            ctx.addFilter(.blur(radius: 1 * scale))
            ctx.drawLayer { layer in
                for dot in dots() {
                    let rect = CGRect(x: canvas.width / 2 + (dot.x - dot.r) * scale,
                                      y: canvas.height / 2 + (dot.y - dot.r) * scale,
                                      width: 2 * dot.r * scale, height: 2 * dot.r * scale)
                    layer.fill(Path(ellipseIn: rect), with: .color(.black))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func dots() -> [(x: CGFloat, y: CGFloat, r: CGFloat)] {
        guard animated else { return [(-6, 0, 2.4), (0, 0, 2.4), (6, 0, 2.4)] }
        let t = time
        let a = t * 2 * .pi / HUDTiming.dotsPeriod
        return (0..<3).map { k in
            let kk = Double(k)
            let phase = a + kk * 2.094
            let radius = 3.4 + 1.6 * sin(t * 2.3 + kk * 1.7)
            let size = 2.3 + 0.9 * (0.5 + 0.5 * sin(t * 4.7 + kk * 2.2))
            return (CGFloat(radius * cos(phase)), CGFloat(radius * sin(phase)), CGFloat(size))
        }
    }
}

/// An in-progress label: the ink at half strength with a full-strength band sweeping
/// left to right. Plain ink under Reduce Motion.
struct HUDShimmerLabel: View {
    let text: String
    let ink: Color
    let time: Double
    var animated = true

    var body: some View {
        Text(text).foregroundStyle(style)
    }

    private var style: AnyShapeStyle {
        guard animated else { return AnyShapeStyle(ink) }
        let phase = time.truncatingRemainder(dividingBy: HUDTiming.shimmerPeriod) / HUDTiming.shimmerPeriod
        // The gradient is three label-widths wide; its band sweeps from just
        // before the label to just past it.
        let start = -0.5 + 2 * phase - 1.5
        let base = ink.opacity(0.5)
        return AnyShapeStyle(LinearGradient(
            stops: [.init(color: base, location: 0), .init(color: base, location: 0.38),
                    .init(color: ink, location: 0.5), .init(color: base, location: 0.62),
                    .init(color: base, location: 1)],
            startPoint: UnitPoint(x: start, y: 0.5), endPoint: UnitPoint(x: start + 3, y: 0.5)))
    }
}

/// A check that draws itself from its short stroke to its long one.
struct HUDCheck: View {
    let progress: Double
    let color: Color
    var size: CGFloat = 14

    var body: some View {
        CheckPath()
            .trim(from: 0, to: progress)
            .stroke(color, style: StrokeStyle(lineWidth: 1.9 * size / 16, lineCap: .round, lineJoin: .round))
            .opacity(progress > 0.001 ? 1 : 0)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private struct CheckPath: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 16
            var path = Path()
            path.move(to: CGPoint(x: 3.6 * s, y: 8.4 * s))
            path.addLine(to: CGPoint(x: 6.7 * s, y: 11.4 * s))
            path.addLine(to: CGPoint(x: 12.6 * s, y: 4.9 * s))
            return path
        }
    }
}

/// The record dot, breathing gently while it records. Solid under Reduce Motion.
struct HUDRecordDot: View {
    let time: Double
    let color: Color
    var animated = true
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(animated ? 0.85 + 0.15 * cos(time * 2 * .pi / 1.1) : 1)
            .accessibilityHidden(true)
    }
}
