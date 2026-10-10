import Foundation
import UsefulVoiceCore

// MARK: - Formatting

/// German-region number and date formats for the Insights page: 77.974, 1,2 min, $3,09,
/// "11. Sep", "Sun 4". Written out rather than taken from the system locale so the page
/// reads the same on every Mac.
enum InsightsFormat {
    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(".") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }

    static func decimal(_ x: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", x).replacingOccurrences(of: ".", with: ",")
    }

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded())) %" }

    /// "22h 39m", "32m", "40 s".
    static func hoursMinutes(_ seconds: Double) -> String {
        guard seconds >= 60 else { return "\(Int(seconds.rounded())) s" }
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// "35 s", "1,2 min".
    static func shortDuration(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds.rounded())) s" : "\(decimal(seconds / 60, digits: 1)) min"
    }

    static func hour(_ h: Int) -> String { String(format: "%02d:00", h) }

    /// Keeps a date from breaking across lines inside a sentence.
    static func unbroken(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "11. Sep"
    static func dayMonth(_ date: Date, _ cal: Calendar) -> String {
        "\(cal.component(.day, from: date)). \(months[cal.component(.month, from: date) - 1])"
    }

    /// "10. Oct 2026"
    static func fullDate(_ date: Date, _ cal: Calendar) -> String {
        "\(dayMonth(date, cal)) \(cal.component(.year, from: date))"
    }

    /// "Sun 4"
    static func weekdayDay(_ date: Date, _ cal: Calendar) -> String {
        "\(weekdays[cal.component(.weekday, from: date) - 1]) \(cal.component(.day, from: date))"
    }

    /// "Sun 4. Oct"
    static func weekdayDate(_ date: Date, _ cal: Calendar) -> String {
        "\(weekdays[cal.component(.weekday, from: date) - 1]) \(dayMonth(date, cal))"
    }

    /// "4. to 10. Oct 2026", "11. Sep to 10. Oct 2026", "30. Dec 2026 to 5. Jan 2027".
    static func dateRange(_ a: Date, _ b: Date, _ cal: Calendar) -> String {
        let ca = cal.dateComponents([.year, .month], from: a)
        let cb = cal.dateComponents([.year, .month], from: b)
        if ca == cb {
            return "\(cal.component(.day, from: a)). to \(fullDate(b, cal))"
        }
        if ca.year == cb.year {
            return "\(dayMonth(a, cal)) to \(fullDate(b, cal))"
        }
        return "\(fullDate(a, cal)) to \(fullDate(b, cal))"
    }

    /// A rounded-up axis maximum with a clean half, leaving a little headroom for labels.
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 100 }
        let target = value * 1.08
        let exponent = pow(10, floor(log10(target)))
        for mantissa in [1.0, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10] where mantissa * exponent >= target {
            return mantissa * exponent
        }
        return 10 * exponent
    }
}

// MARK: - Model

struct InsightsHeroChart: Equatable {
    /// "Words per day", "Words per week" or "Your first week".
    var title: String
    var values: [Int]
    /// The long label for each value, used by the hover readout ("Sun 4. Oct").
    var valueLabels: [String]
    /// Empty slots after the last value: the days still to come in a first week.
    var futureSlots = 0
    var xLabels: [Label]
    var yMax: Double
    var average: Int?
    var bestIndex: Int
    var bestTitle: String
    var todayTitle: String
    var todaySubtitle: String
    var showDots: Bool

    struct Label: Equatable {
        let index: Int
        let text: String
    }

    var slots: Int { values.count + futureSlots }
}

struct InsightsLanguage: Equatable {
    let name: String
    let words: Int
    let share: Double
}

struct InsightsCost: Equatable {
    var total: Double
    var deepgramMinutes: Int
    var deepgramCost: Double
    /// Nil when the vocabulary is empty: keyterm prompting is only billed with terms.
    var keytermCost: Double?
    var whisperMinutes: Int
    var note: String
}

struct InsightsQuietFact: Equatable {
    let value: String
    let label: String
}

/// Everything the Insights page draws for one range, computed from the stores. A plain
/// value so the page body only lays it out, and so a snapshot fixture can stand in for it.
struct InsightsData {
    var range: InsightsRange
    var hasAnyData: Bool
    var rangeLabel: String
    /// The sentence under the headline: "words in the last 30 days."
    var periodPhrase: String
    var totalWords: Int
    var dictations: Int
    var spokenSeconds: Double
    var savedSeconds: Double
    var typingSeconds: Double
    var wordsPerMinute: Int?
    var averagePerDay: Int
    var chart: InsightsHeroChart?
    var goal: Int
    var todayWords: Int
    var streak: Int
    var bestStreak: Int
    var hours: [Int]
    var peakHour: Int?
    var peakWindow: String?
    var wpmSeries: [Double]
    var wpmNote: String?
    var languages: [InsightsLanguage]
    var cost: InsightsCost?
    var topWords: [(word: String, count: Int)]
    var quiet: [InsightsQuietFact]
}

/// What the page reads: the stores, plus the daily goal and "now".
struct InsightsInputs {
    var stats: UsageStatsStore
    var records: [DictationRecord]
    var terms: [MemoryTerm]
    var replacements: [ReplacementRule]
    var goal: Int
    var now: Date
}

extension InsightsData {
    static let deepgramPerMinute = 0.0043
    static let keytermPerMinute = 0.0013
    static let typingWordsPerMinute = 40.0
    /// An all-time chart switches from days to weeks once it spans more than this.
    static let weeklyAfterDays = 60

    static func calendar() -> Calendar {
        var cal = UsageStatsStore.defaultCalendar
        cal.firstWeekday = 2
        return cal
    }

    // swiftlint:disable:next function_body_length
    static func build(range: InsightsRange, inputs: InsightsInputs) -> InsightsData {
        let cal = calendar()
        let today = cal.startOfDay(for: inputs.now)
        let summary = inputs.stats.insights(range: range, now: inputs.now)
        let allDays = inputs.stats.dayStats().filter { $0.date <= today }
        let firstDay = allDays.first?.date
        let daysSinceFirst = firstDay.map { (cal.dateComponents([.day], from: $0, to: today).day ?? 0) + 1 }

        // The first week gets its own 7-slot frame instead of a sliver on a long axis.
        let firstWeek = range != .week && (daysSinceFirst.map { $0 < 7 } ?? false)

        let periodDays: Int?
        switch range {
        case .week: periodDays = 7
        case .month: periodDays = 30
        case .all: periodDays = nil
        }
        let startDate: Date? = {
            if firstWeek { return firstDay }
            guard let periodDays else { return firstDay }
            return cal.date(byAdding: .day, value: -(periodDays - 1), to: today)
        }()
        let days = allDays.filter { startDate == nil || $0.date >= startDate! }

        let words = days.reduce(0) { $0 + $1.words }
        let dictations = days.reduce(0) { $0 + $1.dictations }
        let timedWords = days.reduce(0) { $0 + $1.timedWords }
        let seconds = days.reduce(0.0) { $0 + $1.seconds }
        let typing = Double(timedWords) / typingWordsPerMinute * 60
        let saved = max(0, typing - seconds)
        let wpm = seconds > 0 ? Int((Double(timedWords) / seconds * 60).rounded()) : nil

        let dayCount: Int = {
            let sinceFirst = daysSinceFirst ?? 1
            if let periodDays, !firstWeek { return min(periodDays, sinceFirst) }
            return max(1, sinceFirst)
        }()

        var data = InsightsData(
            range: range,
            hasAnyData: !allDays.isEmpty,
            rangeLabel: "No dictations yet",
            periodPhrase: "",
            totalWords: words,
            dictations: dictations,
            spokenSeconds: seconds,
            savedSeconds: saved,
            typingSeconds: typing,
            wordsPerMinute: wpm,
            averagePerDay: Int((Double(words) / Double(dayCount)).rounded()),
            chart: nil,
            goal: inputs.goal,
            todayWords: allDays.last(where: { $0.date == today })?.words ?? 0,
            streak: summary.currentStreak,
            bestStreak: summary.bestStreak,
            hours: summary.hours,
            peakHour: nil,
            peakWindow: nil,
            wpmSeries: [],
            wpmNote: nil,
            languages: [],
            cost: nil,
            topWords: [],
            quiet: [])
        guard data.hasAnyData, let firstDay else { return data }

        // Header range and the sentence.
        switch range {
        case .week:
            data.rangeLabel = InsightsFormat.dateRange(startDate ?? today, today, cal)
            data.periodPhrase = "words in the last 7 days."
        case .month:
            if firstWeek {
                data.rangeLabel = InsightsFormat.dateRange(firstDay, today, cal)
                data.periodPhrase = "words since you started on \(InsightsFormat.unbroken(InsightsFormat.dayMonth(firstDay, cal)))."
            } else {
                data.rangeLabel = InsightsFormat.dateRange(startDate ?? today, today, cal)
                data.periodPhrase = "words in the last 30 days."
            }
        case .all:
            if firstWeek {
                data.rangeLabel = InsightsFormat.dateRange(firstDay, today, cal)
                data.periodPhrase = "words since you started on \(InsightsFormat.unbroken(InsightsFormat.dayMonth(firstDay, cal)))."
            } else {
                data.rangeLabel = "Since \(InsightsFormat.fullDate(firstDay, cal))"
                data.periodPhrase = "words since \(InsightsFormat.unbroken(InsightsFormat.fullDate(firstDay, cal)))."
            }
        }

        // Time of day.
        if data.hours.reduce(0, +) > 0, let peak = data.hours.enumerated().max(by: { $0.element < $1.element }) {
            data.peakHour = peak.offset
            if data.hours.filter({ $0 > 0 }).count >= 2 {
                var bestStart = 0
                var bestSum = -1
                for start in 0...21 {
                    let sum = data.hours[start..<(start + 3)].reduce(0, +)
                    if sum > bestSum { bestSum = sum; bestStart = start }
                }
                data.peakWindow = "Most words from \(InsightsFormat.hour(bestStart)) to \(InsightsFormat.hour((bestStart + 3) % 24))"
            }
        }

        // Languages.
        let langTotal = summary.languages.reduce(0) { $0 + $1.words }
        data.languages = summary.languages.map {
            InsightsLanguage(name: languageName($0.code), words: $0.words,
                             share: langTotal > 0 ? Double($0.words) / Double(langTotal) : 0)
        }

        // Hero chart and the speed trend.
        let weekly = range == .all && !firstWeek && (daysSinceFirst ?? 0) > weeklyAfterDays
        data.chart = heroChart(range: range, firstWeek: firstWeek, weekly: weekly, days: days, today: today,
                               firstDay: firstDay, daysSinceFirst: daysSinceFirst ?? 1,
                               average: data.averagePerDay, cal: cal)
        let trend = speedTrend(days: days, weekly: weekly, cal: cal)
        data.wpmSeries = trend.values
        if firstWeek {
            data.wpmNote = trend.values.count > 1
                ? "Your first \(trend.values.count) days" : nil
        } else if let first = trend.values.first, let last = trend.values.last, trend.values.count > 1,
                  let date = trend.firstDate {
            let a = Int(first.rounded()), b = Int(last.rounded())
            let where_ = InsightsFormat.dayMonth(date, cal)
            data.wpmNote = b > a ? "Up from \(a) on \(where_)" : (b < a ? "Down from \(a) on \(where_)" : "Steady at \(a)")
        }

        // Cost, from the dictations still in history.
        data.cost = cost(records: inputs.records, hasTerms: !inputs.terms.isEmpty, since: startDate,
                         range: range, firstWeek: firstWeek, firstDay: firstDay, cal: cal)

        // Top words, from the vocabulary's own usage counts.
        data.topWords = inputs.terms
            .filter { $0.usageCount > 0 }
            .sorted { $0.usageCount != $1.usageCount ? $0.usageCount > $1.usageCount : $0.phrase < $1.phrase }
            .prefix(5)
            .map { ($0.phrase, $0.usageCount) }

        // Quiet facts. Only those with a real number behind them.
        var quiet: [InsightsQuietFact] = []
        let fixes = inputs.replacements.reduce(0) { $0 + $1.usageCount }
        if fixes > 0 { quiet.append(.init(value: InsightsFormat.grouped(fixes), label: "fixes applied, all time")) }
        let timed = inputs.records.filter {
            !$0.provider.hasSuffix("reprocess") && ($0.durationSeconds ?? 0) > 0
                && (startDate == nil || $0.createdAt >= startDate!)
        }
        if let longest = timed.max(by: { ($0.durationSeconds ?? 0) < ($1.durationSeconds ?? 0) }),
           let d = longest.durationSeconds {
            quiet.append(.init(
                value: InsightsFormat.shortDuration(d),
                label: "longest dictation, \(InsightsFormat.grouped(UsageWordCounter.count(longest.text))) words"))
        }
        if !timed.isEmpty {
            let mean = timed.reduce(0.0) { $0 + ($1.durationSeconds ?? 0) } / Double(timed.count)
            quiet.append(.init(value: InsightsFormat.shortDuration(mean), label: "average dictation"))
        }
        let lifetime = allDays.reduce(0) { $0 + $1.words }
        quiet.append(.init(value: InsightsFormat.grouped(lifetime),
                           label: "words since \(InsightsFormat.fullDate(firstDay, cal))"))
        data.quiet = quiet
        return data
    }

    // MARK: Hero chart

    private static func heroChart(range: InsightsRange, firstWeek: Bool, weekly: Bool, days: [InsightsDayStat],
                                  today: Date, firstDay: Date, daysSinceFirst: Int, average: Int,
                                  cal: Calendar) -> InsightsHeroChart {
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0.words) })

        func daily(from start: Date, count: Int) -> (values: [Int], dates: [Date]) {
            var values: [Int] = []
            var dates: [Date] = []
            for i in 0..<count {
                let d = cal.date(byAdding: .day, value: i, to: start) ?? start
                dates.append(d)
                values.append(byDay[d] ?? 0)
            }
            return (values, dates)
        }

        func extremes(_ values: [Int]) -> Int {
            // The first of equal maxima, so a tie stays on the earlier day.
            values.indices.max(by: { values[$0] != values[$1] ? values[$0] < values[$1] : $0 > $1 }) ?? 0
        }

        if firstWeek {
            let (values, dates) = daily(from: firstDay, count: daysSinceFirst)
            let best = extremes(values)
            var labels = values.indices.map { i in
                InsightsHeroChart.Label(index: i, text: i == values.count - 1 ? "Today" : InsightsFormat.weekdayDay(dates[i], cal))
            }
            let lastSlot = 6
            if lastSlot > values.count - 1 {
                let end = cal.date(byAdding: .day, value: lastSlot, to: firstDay) ?? firstDay
                labels.append(.init(index: lastSlot, text: InsightsFormat.weekdayDay(end, cal)))
            }
            return InsightsHeroChart(
                title: "Your first week", values: values,
                valueLabels: dates.map { InsightsFormat.weekdayDate($0, cal) },
                futureSlots: 7 - values.count, xLabels: labels,
                yMax: InsightsFormat.niceCeiling(Double(values.max() ?? 0)), average: nil,
                bestIndex: best, bestTitle: "Best day, \(InsightsFormat.weekdayDate(dates[best], cal))",
                todayTitle: "Today", todaySubtitle: InsightsFormat.grouped(values.last ?? 0), showDots: true)
        }

        switch range {
        case .week:
            let start = cal.date(byAdding: .day, value: -6, to: today) ?? today
            let (values, dates) = daily(from: start, count: 7)
            let best = extremes(values)
            let labels = values.indices.map {
                InsightsHeroChart.Label(index: $0, text: $0 == 6 ? "Today" : InsightsFormat.weekdayDay(dates[$0], cal))
            }
            return InsightsHeroChart(
                title: "Words per day", values: values,
                valueLabels: dates.map { InsightsFormat.weekdayDate($0, cal) }, xLabels: labels,
                yMax: InsightsFormat.niceCeiling(Double(values.max() ?? 0)), average: average,
                bestIndex: best, bestTitle: "Best day, \(InsightsFormat.weekdayDate(dates[best], cal))",
                todayTitle: "Today", todaySubtitle: InsightsFormat.grouped(values[6]), showDots: true)

        case .month:
            let start = cal.date(byAdding: .day, value: -29, to: today) ?? today
            let (values, dates) = daily(from: start, count: 30)
            return dailyChart(values: values, dates: dates, average: average, cal: cal)

        case .all:
            if !weekly {
                let count = max(2, daysSinceFirst)
                let start = cal.date(byAdding: .day, value: -(count - 1), to: today) ?? today
                let (values, dates) = daily(from: start, count: count)
                return dailyChart(values: values, dates: dates, average: average, cal: cal)
            }
            // Weeks from the first week's Monday to this one.
            let firstWeekStart = cal.dateInterval(of: .weekOfYear, for: firstDay)?.start ?? firstDay
            let thisWeekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            var starts: [Date] = []
            var cursor = firstWeekStart
            while cursor <= thisWeekStart {
                starts.append(cursor)
                cursor = cal.date(byAdding: .day, value: 7, to: cursor) ?? thisWeekStart.addingTimeInterval(1)
            }
            var values = [Int](repeating: 0, count: starts.count)
            for day in days {
                let ws = cal.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date
                if let i = starts.firstIndex(of: ws) { values[i] += day.words }
            }
            let best = extremes(values)
            // A label at the first week that starts in each month.
            var labels: [InsightsHeroChart.Label] = []
            var previousMonth = -1
            for (i, s) in starts.enumerated() {
                let m = cal.component(.month, from: s)
                if m != previousMonth {
                    let year = cal.component(.year, from: s)
                    let text = m == 1 ? "Jan \(year)" : InsightsFormat.months[m - 1]
                    labels.append(.init(index: i, text: text))
                    previousMonth = m
                }
            }
            labels = thinned(labels, to: 7)
            return InsightsHeroChart(
                title: "Words per week", values: values,
                valueLabels: starts.map { "Week of \(InsightsFormat.dayMonth($0, cal))" }, xLabels: labels,
                yMax: InsightsFormat.niceCeiling(Double(values.max() ?? 0)), average: nil,
                bestIndex: best, bestTitle: "Best week, \(InsightsFormat.dayMonth(starts[best], cal))",
                todayTitle: "This week", todaySubtitle: "\(InsightsFormat.grouped(values.last ?? 0)) so far",
                showDots: false)
        }
    }

    private static func dailyChart(values: [Int], dates: [Date], average: Int, cal: Calendar) -> InsightsHeroChart {
        let best = values.indices.max(by: { values[$0] != values[$1] ? values[$0] < values[$1] : $0 > $1 }) ?? 0
        let last = values.count - 1
        var labels: [InsightsHeroChart.Label] = []
        let steps = min(4, last)
        for k in 0...steps {
            let i = steps == 0 ? 0 : Int((Double(k) / Double(steps) * Double(last)).rounded())
            labels.append(.init(index: i, text: i == last ? "Today" : InsightsFormat.dayMonth(dates[i], cal)))
        }
        return InsightsHeroChart(
            title: "Words per day", values: values,
            valueLabels: dates.map { InsightsFormat.weekdayDate($0, cal) }, xLabels: labels,
            yMax: InsightsFormat.niceCeiling(Double(values.max() ?? 0)), average: average,
            bestIndex: best, bestTitle: "Best day, \(InsightsFormat.dayMonth(dates[best], cal))",
            todayTitle: "Today", todaySubtitle: InsightsFormat.grouped(values[last]), showDots: false)
    }

    private static func thinned(_ labels: [InsightsHeroChart.Label], to maxCount: Int) -> [InsightsHeroChart.Label] {
        guard labels.count > maxCount else { return labels }
        let stride = Int((Double(labels.count) / Double(maxCount)).rounded(.up))
        return labels.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
    }

    // MARK: Speaking speed

    /// Words per minute per day (per week for a weekly chart). Days with under 30 seconds of
    /// timed speech are skipped: a three second dictation says nothing about speed.
    private static func speedTrend(days: [InsightsDayStat], weekly: Bool, cal: Calendar) -> (values: [Double], firstDate: Date?) {
        struct Bucket { var date: Date; var words = 0; var seconds = 0.0 }
        var buckets: [Bucket] = []
        for day in days where day.seconds > 0 {
            let key = weekly ? (cal.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date) : day.date
            if let i = buckets.firstIndex(where: { $0.date == key }) {
                buckets[i].words += day.timedWords
                buckets[i].seconds += day.seconds
            } else {
                buckets.append(Bucket(date: key, words: day.timedWords, seconds: day.seconds))
            }
        }
        let usable = buckets.filter { $0.seconds >= 30 }
        return (usable.map { Double($0.words) / $0.seconds * 60 }, usable.first?.date)
    }

    // MARK: Cost

    private static func cost(records: [DictationRecord], hasTerms: Bool, since: Date?, range: InsightsRange,
                             firstWeek: Bool, firstDay: Date, cal: Calendar) -> InsightsCost? {
        let inRange = records.filter { !$0.provider.hasSuffix("reprocess") && (since == nil || $0.createdAt >= since!) }
        var deepgram = 0.0
        var whisper = 0.0
        for r in inRange {
            guard let d = r.durationSeconds, d > 0 else { continue }
            if r.provider.hasPrefix("Deepgram") { deepgram += d / 60 }
            else if r.provider.hasPrefix("Whisper") { whisper += d / 60 }
        }
        guard deepgram > 0 || whisper > 0 else { return nil }

        // History keeps the newest 1.000 dictations. When it no longer reaches back to the
        // start of the range, say what the estimate covers instead of the range.
        let historyCap = 1_000
        let oldest = records.map(\.createdAt).min()
        let partial = records.count >= historyCap && oldest.map { since == nil || $0 > since! } == true
        let note: String
        if partial {
            note = "in your latest \(InsightsFormat.grouped(records.count)) dictations"
        } else if firstWeek {
            note = "since \(InsightsFormat.dayMonth(firstDay, cal))"
        } else {
            switch range {
            case .week: note = "in the last 7 days"
            case .month: note = "in the last 30 days"
            case .all: note = "since \(InsightsFormat.fullDate(firstDay, cal))"
            }
        }
        let nova = deepgram * deepgramPerMinute
        let key = hasTerms ? deepgram * keytermPerMinute : nil
        return InsightsCost(total: nova + (key ?? 0), deepgramMinutes: Int(deepgram.rounded()), deepgramCost: nova,
                            keytermCost: key, whisperMinutes: Int(whisper.rounded()), note: note)
    }

    static func languageName(_ code: String) -> String {
        switch code {
        case "multi": return "Multilingual"
        case "unknown": return "Unknown"
        default:
            // The language's own name, as in the board: Deutsch, not German.
            let own = Locale(identifier: code).localizedString(forLanguageCode: code)
            return (own ?? code).localizedCapitalized
        }
    }
}

/// Remembers the last built `InsightsData`, so a redraw that changes nothing the page reads
/// (a dictation state change, a hover) does not walk 1.000 records again.
final class InsightsCache {
    private struct Key: Equatable {
        let range: InsightsRange
        let revision: Int
        let goal: Int
        let day: Date
    }

    private var key: Key?
    private var data: InsightsData?

    func data(range: InsightsRange, revision: Int, goal: Int, now: Date = Date(),
              build: () -> InsightsData) -> InsightsData {
        let next = Key(range: range, revision: revision, goal: goal,
                       day: InsightsData.calendar().startOfDay(for: now))
        if let data, key == next { return data }
        let built = build()
        key = next
        data = built
        return built
    }
}
