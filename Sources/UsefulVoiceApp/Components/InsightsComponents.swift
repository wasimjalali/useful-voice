import SwiftUI
import UsefulVoiceCore

// MARK: - Page chrome

/// The page title bar the stage pages share: a 15 pt title, an optional quiet line beside
/// it, an accessory on the right and, for scrolling forms, a hairline under it.
struct StagePageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var hairline = false
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.uv(.title, .semibold))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.uv(.ui))
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.leading, 28)
        .padding(.trailing, 24)
        .frame(height: 60)
        .overlay(alignment: .bottom) {
            if hairline { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

extension StagePageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, hairline: Bool = false) {
        self.init(title: title, subtitle: subtitle, hairline: hairline) { EmptyView() }
    }
}

// MARK: - Tiles

/// A lifted tile with a 13 pt title and a quiet note on the right. One level of lift, no
/// cards inside cards.
struct InsightsTile<Content: View>: View {
    let title: String
    var meta: String?
    var radius: CGFloat = Radius.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.uv(.ui, .semibold))
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let meta {
                    Text(meta)
                        .font(.uv(.meta))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
            }
            content()
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .insightsLift(radius: radius)
    }
}

extension View {
    /// The board's lift at a given radius: bubble surface, faint edge, lift shadow.
    func insightsLift(radius: CGFloat) -> some View {
        self
            .background(Theme.bubble, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.edge, lineWidth: 1))
            .themeShadow(.lift)
    }
}

/// A large figure (30 pt) over a 13 pt label, or beside it.
struct InsightsFigure: View {
    let value: String
    let label: String
    var muted = false
    var inline = false

    var body: some View {
        if inline {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                figure
                Text(label).font(.uv(.ui)).foregroundStyle(Theme.inkMuted)
            }
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                figure
                Text(label).font(.uv(.ui)).foregroundStyle(Theme.inkMuted)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var figure: some View {
        Text(value)
            .font(.system(size: muted ? 20 : 30, weight: .semibold))
            .tracking(muted ? -0.2 : -0.75)
            .monospacedDigit()
            .foregroundStyle(muted ? Theme.inkMuted : Theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(minHeight: muted ? 36 : nil, alignment: .leading)
    }
}

/// Children sit on a 12 column grid by `span`, equal height, 14 pt apart.
private struct SpanKey: LayoutValueKey {
    static let defaultValue = 12
}

extension View {
    func insightsSpan(_ columns: Int) -> some View {
        layoutValue(key: SpanKey.self, value: columns)
    }
}

struct InsightsSpanRow: Layout {
    var spacing: CGFloat = 14

    private func widths(_ total: CGFloat, _ subviews: Subviews) -> [CGFloat] {
        let spans = subviews.map { $0[SpanKey.self] }
        let sum = spans.reduce(0, +)
        if sum == 12 {
            let col = (total - 11 * spacing) / 12
            return spans.map { CGFloat($0) * col + CGFloat($0 - 1) * spacing }
        }
        let usable = total - spacing * CGFloat(max(spans.count - 1, 0))
        return spans.map { usable * CGFloat($0) / CGFloat(max(sum, 1)) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 800
        let w = widths(total, subviews)
        let height = zip(subviews, w).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(bounds.width, subviews)
        var x = bounds.minX
        for (subview, width) in zip(subviews, w) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

// MARK: - Small marks

/// A 10 pt square legend swatch.
struct InsightsSwatch: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: 10, height: 10)
    }
}

/// A horizontal bar on a track with the value as a fraction. Bar geometry, so 3 pt corners.
struct InsightsMeter: View {
    let fraction: Double
    var color: Color = InsightsInk.k1
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(InsightsInk.track)
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(color)
                    .frame(width: max(height, proxy.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: height)
    }
}
