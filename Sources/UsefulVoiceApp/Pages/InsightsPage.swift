import SwiftUI
import UsefulVoiceCore

/// Lifetime usage from the persisted usage stats, redrawn when a dictation finishes.
struct InsightsPage: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    @State private var range: InsightsRange = .month

    var body: some View {
        // Reading the revision ties this body to new dictations.
        let _ = viewModel.usageRevision
        let summary = viewModel.usageStats.insights(range: range)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CommandPageHeader(title: "Insights") {
                    BrandedSegmentedControl(selection: $range, options: [
                        (label: "7 days", value: InsightsRange.week),
                        (label: "30 days", value: InsightsRange.month),
                        (label: "All time", value: InsightsRange.all),
                    ])
                    .frame(width: 270)
                }

                if summary.hasAnyData {
                    content(summary)
                } else {
                    CommandPanel {
                        CommandEmptyState(
                            icon: "chart.bar",
                            title: "No dictations yet",
                            detail: "Your words, streak and time saved show up here after your first dictation.")
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .pageColumn(maxWidth: 1100)
        }
        .background(Theme.surface)
    }

    // MARK: - Sections

    @ViewBuilder
    private func content(_ s: InsightsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
            InsightsStatTile(value: Self.number(s.totalWords), label: "Words dictated")
            InsightsStatTile(value: Self.number(s.dictations), label: "Dictations")
            InsightsStatTile(value: Self.duration(s.spokenSeconds), label: "Time dictating")
            InsightsStatTile(value: s.wordsPerMinute.map { Self.number(Int($0.rounded())) } ?? "-",
                             label: "Words per minute")
            InsightsStatTile(value: Self.duration(s.secondsSaved), label: "Saved versus typing")
            InsightsStatTile(value: Self.days(s.currentStreak),
                             label: "Streak, best \(Self.number(s.bestStreak))")
        }

        CommandPanel("Words per day") {
            dailyChart(s)
        }

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)],
                  alignment: .leading, spacing: 14) {
            CommandPanel("Time of day") {
                hourChart(s)
            }
            CommandPanel("Languages") {
                languages(s)
            }
        }
    }

    private func dailyChart(_ s: InsightsSummary) -> some View {
        let bars = s.daily.enumerated().map { i, p in
            InsightsBarChart.Bar(
                id: i, value: p.words,
                help: "\(p.date.formatted(date: .abbreviated, time: .omitted)): \(Self.number(p.words)) words")
        }
        return VStack(alignment: .leading, spacing: 12) {
            InsightsBarChart(
                bars: bars,
                height: 170,
                leadingLabel: s.daily.first?.date.formatted(date: .abbreviated, time: .omitted),
                trailingLabel: s.daily.last?.date.formatted(date: .abbreviated, time: .omitted))
        }
    }

    private func hourChart(_ s: InsightsSummary) -> some View {
        let bars = s.hours.enumerated().map { hour, words in
            InsightsBarChart.Bar(id: hour, value: words,
                                 help: "\(Self.hourLabel(hour)): \(Self.number(words)) words")
        }
        let peak = s.hours.enumerated().max { $0.element < $1.element }
        return VStack(alignment: .leading, spacing: 12) {
            InsightsBarChart(
                bars: bars, height: 120,
                leadingLabel: Self.hourLabel(0), trailingLabel: Self.hourLabel(23),
                highlightedID: peak.flatMap { $0.element > 0 ? $0.offset : nil })
        }
    }

    @ViewBuilder
    private func languages(_ s: InsightsSummary) -> some View {
        if s.totalWords == 0 {
            Text("No words in this range.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(s.languages.prefix(5), id: \.code) { lang in
                    let share = Double(lang.words) / Double(s.totalWords)
                    InsightsShareRow(name: Self.languageName(lang.code), share: share,
                                     percentText: share.formatted(.percent.precision(.fractionLength(0))))
                }
            }
        }
    }

    // MARK: - Formatting

    private static func number(_ n: Int) -> String {
        n.formatted(.number)
    }

    private static func days(_ n: Int) -> String {
        n == 1 ? "1 day" : "\(number(n)) days"
    }

    private static func duration(_ seconds: Double) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute] : [.second])
        return f.string(from: seconds.rounded()) ?? "0"
    }

    private static func hourLabel(_ hour: Int) -> String {
        var c = DateComponents()
        c.hour = hour
        guard let date = Calendar.current.date(from: c) else { return "\(hour)" }
        return date.formatted(.dateTime.hour())
    }

    private static func languageName(_ code: String) -> String {
        switch code {
        case "multi": return "Multilingual"
        case "unknown": return "Unknown"
        default: return Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
        }
    }
}
