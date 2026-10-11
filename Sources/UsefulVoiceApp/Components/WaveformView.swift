import SwiftUI

/// The recording pill's scrolling waveform: 30 bars, 2 pt wide, in a 104 by 28 pt
/// box. Every 50 ms the smoothed, dB-mapped mic level is pushed into the history
/// (newest on the right) and the row scrolls left. Bar height is 3 pt at silence up
/// to 28 pt; opacity ramps from 0.35 (oldest) to 1 (newest). The history starts at
/// zero for each recording. It is data, so Reduce Motion does not change it.
struct WaveformView: View {
    /// Raw mic RMS.
    let level: Float
    var fill: Color = Theme.hudMark
    /// Snapshot only: a ready-made history (mapped values, oldest first).
    var fixture: [Double]? = nil

    static let barCount = 30
    static let size = CGSize(width: 104, height: 28)
    private static let barWidth: CGFloat = 2
    private static let minHeight: CGFloat = 3

    @State private var model = Model()

    final class Model {
        var history = [Double](repeating: 0, count: WaveformView.barCount)
        let smoother = MicLevel.Smoother()
        var lastPush: Double?

        func advance(rms: Float, at t: Double) {
            let v = smoother.step(rms: rms, at: t)
            guard let last = lastPush else { lastPush = t; return }
            var pushes = 0
            var next = last
            while t - next >= 0.05, pushes < WaveformView.barCount {
                next += 0.05
                history.removeFirst()
                history.append(v)
                pushes += 1
            }
            lastPush = pushes == WaveformView.barCount ? t : next
        }
    }

    var body: some View {
        Group {
            if let fixture {
                Canvas { ctx, sz in Self.draw(ctx, sz, history: fixture, fill: fill) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let _ = model.advance(rms: level, at: timeline.date.timeIntervalSinceReferenceDate)
                    Canvas { ctx, sz in Self.draw(ctx, sz, history: model.history, fill: fill) }
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityHidden(true)
    }

    private static func draw(_ ctx: GraphicsContext, _ size: CGSize, history: [Double], fill: Color) {
        let n = history.count
        guard n > 1 else { return }
        let step = (size.width - barWidth) / CGFloat(n - 1)
        for (i, raw) in history.enumerated() {
            let v = CGFloat(min(max(raw, 0), 1))
            let h = minHeight + (size.height - minHeight) * v
            let rect = CGRect(x: CGFloat(i) * step, y: (size.height - h) / 2, width: barWidth, height: h)
            let opacity = 0.35 + 0.65 * Double(i) / Double(n - 1)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(fill.opacity(opacity)))
        }
    }
}
