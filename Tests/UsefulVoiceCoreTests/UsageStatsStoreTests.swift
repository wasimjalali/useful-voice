import Testing
import Foundation
@testable import UsefulVoiceCore

// HOW THE USAGE STATS STORE COULD FAIL (written before the code)
//
//  1. Midnight boundary: a dictation at 23:59:59 and one at 00:00:00 must land on two
//     different days, and both must count once. A day key built from a UTC date or from
//     a 24 h offset would merge or shift them.
//  2. Daylight saving: on the spring-forward day the local clock skips 02:00-02:59. Records
//     at 01:30 and 03:30 belong to the same day, the day must not be dropped or counted
//     twice, and walking back "N days" for the chart must not skip or repeat a date
//     (24 h * N subtraction would).
//  3. Time zone change: the user travels. Buckets recorded earlier keep the day they were
//     recorded on; loading the file under another zone must not re-bucket or double count.
//  4. Empty text or whitespace only: no dictation, no word, must not bump the dictation
//     count or the streak.
//  5. Punctuation only ("...", "?!", emoji only): zero words, ignored like empty text.
//  6. CJK text with no spaces: must not count as one word per sentence, nor one per
//     character, nor as zero.
//  7. Apostrophes, hyphens, decimals and thousands separators: "don't", "well-known",
//     "3.5", "1,000" are one word each, not two.
//  8. Huge counts: additions must saturate instead of trapping on overflow.
//  9. Duplicate append: recording the same record id twice (a retry, a double callback,
//     seeding then a live call) must count once.
// 10. Missing or invalid duration (nil, zero, negative, NaN): the words still count, but
//     they must stay out of words-per-minute and time-spoken.
// 11. Corrupted file: must be moved aside, load outcome must say so, and the next record
//     must NOT overwrite the original with an empty store. Never crash.
// 12. Seeding twice: a second launch, or a restored history, must not add the old records
//     again once the stats file exists.
// 13. Deleted history: clearing or deleting Library items must not reduce lifetime totals.
// 14. Reprocessed history items (provider ends in "reprocess") are copies of an existing
//     dictation and must not be seeded as new dictations.
// 15. Streak: alive when the last dictation was today or yesterday, dead after that; the
//     best streak must survive a gap and cross a DST change.
// 16. Range windows: 7 and 30 day windows include today and exclude older days exactly.
// 17. Round trip: everything above must survive save and reload from disk unchanged.

@Suite final class UsageStatsStoreTests {
    private let dir: URL
    private let fileURL: URL
    private let diagnostics = Diagnostics(directory: nil)
    private let ny: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("usage-stats.json")
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    // MARK: fixture

    /// Day 0 is Monday 2026-02-23 in New York. US daylight saving began Sunday 2026-03-08 (day 13).
    private struct Fx {
        var day: Int
        var hour: Int
        var minute = 0
        var second = 0
        var text: String
        var lang: String?
        var duration: Double?
    }

    private func date(_ fx: Fx) -> Date {
        let base = ny.date(from: DateComponents(year: 2026, month: 2, day: 23))!
        let day = ny.date(byAdding: .day, value: fx.day, to: base)!
        return ny.date(bySettingHour: fx.hour, minute: fx.minute, second: fx.second, of: day)!
    }

    private func record(_ fx: Fx, id: UUID = UUID(), provider: String = "deepgram") -> DictationRecord {
        DictationRecord(id: id, text: fx.text, createdAt: date(fx), language: fx.lang,
                        provider: provider, durationSeconds: fx.duration)
    }

    private func words(_ n: Int) -> String {
        // Mixed punctuation on purpose, still exactly n words.
        (0..<n).map { i in ["alpha", "beta,", "gamma.", "delta!", "epsilon"][i % 5] }
            .joined(separator: " ")
    }

    private func isActive(_ d: Int) -> Bool { d % 7 != 5 && !(20...22).contains(d) }

    /// The whole timeline, oldest first. Days 0...39, Saturdays and days 20-22 skipped.
    private func fixture() -> [Fx] {
        var out: [Fx] = []
        for d in 0...39 where isActive(d) {
            out.append(Fx(day: d, hour: 9, minute: 15, text: words(10 + d), lang: "en",
                          duration: Double(10 + d) * 0.4))
            out.append(Fx(day: d, hour: 19, text: words(20), lang: "de-DE",
                          duration: d % 3 == 0 ? nil : 10))
        }
        // Midnight boundary between day 10 and day 11.
        out.append(Fx(day: 10, hour: 23, minute: 59, second: 59, text: words(5), lang: "en", duration: 2))
        out.append(Fx(day: 11, hour: 0, text: words(5), lang: "en", duration: 2))
        // Spring-forward day: 01:30 and 03:30 exist, 02:30 does not.
        out.append(Fx(day: 13, hour: 1, minute: 30, text: words(3), lang: "multi", duration: nil))
        out.append(Fx(day: 13, hour: 3, minute: 30, text: words(3), lang: nil, duration: nil))
        // Chinese without spaces: 13 characters, counted as ceil(13 / 2) = 7 words.
        out.append(Fx(day: 2, hour: 15, text: "今天天气很好我们去公园散步", lang: "zh", duration: 3))
        // Never counted.
        out.append(Fx(day: 4, hour: 12, text: "", lang: "en", duration: 1))
        out.append(Fx(day: 4, hour: 12, minute: 1, text: "  \n ", lang: "en", duration: 1))
        out.append(Fx(day: 4, hour: 12, minute: 2, text: "... ?! --", lang: "en", duration: 1))
        return out.sorted { date($0) < date($1) }
    }

    private struct Expected {
        var words = 0, dictations = 0, timedWords = 0
        var timedSeconds = 0.0
    }

    /// Independent arithmetic from the fixture rules, not from the store.
    private func expected(_ items: [Fx], fromDay: Int = 0) -> Expected {
        var e = Expected()
        for fx in items where fx.day >= fromDay {
            let n: Int
            switch fx.text {
            case "", "  \n ", "... ?! --": n = 0
            case "今天天气很好我们去公园散步": n = 7
            default: n = fx.text.split(separator: " ").count
            }
            guard n > 0 else { continue }
            e.words += n
            e.dictations += 1
            if let d = fx.duration, d > 0 { e.timedWords += n; e.timedSeconds += d }
        }
        return e
    }

    private func store(_ cal: Calendar? = nil) -> UsageStatsStore {
        UsageStatsStore(fileURL: fileURL, calendar: cal ?? ny, diagnostics: diagnostics)
    }

    private func nowAt(day: Int) -> Date { date(Fx(day: day, hour: 20, text: "", lang: nil, duration: nil)) }

    // MARK: the scenario

    @Test func seedThenLiveUpdatesThenReloadThenHistoryDeletion() throws {
        let all = fixture()
        let cutoff = 36
        let seedFx = all.filter { $0.day <= cutoff }
        let liveFx = all.filter { $0.day > cutoff }

        // History as it exists for a current user, including a reprocess copy of an
        // early item (must not be seeded) and a duplicate id.
        let history = DictationHistory(fileURL: dir.appendingPathComponent("history.json"),
                                       diagnostics: diagnostics)
        var seedRecords: [DictationRecord] = []
        for fx in seedFx { seedRecords.append(record(fx)) }
        let copy = record(seedFx[0], provider: "deepgram reprocess")
        for r in seedRecords + [copy] { history.append(r) }

        // 1. Seed once from history.
        let s = store()
        #expect(s.loadOutcome == .fresh)
        s.seedIfFresh(from: history.all())
        let afterSeed = s.insights(range: .all, now: nowAt(day: cutoff))
        let seedExpected = expected(seedFx)
        #expect(afterSeed.totalWords == seedExpected.words)
        #expect(afterSeed.dictations == seedExpected.dictations)

        // 2. Seeding again (same launch, then a restored, larger history) changes nothing.
        s.seedIfFresh(from: history.all() + history.all())
        #expect(s.insights(range: .all, now: nowAt(day: cutoff)).totalWords == seedExpected.words)

        // 3. Live updates, one duplicate call, empty and punctuation-only dictations.
        var liveRecords: [DictationRecord] = []
        for fx in liveFx { liveRecords.append(record(fx)) }
        for r in liveRecords { #expect(s.record(r)) }
        #expect(s.record(liveRecords[0]) == false)
        #expect(s.record(record(Fx(day: 39, hour: 21, text: "", lang: "en", duration: 1))) == false)
        #expect(s.record(record(Fx(day: 39, hour: 21, text: "?!", lang: "en", duration: 1))) == false)

        let now = nowAt(day: 39)
        let total = expected(all)
        let sum = s.insights(range: .all, now: now)
        #expect(sum.totalWords == total.words)
        #expect(sum.dictations == total.dictations)
        let wpm = try #require(sum.wordsPerMinute)
        #expect(abs(wpm - Double(total.timedWords) / total.timedSeconds * 60) < 0.0001)
        #expect(abs(sum.spokenSeconds - total.timedSeconds) < 0.0001)
        // Saved = typing time for the timed words at 40 wpm minus the time spent speaking.
        #expect(abs(sum.secondsSaved - (Double(total.timedWords) / 40 * 60 - total.timedSeconds)) < 0.0001)

        // Streaks: active runs are days 0-4, 6-11, 13-18, 23-25, 27-32 and 34-39. The current
        // run is 6 days ending on day 39 and the best is 6 (the DST day sits inside 13-18).
        #expect(sum.currentStreak == 6)
        #expect(sum.bestStreak == 6)
        let best = try #require(sum.bestDay)
        #expect(best.words == (10 + 39) + 20)
        #expect(ny.dateComponents([.year, .month, .day], from: best.date)
                == DateComponents(year: 2026, month: 4, day: 3))

        // Midnight boundary and DST day: each day holds exactly its own words.
        let month = s.insights(range: .month, now: now)
        #expect(month.daily.count == 30)
        func wordsOn(_ day: Int) -> Int {
            expected(all.filter { $0.day == day }).words
        }
        for point in month.daily {
            let d = ny.dateComponents([.day], from: ny.startOfDay(for: nowAt(day: 0)), to: point.date).day!
            #expect(point.words == wordsOn(d), "day \(d)")
        }
        // Consecutive daily points are exactly one calendar day apart, even across DST.
        for pair in zip(month.daily, month.daily.dropFirst()) {
            #expect(ny.date(byAdding: .day, value: 1, to: pair.0.date) == pair.1.date)
        }

        // Range windows.
        let week = s.insights(range: .week, now: now)
        #expect(week.daily.count == 7)
        #expect(week.totalWords == expected(all, fromDay: 33).words)
        #expect(month.totalWords == expected(all, fromDay: 10).words)

        // Hour histogram: every active day dictated at 09:xx and 19:xx, plus the extras.
        let hours = sum.hours
        #expect(hours.count == 24)
        #expect(hours[9] == expected(all.filter { $0.hour == 9 }).words)
        #expect(hours[19] == expected(all.filter { $0.hour == 19 }).words)
        #expect(hours[23] == 5 && hours[0] == 5 && hours[1] == 3 && hours[3] == 3 && hours[2] == 0)

        // Languages: de-DE folds into de, missing language is "unknown", multi is kept.
        let byCode = Dictionary(uniqueKeysWithValues: sum.languages.map { ($0.code, $0.words) })
        #expect(byCode["de"] == expected(all.filter { $0.lang == "de-DE" }).words)
        #expect(byCode["en"] == expected(all.filter { $0.lang == "en" }).words)
        #expect(byCode["zh"] == 7)
        #expect(byCode["multi"] == 3)
        #expect(byCode["unknown"] == 3)
        #expect(sum.languages.map(\.words) == sum.languages.map(\.words).sorted(by: >))

        // 4. Deleting from the Library, even clearing it, leaves the lifetime totals alone.
        history.clear()
        #expect(s.insights(range: .all, now: now).totalWords == total.words)

        // 5. Reload from disk, in another time zone. Nothing moves, nothing doubles.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let reloaded = store(tokyo)
        #expect(reloaded.loadOutcome == .loaded)
        let again = reloaded.insights(range: .all, now: now)
        #expect(again.totalWords == total.words)
        #expect(again.dictations == total.dictations)
        #expect(again.hours == sum.hours)
        #expect(again.languages == sum.languages)
        // The duplicate guard survived the reload.
        #expect(reloaded.record(liveRecords[1]) == false)
        // Seeding after reload does nothing even with a full history.
        reloaded.seedIfFresh(from: seedRecords)
        #expect(reloaded.insights(range: .all, now: now).totalWords == total.words)
    }

    @Test func streakIsAliveYesterdayAndDeadAfterThat() {
        let s = store()
        s.record(record(Fx(day: 0, hour: 10, text: "one two", lang: "en", duration: 1)))
        s.record(record(Fx(day: 1, hour: 10, text: "one two", lang: "en", duration: 1)))
        #expect(s.insights(range: .all, now: nowAt(day: 1)).currentStreak == 2)
        #expect(s.insights(range: .all, now: nowAt(day: 2)).currentStreak == 2)
        #expect(s.insights(range: .all, now: nowAt(day: 3)).currentStreak == 0)
        #expect(s.insights(range: .all, now: nowAt(day: 3)).bestStreak == 2)
    }

    @Test func corruptFileIsSetAsideAndNeverOverwritten() throws {
        try Data("{ not json".utf8).write(to: fileURL)
        let s = store()
        guard case .corrupt = s.loadOutcome else {
            Issue.record("expected corrupt, got \(s.loadOutcome)")
            return
        }
        #expect(s.record(record(Fx(day: 0, hour: 9, text: "hello there", lang: "en", duration: 1))))
        // Counted in memory, but nothing was written over the set-aside original.
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("bak").path))
        #expect(s.lastSaveError != nil)
    }

    @Test func missingOrInvalidDurationsStayOutOfSpeed() throws {
        let s = store()
        for (i, d) in [nil, 0, -3, Double.nan, Double.infinity, 6].enumerated() {
            s.record(record(Fx(day: i, hour: 9, text: "one two three", lang: "en", duration: d)))
        }
        let sum = s.insights(range: .all, now: nowAt(day: 5))
        #expect(sum.totalWords == 18)
        #expect(sum.spokenSeconds == 6)
        #expect(try #require(sum.wordsPerMinute) == 30)
    }

    @Test func hugeCountsSaturateInsteadOfTrapping() {
        let s = store()
        let big = String(repeating: "word ", count: 200_000)
        for _ in 0..<3 { s.record(record(Fx(day: 0, hour: 9, text: big, lang: "en", duration: 60))) }
        #expect(s.insights(range: .all, now: nowAt(day: 0)).totalWords == 600_000)
    }

    @Test func wordCounterMatchesHowAPersonCounts() {
        let cases: [(String, Int)] = [
            ("", 0), ("   ", 0), ("...", 0), ("?!", 0), ("😀", 0),
            ("hello", 1), ("Hello, world!", 2), ("don't stop", 2), ("don’t", 1),
            ("well-known fact", 2), ("It costs 3.5 dollars", 4), ("1,000 users", 2),
            ("one\ntwo\tthree", 3), ("e-mail me at 5pm.", 4),
            ("今天天气很好", 3), ("私は犬が好きです", 4), ("Hello 世界 again", 3),
        ]
        for (text, n) in cases {
            #expect(UsageWordCounter.count(text) == n, "\(text)")
        }
    }
}
