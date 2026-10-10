import SwiftUI
import UsefulVoiceCore

/// Insights: one hero (your words, and words per day or week), then goal and streak, time of
/// day and speaking speed, time saved and languages, cost and top words, and a quiet strip of
/// small facts. Redrawn when a dictation finishes (`usageRevision`).
struct InsightsPage: View {
    @ObservedObject var viewModel: UsefulVoiceViewModel
    let settings: AppSettings
    @State private var range: InsightsRange = InsightsFixture.startRange ?? .month
    @State private var cache = InsightsCache()

    var body: some View {
        // Reading the revision ties this body to new dictations.
        let _ = viewModel.usageRevision
        let data = cache.data(range: range, revision: viewModel.usageRevision, goal: settings.dailyWordGoal) {
            InsightsData.build(range: range, inputs: inputs)
        }

        VStack(spacing: 0) {
            StagePageHeader(title: "Insights", subtitle: data.rangeLabel) {
                BrandedSegmentedControl(selection: $range, options: [
                    (label: "7 days", value: InsightsRange.week),
                    (label: "30 days", value: InsightsRange.month),
                    (label: "All time", value: InsightsRange.all),
                ])
                .frame(width: 252)
            }
            ScrollView {
                VStack(spacing: 14) {
                    hero(data)
                    goalSpeedRow(data)
                    if data.hasAnyData {
                        savedAndLanguages(data)
                        costAndWords(data)
                        quietStrip(data)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 2)
                .padding(.bottom, 24)
                .pageColumn(maxWidth: 1180)
            }
        }
        .background(Theme.surface)
    }

    private var inputs: InsightsInputs {
        if let fixture = InsightsFixture.current { return fixture }
        return InsightsInputs(
            stats: viewModel.usageStats,
            records: viewModel.historyStore.all(),
            terms: viewModel.languageMemory.terms,
            replacements: viewModel.languageMemory.replacements,
            goal: settings.dailyWordGoal,
            now: Date())
    }

    // MARK: - Hero

    private func hero(_ d: InsightsData) -> some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 0) {
                if d.hasAnyData {
                    heroSentences(d)
                    Spacer(minLength: 12)
                    heroStats(d)
                } else {
                    heroInvite
                }
            }
            .frame(width: 330, alignment: .topLeading)

            ZStack(alignment: .topTrailing) {
                InsightsHeroChartView(chart: d.chart ?? Self.emptyChart(range))
                Text(d.chart?.title ?? "Words per day")
                    .font(.uv(.label))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.trailing, 14)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .bottomTrailing)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(EdgeInsets(top: 26, leading: 30, bottom: 22, trailing: 26))
        .frame(height: 306)
        .insightsLift(radius: Radius.xl)
    }

    private func heroSentences(_ d: InsightsData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You dictated \(InsightsFormat.grouped(d.totalWords)) \(d.periodPhrase)")
                .foregroundStyle(Theme.ink)
            if d.savedSeconds >= 60 {
                (Text("That's ").foregroundStyle(Theme.inkMuted)
                 + Text(InsightsFormat.hoursMinutes(d.savedSeconds)).foregroundStyle(Theme.ink)
                 + Text(" you didn't type.").foregroundStyle(Theme.inkMuted))
            }
        }
        .font(.system(size: 30, weight: .semibold))
        .tracking(-0.9)
        .monospacedDigit()
        .lineSpacing(1)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func heroStats(_ d: InsightsData) -> some View {
        var stats: [(String, String)] = [(InsightsFormat.grouped(d.dictations), "dictations")]
        if d.spokenSeconds > 0 { stats.append((InsightsFormat.hoursMinutes(d.spokenSeconds), "speaking")) }
        stats.append((InsightsFormat.grouped(d.averagePerDay), "a day on average"))
        return HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { i, stat in
                VStack(alignment: .leading, spacing: 1) {
                    Text(stat.0)
                        .font(.uv(.figure, .semibold))
                        .tracking(-0.3)
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                    Text(stat.1)
                        .font(.uv(.meta))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.horizontal, 16)
                .padding(.leading, i == 0 ? -16 : 0)
                .overlay(alignment: .leading) {
                    if i > 0 { Rectangle().fill(Theme.line).frame(width: 1) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The new user's hero: it names the hotkey and offers the first dictation.
    private var heroInvite: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your words add up here.")
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.9)
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Tap")
                    BrandKbd(HotkeyOption.label(for: viewModel.hotkeyKeycode))
                    Text(", speak, then tap it again.")
                }
                Text("Every dictation adds to your words, the time you save and your busiest hours.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.uv(.body))
            .foregroundStyle(Theme.inkMuted)
            .lineSpacing(4)
            .padding(.top, 14)
            Spacer(minLength: 12)
            Button("Try a dictation") {
                viewModel.navigate(to: "stream")
                viewModel.toggle()
            }
            .buttonStyle(.brandPrimary)
            .controlSize(.large)
            // A dictation already running would be stopped by the toggle.
            .disabled(!dictationIdle)
            .clickableCursor()
        }
    }

    private var dictationIdle: Bool {
        if case .idle = viewModel.dictationState { return true }
        return false
    }

    /// Ghost axes for a new user, so the page keeps its shape.
    private static func emptyChart(_ range: InsightsRange) -> InsightsHeroChart {
        let cal = InsightsData.calendar()
        let today = cal.startOfDay(for: Date())
        let span = range == .week ? 7 : 30
        let start = cal.date(byAdding: .day, value: -(span - 1), to: today) ?? today
        var labels = [InsightsHeroChart.Label(index: 0, text: range == .week ? InsightsFormat.weekdayDay(start, cal)
                                                                              : InsightsFormat.dayMonth(start, cal))]
        if range != .week {
            let mid = cal.date(byAdding: .day, value: 14, to: start) ?? start
            labels.append(.init(index: 14, text: InsightsFormat.dayMonth(mid, cal)))
        }
        labels.append(.init(index: span - 1, text: "Today"))
        return InsightsHeroChart(title: "Words per day", values: [], valueLabels: [], futureSlots: span,
                                 xLabels: labels, yMax: 5000, average: nil, bestIndex: 0, bestTitle: "",
                                 todayTitle: "", todaySubtitle: "", showDots: false)
    }

    // MARK: - Goal, time of day, speaking speed

    private func goalSpeedRow(_ d: InsightsData) -> some View {
        InsightsSpanRow {
            goalTile(d).insightsSpan(5)
            timeOfDayTile(d).insightsSpan(4)
            speedTile(d).insightsSpan(3)
        }
        .frame(height: 250)
    }

    private func goalTile(_ d: InsightsData) -> some View {
        let goalFraction = d.goal > 0 ? Double(d.todayWords) / Double(d.goal) : 0
        let streakFraction = d.bestStreak > 0 ? Double(d.streak) / Double(d.bestStreak) : 0
        let toGo = d.goal - d.todayWords
        let meta = d.hasAnyData
            ? (toGo <= 0 ? "Goal reached" : "\(InsightsFormat.percent(goalFraction)) of today's goal") : nil
        return InsightsTile(title: "Goal and streak", meta: meta) {
            HStack(spacing: 26) {
                InsightsRings(goal: goalFraction, streak: streakFraction)
                VStack(alignment: .leading, spacing: 18) {
                    legendFigure(color: InsightsInk.k1, label: "Daily goal",
                                 value: InsightsFormat.grouped(d.todayWords),
                                 unit: " / \(InsightsFormat.grouped(d.goal)) words") {
                        if !d.hasAnyData {
                            Button {
                                viewModel.navigate(to: "settings", anchor: "general")
                            } label: {
                                Text("Change goal")
                                    .font(.uv(.meta, .medium))
                                    .foregroundStyle(Theme.ink)
                                    .underline(true, color: Theme.lineStrong)
                            }
                            .buttonStyle(.plain)
                            .clickableCursor()
                        } else {
                            Text(toGo > 0 ? "\(InsightsFormat.grouped(toGo)) to go today" : "Goal reached")
                                .font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                        }
                    }
                    legendFigure(color: InsightsInk.k2, label: "Streak",
                                 value: InsightsFormat.grouped(d.streak),
                                 unit: d.streak == 1 ? " day" : " days") {
                        Text(streakNote(d)).font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func streakNote(_ d: InsightsData) -> String {
        if d.bestStreak == 0 { return "Starts with your first dictation" }
        if d.streak >= d.bestStreak { return "Your best yet" }
        return "Best \(InsightsFormat.grouped(d.bestStreak)) days"
    }

    private func legendFigure<Note: View>(color: Color, label: String, value: String, unit: String,
                                          @ViewBuilder note: () -> Note) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                InsightsSwatch(color: color)
                Text(label).font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
            }
            (Text(value).font(.system(size: 26, weight: .semibold)).tracking(-0.65)
             + Text(unit).font(.uv(.ui)).foregroundStyle(Theme.inkMuted))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            note()
        }
    }

    private func timeOfDayTile(_ d: InsightsData) -> some View {
        InsightsTile(title: "Time of day") {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if let peak = d.peakHour {
                        InsightsFigure(value: InsightsFormat.hour(peak), label: "Busiest hour")
                        if let window = d.peakWindow {
                            Text(window).font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                                .padding(.top, 8)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        InsightsFigure(value: "None yet", label: "Busiest hour", muted: true)
                        Text("Shows after a few dictations").font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                            .padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 120, maxHeight: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
                InsightsRadial(hours: d.hours, empty: d.peakHour == nil)
                    .padding(.trailing, -6)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func speedTile(_ d: InsightsData) -> some View {
        InsightsTile(title: "Speaking speed") {
            VStack(alignment: .leading, spacing: 0) {
                if let wpm = d.wordsPerMinute {
                    InsightsFigure(value: InsightsFormat.grouped(wpm), label: "Words per minute")
                    if d.wpmSeries.count > 1 {
                        InsightsSpeedTrend(values: d.wpmSeries).padding(.top, 14)
                    }
                    Spacer(minLength: 8)
                    if let note = d.wpmNote {
                        Text(note).font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                    }
                } else {
                    InsightsFigure(value: "None yet", label: "Words per minute", muted: true)
                    Spacer(minLength: 8)
                    Text("Typing runs at about 40. Most people speak three times faster.")
                        .font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Time saved, languages

    private func savedAndLanguages(_ d: InsightsData) -> some View {
        let showSaved = d.spokenSeconds > 0 && d.wordsPerMinute != nil
        let showLanguages = !d.languages.isEmpty
        return InsightsSpanRow {
            if showSaved { timeSavedTile(d).insightsSpan(showLanguages ? 7 : 12) }
            if showLanguages { languagesTile(d).insightsSpan(showSaved ? 5 : 12) }
        }
    }

    private func timeSavedTile(_ d: InsightsData) -> some View {
        let typing = max(d.typingSeconds, d.spokenSeconds)
        let fraction = typing > 0 ? d.spokenSeconds / typing : 0
        return InsightsTile(title: "Time saved", meta: "Same words, two ways") {
            VStack(alignment: .leading, spacing: 14) {
                InsightsFigure(value: InsightsFormat.hoursMinutes(d.savedSeconds),
                               label: "you didn't spend typing", inline: true)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 14) {
                    barLabel("Typing at \(Int(InsightsData.typingWordsPerMinute)) wpm",
                             InsightsFormat.hoursMinutes(typing))
                    RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                        .fill(InsightsInk.k3).frame(height: 26)
                    barLabel("Dictating at \(d.wordsPerMinute ?? 0) wpm",
                             InsightsFormat.hoursMinutes(d.spokenSeconds))
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                                .strokeBorder(InsightsInk.k3, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                                .fill(InsightsInk.k1)
                                .frame(width: max(12, proxy.size.width * CGFloat(fraction)))
                            if d.savedSeconds >= 60 {
                                Text("\(InsightsFormat.hoursMinutes(d.savedSeconds)) saved")
                                    .font(.uv(.meta, .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.inkMuted)
                                    .padding(.trailing, 12)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                    .frame(height: 26)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func barLabel(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left).font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
            Spacer(minLength: 8)
            Text(right).font(.uv(.ui, .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
        }
    }

    private func languagesTile(_ d: InsightsData) -> some View {
        // The top three, then everything else together.
        var shown = Array(d.languages.prefix(3))
        if d.languages.count > 3 {
            let rest = d.languages.dropFirst(3)
            shown.append(InsightsLanguage(name: "Other", words: rest.reduce(0) { $0 + $1.words },
                                          share: rest.reduce(0) { $0 + $1.share }))
        }
        let count = d.languages.count
        return InsightsTile(title: "Languages") {
            VStack(alignment: .leading, spacing: 14) {
                InsightsFigure(value: InsightsFormat.grouped(d.languages.reduce(0) { $0 + $1.words }),
                               label: "words in \(count) \(count == 1 ? "language" : "languages")", inline: true)
                Spacer(minLength: 0)
                languageBar(shown)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, lang in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 7) {
                                InsightsSwatch(color: InsightsInk.step(i))
                                Text(lang.name).font(.uv(.meta)).foregroundStyle(Theme.inkMuted).lineLimit(1)
                            }
                            Text(InsightsFormat.percent(lang.share))
                                .font(.uv(.figure, .semibold)).tracking(-0.3).monospacedDigit()
                                .foregroundStyle(Theme.ink)
                            Text("\(InsightsFormat.grouped(lang.words)) words")
                                .font(.uv(.meta)).monospacedDigit().foregroundStyle(Theme.inkMuted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// One segment per language, 3 pt apart, the outer ends rounded.
    private func languageBar(_ shown: [InsightsLanguage]) -> some View {
        GeometryReader { proxy in
            let gaps = CGFloat(max(shown.count - 1, 0)) * 3
            let usable = proxy.size.width - gaps
            HStack(spacing: 3) {
                ForEach(Array(shown.enumerated()), id: \.offset) { i, lang in
                    UnevenRoundedRectangle(
                        topLeadingRadius: i == 0 ? Radius.sm : 3,
                        bottomLeadingRadius: i == 0 ? Radius.sm : 3,
                        bottomTrailingRadius: i == shown.count - 1 ? Radius.sm : 3,
                        topTrailingRadius: i == shown.count - 1 ? Radius.sm : 3,
                        style: .continuous)
                        .fill(InsightsInk.step(i))
                        .frame(width: max(6, usable * CGFloat(lang.share)))
                }
            }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }

    // MARK: - Cost, top words

    private func costAndWords(_ d: InsightsData) -> some View {
        let showCost = d.cost != nil
        let showWords = !d.topWords.isEmpty
        return InsightsSpanRow {
            if let cost = d.cost, showCost { costTile(cost).insightsSpan(showWords ? 5 : 12) }
            if showWords { topWordsTile(d).insightsSpan(showCost ? 7 : 12) }
        }
    }

    private func costTile(_ c: InsightsCost) -> some View {
        InsightsTile(title: "Engine cost", meta: "Estimate") {
            VStack(alignment: .leading, spacing: 14) {
                InsightsFigure(value: "$\(InsightsFormat.decimal(c.total, digits: 2))", label: c.note, inline: true)
                minutesBar(c)
                VStack(spacing: 0) {
                    costRow(swatch: InsightsInk.k1, name: "Deepgram Nova-3", minutes: c.deepgramMinutes,
                            amount: "$\(InsightsFormat.decimal(c.deepgramCost, digits: 2))", first: true)
                    if let key = c.keytermCost {
                        costRow(swatch: .clear, name: "Keyterm prompting", minutes: c.deepgramMinutes,
                                amount: "$\(InsightsFormat.decimal(key, digits: 2))")
                    }
                    costRow(swatch: InsightsInk.k3, name: "Whisper (local)", minutes: c.whisperMinutes,
                            amount: c.whisperMinutes > 0 ? "No cost" : "Not used", quiet: true)
                }
                Text("List prices. Your Deepgram invoice is the source of truth.")
                    .font(.uv(.label)).foregroundStyle(Theme.inkMuted)
            }
        }
    }

    private func minutesBar(_ c: InsightsCost) -> some View {
        GeometryReader { proxy in
            let total = Double(max(c.deepgramMinutes + c.whisperMinutes, 1))
            let gap: CGFloat = c.whisperMinutes > 0 && c.deepgramMinutes > 0 ? 3 : 0
            let usable = proxy.size.width - gap
            HStack(spacing: gap) {
                if c.deepgramMinutes > 0 {
                    Capsule().fill(InsightsInk.k1)
                        .frame(width: max(6, usable * CGFloat(Double(c.deepgramMinutes) / total)))
                }
                if c.whisperMinutes > 0 {
                    Capsule().fill(InsightsInk.k3)
                        .frame(width: max(6, usable * CGFloat(Double(c.whisperMinutes) / total)))
                }
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private func costRow(swatch: Color, name: String, minutes: Int, amount: String,
                         first: Bool = false, quiet: Bool = false) -> some View {
        HStack(spacing: 10) {
            InsightsSwatch(color: swatch)
            Text(name).font(.uv(.ui)).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(InsightsFormat.grouped(minutes)) min")
                .font(.uv(.meta)).monospacedDigit().foregroundStyle(Theme.inkMuted)
            Text(amount)
                .font(.uv(quiet ? .meta : .ui, quiet ? .medium : .semibold)).monospacedDigit()
                .foregroundStyle(quiet ? Theme.inkMuted : Theme.ink)
                .frame(width: 64, alignment: .trailing)
        }
        .frame(height: 30)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .accessibilityElement(children: .combine)
    }

    private func topWordsTile(_ d: InsightsData) -> some View {
        let top = d.topWords[0]
        let peak = Double(max(top.count, 1))
        return InsightsTile(title: "Top words", meta: "All time, from your vocabulary") {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(top.word)
                        .font(.system(size: 30, weight: .semibold)).tracking(-0.75)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text("said \(InsightsFormat.grouped(top.count)) times")
                        .font(.uv(.meta)).foregroundStyle(Theme.inkMuted)
                }
                .frame(width: 150, alignment: .leading)
                VStack(spacing: 14) {
                    ForEach(Array(d.topWords.enumerated()), id: \.offset) { i, item in
                        HStack(spacing: 12) {
                            Text(item.word).font(.uv(.ui)).foregroundStyle(Theme.ink).lineLimit(1)
                                .frame(width: 64, alignment: .leading)
                            InsightsMeter(fraction: Double(item.count) / peak,
                                          color: i == 0 ? InsightsInk.k1 : InsightsInk.k2)
                            Text(InsightsFormat.grouped(item.count))
                                .font(.uv(.ui, .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                                .frame(width: 36, alignment: .trailing)
                        }
                        .frame(height: 22)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Quiet strip

    private func quietStrip(_ d: InsightsData) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(d.quiet.enumerated()), id: \.offset) { i, fact in
                VStack(alignment: .leading, spacing: 1) {
                    Text(fact.value).font(.uv(.title, .semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text(fact.label).font(.uv(.meta)).foregroundStyle(Theme.inkMuted).lineLimit(1)
                }
                .padding(.leading, i == 0 ? 0 : 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    if i > 0 { Rectangle().fill(Theme.line).frame(width: 1) }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 12)
    }
}
