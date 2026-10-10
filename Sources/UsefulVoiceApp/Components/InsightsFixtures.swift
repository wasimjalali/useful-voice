import Foundation
import UsefulVoiceCore

/// Snapshot-only stand-ins for the Insights data, so every state of the page can be rendered
/// offscreen without touching the owner's real stores. Active only when `UV_SNAPSHOT` is set:
///
///     UV_INSIGHTS_FIXTURE=empty|firstWeek|full   which data to draw
///     UV_INSIGHTS_RANGE=7d|30d|all               which range the page opens on
///
/// The fixtures run through the same store and builder as real data (a temporary
/// `UsageStatsStore` filled with synthetic dictations), so what they show is what the page
/// would compute. The numbers are illustrative; they are not anyone's usage.
enum InsightsFixture {
    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    private static var snapshotOnly: Bool { env["UV_SNAPSHOT"] != nil }

    static var startRange: InsightsRange? {
        guard snapshotOnly else { return nil }
        switch env["UV_INSIGHTS_RANGE"] {
        case "7d": return .week
        case "30d": return .month
        case "all": return .all
        default: return nil
        }
    }

    static let current: InsightsInputs? = {
        guard snapshotOnly, let kind = env["UV_INSIGHTS_FIXTURE"] else { return nil }
        switch kind {
        case "empty": return make(days: [], terms: [], fixes: 0)
        case "firstWeek": return make(days: firstWeekDays, terms: Array(terms.prefix(3)).map { var t = $0; t.usageCount = max(1, t.usageCount / 8); return t }, fixes: 2)
        case "full": return make(days: fullDays, terms: terms, fixes: 51)
        default:
            fputs("UV_INSIGHTS_FIXTURE must be empty, firstWeek or full\n", stderr)
            exit(2)
        }
    }()

    // MARK: Data

    /// Words per day, oldest first, ending today.
    private static let last30 = [
        1643, 1314, 2267, 1164, 2047, 1723, 1137, 1993, 1098, 1852, 1159, 2180, 7339, 0, 0,
        3337, 4731, 2295, 2639, 4040, 5149, 3865, 3240, 5248, 2027, 4840, 2869, 2365, 2273, 2140,
    ]
    /// Words per week for the weeks before those 30 days, oldest first.
    private static let earlierWeeks = [9800, 16400, 19800, 22600, 25300, 27900, 31400, 29200, 26800, 30500, 28700, 24100, 19600]
    private static let hourWeights = [2, 1, 0, 0, 0, 1, 4, 9, 18, 30, 38, 34, 24, 32, 44, 56, 78, 62, 40, 28, 20, 14, 8, 4]

    private static let terms: [MemoryTerm] = [("Eval", 32), ("Devin", 23), ("Gemini", 20), ("SWE 2", 15), ("Tabari", 15)]
        .map { MemoryTerm(phrase: $0.0, usageCount: $0.1) }

    private static var firstWeekDays: [(offset: Int, words: Int)] { [(-2, 1212), (-1, 2031), (0, 846)] }

    private static var fullDays: [(offset: Int, words: Int)] {
        var days = last30.enumerated().map { (offset: $0.offset - 29, words: $0.element) }
        for (w, total) in earlierWeeks.enumerated() {
            // Seven days per earlier week, the last of them the day before the 30 day window.
            for d in 0..<7 {
                let offset = -30 - (earlierWeeks.count - 1 - w) * 7 - d
                days.append((offset: offset, words: total / 7 + (d % 3) * 40))
            }
        }
        return days.sorted { $0.offset < $1.offset }
    }

    // MARK: Builder

    private struct Generator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }
    }

    private static func make(days: [(offset: Int, words: Int)], terms: [MemoryTerm], fixes: Int) -> InsightsInputs {
        let cal = InsightsData.calendar()
        let now = Date()
        let today = cal.startOfDay(for: now)
        var rng = Generator()
        let total = hourWeights.reduce(0, +)
        let languages: [(code: String, weight: Int)] = [("en", 59), ("de", 27), ("fa", 14)]
        let spanDays = Double(max(1, days.count))

        var records: [DictationRecord] = []
        for (n, entry) in days.enumerated() {
            guard entry.words > 0, let day = cal.date(byAdding: .day, value: entry.offset, to: today) else { continue }
            // Speed drifts upward over the window, so the trend has something to show.
            let wpm = 118 + 14 * Double(n) / spanDays
            var left = entry.words
            while left > 0 {
                let words = min(left, 40 + rng.next(120))
                left -= words
                var pick = rng.next(total), hour = 0
                while pick >= hourWeights[hour] { pick -= hourWeights[hour]; hour += 1 }
                var langPick = rng.next(100), code = "en"
                for l in languages { if langPick < l.weight { code = l.code; break }; langPick -= l.weight }
                let created = cal.date(byAdding: .minute, value: hour * 60 + rng.next(60), to: day) ?? day
                records.append(DictationRecord(
                    text: Array(repeating: "word", count: words).joined(separator: " "),
                    createdAt: created, language: code,
                    provider: rng.next(100) < 7 ? "Whisper (local)" : "Deepgram",
                    durationSeconds: Double(words) / wpm * 60))
            }
        }
        records.sort { $0.createdAt > $1.createdAt }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("uv-insights-fixture-\(UUID().uuidString).json")
        let stats = UsageStatsStore(fileURL: file, diagnostics: Diagnostics(directory: nil))
        stats.seedIfFresh(from: records)
        try? FileManager.default.removeItem(at: file)

        let rule = ReplacementRule(match: "devon", replacement: "Devin", usageCount: fixes)
        return InsightsInputs(stats: stats, records: Array(records.prefix(1_000)), terms: terms,
                              replacements: fixes > 0 ? [rule] : [], goal: 2500, now: now)
    }
}

/// Settings options for offscreen renders, read only when `UV_SNAPSHOT` is set:
///
///     UV_SETTINGS_ANCHOR=<group id>   open scrolled to a group
///     UV_SETTINGS_STATE=noKey|invalidKey|confirmDelete   draw a state that needs no network or data
enum SettingsSnapshot {
    private static var env: [String: String]? {
        let env = ProcessInfo.processInfo.environment
        return env["UV_SNAPSHOT"] != nil ? env : nil
    }

    static var anchor: String? { env?["UV_SETTINGS_ANCHOR"] }
    static var state: String? { env?["UV_SETTINGS_STATE"] }
}
