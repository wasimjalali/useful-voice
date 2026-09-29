import Foundation

public enum InsightsRange: String, CaseIterable, Sendable {
    case week, month, all
}

public struct InsightsDailyPoint: Equatable, Sendable {
    public let date: Date
    public let words: Int
}

public struct InsightsLanguageShare: Equatable, Sendable {
    /// Lowercased base code ("de" for "de-DE"), "multi", or "unknown".
    public let code: String
    public let words: Int
}

public struct InsightsSummary: Equatable, Sendable {
    public var totalWords = 0
    public var dictations = 0
    /// Seconds spoken, from dictations that recorded a duration.
    public var spokenSeconds = 0.0
    /// Nil until at least one dictation with a duration exists.
    public var wordsPerMinute: Double?
    /// Typing time for the timed words at 40 wpm, minus the time spent speaking. Never negative.
    public var secondsSaved = 0.0
    /// Streaks and best day are lifetime, whatever the range.
    public var currentStreak = 0
    public var bestStreak = 0
    public var bestDay: InsightsDailyPoint?
    /// One point per day, oldest first, ending today.
    public var daily: [InsightsDailyPoint] = []
    /// Words per local hour of day, 24 entries.
    public var hours = [Int](repeating: 0, count: 24)
    /// Most words first.
    public var languages: [InsightsLanguageShare] = []
    /// Whether any dictation was ever recorded, in any range.
    public var hasAnyData = false
}

/// Persisted lifetime usage totals, bucketed by local calendar day.
///
/// DictationHistory keeps only the last 1,000 records and lets the user delete them, so
/// totals computed from it would shrink. This store counts each dictation once as it is
/// recorded and never looks at history again, except to seed itself once when its file
/// does not exist yet. Days are keyed by the local "yyyy-MM-dd" at the moment of recording
/// and stored as text, so a later time zone or daylight saving change never moves a bucket.
/// Used on the main thread; no locking. Never throws, never crashes.
public final class UsageStatsStore {
    struct Day: Codable, Equatable {
        var words = 0
        var dictations = 0
        /// Words and seconds of dictations with a valid duration, for words per minute.
        var timedWords = 0
        var seconds = 0.0
        var languages: [String: Int] = [:]
        var hours = [Int](repeating: 0, count: 24)
    }

    struct File: Codable {
        var version = 1
        var days: [String: Day] = [:]
        /// Newest last. Guards against the same dictation being counted twice.
        var recentIDs: [UUID] = []
    }

    private static let supportedVersion = 1
    private static let recentIDCap = 1_000
    private static let typingWordsPerMinute = 40.0

    private let fileURL: URL
    private let calendar: Calendar
    private var file: File
    private var recentIDSet: Set<UUID>
    private let failures = StoreFailureReporter(label: "UsageStats")
    private let outcome: StoreLoadOutcome
    private var isWritable: Bool

    public init(fileURL: URL, calendar: Calendar = .autoupdatingCurrent,
                diagnostics: Diagnostics = .shared) {
        self.fileURL = fileURL
        self.calendar = calendar
        let loaded = StoreFileReader.load(
            from: fileURL,
            version: { (f: File) in f.version },
            supportedVersion: Self.supportedVersion,
            diagnostics: diagnostics
        ) { data in
            try JSONDecoder().decode(File.self, from: data)
        }
        self.file = loaded.value ?? File()
        self.recentIDSet = Set(self.file.recentIDs)
        self.outcome = loaded.outcome
        self.isWritable = loaded.outcome.allowsWriting
    }

    public var loadOutcome: StoreLoadOutcome { outcome }
    public var lastSaveError: String? { failures.lastSaveError }

    public func onSaveFailure(_ handler: @escaping (String) -> Void) {
        failures.onSaveFailure(handler)
    }

    // MARK: - Recording

    /// Fill the store from existing history, once. Does nothing when the stats file already
    /// existed at launch. Reprocessed items are copies of a dictation already in history.
    public func seedIfFresh(from records: [DictationRecord]) {
        guard outcome == .fresh, !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        for r in records where !r.provider.hasSuffix("reprocess") {
            add(r)
        }
        persist()
    }

    /// Count one finished dictation. Returns false when it was ignored (no words, or already counted).
    @discardableResult
    public func record(_ record: DictationRecord) -> Bool {
        guard add(record) else { return false }
        persist()
        return true
    }

    @discardableResult
    private func add(_ record: DictationRecord) -> Bool {
        guard !recentIDSet.contains(record.id) else { return false }
        let n = UsageWordCounter.count(record.text)
        guard n > 0 else { return false }

        let key = Self.dayKey(record.createdAt, calendar: calendar)
        var day = file.days[key] ?? Day()
        day.words = Self.sum(day.words, n)
        day.dictations = Self.sum(day.dictations, 1)
        if let d = record.durationSeconds, d.isFinite, d > 0 {
            day.timedWords = Self.sum(day.timedWords, n)
            day.seconds += d
        }
        let code = Self.languageCode(record.language)
        day.languages[code] = Self.sum(day.languages[code] ?? 0, n)
        let hour = min(max(calendar.component(.hour, from: record.createdAt), 0), 23)
        day.hours[hour] = Self.sum(day.hours[hour], n)
        file.days[key] = day

        file.recentIDs.append(record.id)
        recentIDSet.insert(record.id)
        if file.recentIDs.count > Self.recentIDCap {
            let dropped = file.recentIDs.prefix(file.recentIDs.count - Self.recentIDCap)
            recentIDSet.subtract(dropped)
            file.recentIDs.removeFirst(dropped.count)
        }
        return true
    }

    // MARK: - Reading

    public func insights(range: InsightsRange, now: Date = Date()) -> InsightsSummary {
        var out = InsightsSummary()
        out.hasAnyData = !file.days.isEmpty

        let today = calendar.startOfDay(for: now)
        let chartDays: Int
        var startKey: String?
        switch range {
        case .week: chartDays = 7
        case .month: chartDays = 30
        case .all: chartDays = 90
        }
        if range != .all {
            let start = calendar.date(byAdding: .day, value: -(chartDays - 1), to: today) ?? today
            startKey = Self.dayKey(start, calendar: calendar)
        }

        var timedWords = 0
        var langs: [String: Int] = [:]
        for (key, day) in file.days {
            if let startKey, key < startKey { continue }
            if key > Self.dayKey(today, calendar: calendar) { continue }
            out.totalWords = Self.sum(out.totalWords, day.words)
            out.dictations = Self.sum(out.dictations, day.dictations)
            out.spokenSeconds += day.seconds
            timedWords = Self.sum(timedWords, day.timedWords)
            for (i, h) in day.hours.enumerated() where i < 24 { out.hours[i] = Self.sum(out.hours[i], h) }
            for (code, w) in day.languages { langs[code] = Self.sum(langs[code] ?? 0, w) }
        }
        if out.spokenSeconds > 0 {
            out.wordsPerMinute = Double(timedWords) / out.spokenSeconds * 60
            out.secondsSaved = max(0, Double(timedWords) / Self.typingWordsPerMinute * 60 - out.spokenSeconds)
        }
        out.languages = langs
            .map { InsightsLanguageShare(code: $0.key, words: $0.value) }
            .sorted { $0.words != $1.words ? $0.words > $1.words : $0.code < $1.code }

        // Daily series: step by calendar days so daylight saving never skips or repeats one.
        for offset in stride(from: chartDays - 1, through: 0, by: -1) {
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let words = file.days[Self.dayKey(date, calendar: calendar)]?.words ?? 0
            out.daily.append(InsightsDailyPoint(date: date, words: words))
        }

        // Lifetime streaks and best day.
        let activeKeys = Set(file.days.filter { $0.value.words > 0 }.keys)
        var cursor = today
        if !activeKeys.contains(Self.dayKey(cursor, calendar: calendar)) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while activeKeys.contains(Self.dayKey(cursor, calendar: calendar)) {
            out.currentStreak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        var run = 0
        var previousDate: Date?
        for key in activeKeys.sorted() {
            guard let date = Self.date(fromKey: key, calendar: calendar) else { continue }
            if let previousDate, calendar.date(byAdding: .day, value: 1, to: previousDate) == date {
                run += 1
            } else {
                run = 1
            }
            out.bestStreak = max(out.bestStreak, run)
            previousDate = date
        }
        if let best = file.days.max(by: { $0.value.words != $1.value.words ? $0.value.words < $1.value.words : $0.key > $1.key }),
           best.value.words > 0, let date = Self.date(fromKey: best.key, calendar: calendar) {
            out.bestDay = InsightsDailyPoint(date: date, words: best.value.words)
        }
        return out
    }

    // MARK: - Helpers

    private static func sum(_ a: Int, _ b: Int) -> Int {
        let (v, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : v
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func languageCode(_ language: String?) -> String {
        guard let raw = language?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return "unknown"
        }
        if raw == "multi" || raw == "auto" { return raw == "multi" ? "multi" : "unknown" }
        return String(raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "unknown")
    }

    @discardableResult
    private func persist() -> Bool {
        guard isWritable else {
            failures.reportSaveFailure(
                "not saving: \(loadOutcome.userFacingMessage ?? "the existing file could not be read")")
            return false
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
            FileProtection.restrict(fileURL, isDirectory: false)
            failures.reportSaveSuccess()
            return true
        } catch {
            failures.reportSaveFailure(error)
            return false
        }
    }
}
