import SwiftUI
import UsefulVoiceCore

/// A big number over a small label.
struct InsightsStatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.5)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Minimal bar chart drawn with plain shapes. Handles one bar, all zeros and any width.
struct InsightsBarChart: View {
    struct Bar: Identifiable {
        let id: Int
        let value: Int
        let help: String
    }

    let bars: [Bar]
    var height: CGFloat = 150
    /// Labels under the first bar, and optionally under the last.
    var leadingLabel: String?
    var trailingLabel: String?
    var highlightedID: Int?

    var body: some View {
        let peak = max(bars.map(\.value).max() ?? 0, 1)
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: bars.count > 40 ? 2 : 4) {
                ForEach(bars) { bar in
                    let ratio = CGFloat(bar.value) / CGFloat(peak)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(bar.value == 0 ? Theme.line
                              : (highlightedID == nil || highlightedID == bar.id ? Theme.brand : Theme.inkFaint))
                        .frame(maxWidth: .infinity)
                        .frame(height: bar.value == 0 ? 3 : max(4, ratio * height))
                        .help(bar.help)
                }
            }
            .frame(height: height, alignment: .bottom)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.lineStrong).frame(height: 1)
            }
            if leadingLabel != nil || trailingLabel != nil {
                HStack {
                    Text(leadingLabel ?? "")
                    Spacer(minLength: 8)
                    Text(trailingLabel ?? "")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.inkFaint)
                .lineLimit(1)
            }
        }
    }
}

/// One language row with its share of words.
struct InsightsShareRow: View {
    let name: String
    let share: Double
    let percentText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(percentText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
                    .monospacedDigit()
            }
            Capsule()
                .fill(Theme.sunken)
                .frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(Theme.brand)
                            .frame(width: max(6, proxy.size.width * CGFloat(min(max(share, 0), 1))))
                    }
                }
        }
    }
}
