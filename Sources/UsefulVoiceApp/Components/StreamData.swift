import AppKit
import Combine
import SwiftUI
import UsefulVoiceCore

// MARK: - Formatting

/// Number, date and language formats for the Stream. German-region numbers and dates
/// (1.000, 1,2 min, "Thu 8. Oct"), English words.
enum StreamFormat {
    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }

    private static let clock = formatter("HH:mm")
    private static let shortDay = formatter("EEE d. MMM")
    private static let number: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.numberStyle = .decimal
        return formatter
    }()

    static func time(_ date: Date) -> String { clock.string(from: date) }

    /// "Thu 8. Oct".
    static func day(_ date: Date) -> String { shortDay.string(from: date) }

    /// "Today", "Yesterday", or "Thu 8. Oct".
    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return day(date)
    }

    static func count(_ value: Int) -> String {
        number.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func words(_ count: Int) -> String {
        count == 1 ? "1 word" : "\(Self.count(count)) words"
    }

    static func dictations(_ count: Int) -> String {
        count == 1 ? "1 dictation" : "\(Self.count(count)) dictations"
    }

    /// "9 s" under a minute, "1,2 min" above.
    static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        return String(format: "%.1f min", locale: Locale(identifier: "de_DE"), seconds / 60)
    }

    /// m:ss.
    static func timer(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// The key a stored language code groups under, and its native name. Nil for
    /// auto-detect or a code this build does not know.
    static func language(forCode code: String?) -> (key: String, name: String)? {
        guard let code else { return nil }
        let pin = LanguagePin(recordedCode: code)
        if pin.isMultilingual { return ("multi", "Multiple languages") }
        guard let language = pin.language else { return nil }
        return (language.code, language.nativeName)
    }

    /// The name of a dictation hotkey as it is written in the UI.
    static func keyName(_ keycode: Int) -> String {
        let label = HotkeyOption.label(for: keycode)
        return label == "Right Control" ? "Right Ctrl" : label
    }

    /// True when most letters are right-to-left (Persian, Arabic, Hebrew, Urdu).
    static func isRTL(_ text: String) -> Bool {
        var rtl = 0
        var ltr = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: rtl += 1
            default: if scalar.properties.isAlphabetic { ltr += 1 }
            }
        }
        return rtl > ltr
    }
}

// MARK: - Text pieces

enum StreamText {
    /// NSRanges (UTF-16) of every case- and diacritic-insensitive match of `query`.
    static func matches(of query: String, in text: String) -> [NSRange] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var ranges: [NSRange] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: cursor..<text.endIndex) {
            ranges.append(NSRange(found, in: text))
            cursor = found.upperBound
        }
        return ranges
    }

    /// A window around the first match of a long dictation, trimmed to word edges and
    /// marked with ellipses. Nil when the text is short or has no match.
    static func excerpt(of text: String, matching query: String, limit: Int = 220) -> String? {
        guard text.count > limit,
              let match = text.range(of: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                     options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        var start = text.index(match.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(match.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
        if start > text.startIndex {
            while start < match.lowerBound, !text[start].isWhitespace { start = text.index(after: start) }
        }
        if end < text.endIndex {
            while end > match.upperBound, !text[end].isWhitespace { end = text.index(before: end) }
        }
        var piece = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > text.startIndex { piece = "…" + piece }
        if end < text.endIndex { piece += "…" }
        return piece
    }

    /// A word-level diff of the engine's raw text against the formatted text: words only
    /// in the raw text are `removed` (struck through), words only in the formatted text
    /// are `added`. Nil when the texts are too long to diff cheaply.
    static func diff(original: String, final: String) -> StreamTextSpec? {
        let old = original.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let new = final.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard old.count <= 1_500, new.count <= 1_500 else { return nil }
        // Words match without their punctuation, so a comma the formatter added is not a
        // change; a different capital letter is.
        func key(_ word: String) -> String {
            word.trimmingCharacters(in: .punctuationCharacters)
        }
        let oldKeys = old.map(key)
        let newKeys = new.map(key)
        // Longest common subsequence table, filled from the tail.
        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        if !old.isEmpty, !new.isEmpty {
            for i in stride(from: old.count - 1, through: 0, by: -1) {
                for j in stride(from: new.count - 1, through: 0, by: -1) {
                    table[i][j] = oldKeys[i] == newKeys[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var text = ""
        var spans: [StreamTextSpec.Span] = []
        func emit(_ word: String, _ style: StreamTextSpec.Style?) {
            if !text.isEmpty { text += " " }
            let start = (text as NSString).length
            text += word
            if let style { spans.append(.init(range: NSRange(location: start, length: (word as NSString).length), style: style)) }
        }
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, oldKeys[i] == newKeys[j] {
                emit(new[j], nil); i += 1; j += 1
            } else if i < old.count, j == new.count || table[i + 1][j] >= table[i][j + 1] {
                emit(old[i], .removed); i += 1
            } else {
                emit(new[j], .added); j += 1
            }
        }
        return StreamTextSpec(text: text, spans: spans, rtl: StreamFormat.isRTL(final))
    }
}

/// What a bubble's text view draws: the string plus styled ranges.
struct StreamTextSpec: Equatable {
    enum Style: Equatable {
        /// A search match: 600 weight on a light tint.
        case match
        /// A word the engine wrote that the formatted text dropped: struck through, muted.
        case removed
        /// A word the formatted text added or changed: 600 weight on a light tint.
        case added
        /// The words picked for Teach a fix.
        case teach
    }

    struct Span: Equatable {
        let range: NSRange
        let style: Style
    }

    var text: String
    var spans: [Span] = []
    var rtl = false
}

// MARK: - Days

struct StreamDay: Identifiable, Equatable {
    let day: Date
    /// Oldest first, so the newest dictation of the day sits lowest.
    var records: [DictationRecord]
    var id: Date { day }
}

// MARK: - Store

/// What the Stream shows and what its actions do. Filters and groups only when the
/// history, the search or a filter changes, never per frame.
@MainActor
final class StreamStore: ObservableObject {
    enum Scope: Hashable {
        case all, today, week
        case language(String)
    }

    struct LanguageChip: Hashable, Identifiable {
        let key: String
        let name: String
        var id: String { key }
    }

    struct Toast: Identifiable {
        enum Kind { case success, info, danger }
        let id = UUID()
        let message: String
        let kind: Kind
        let undo: (() -> Void)?
    }

    let viewModel: UsefulVoiceViewModel

    @Published var query = "" { didSet { if query != oldValue { rebuild() } } }
    @Published var scope: Scope = .all { didSet { if scope != oldValue { rebuild() } } }

    @Published private(set) var days: [StreamDay] = []
    /// Newest last, the order bubbles are drawn in. Arrow keys and Shift-click ranges walk it.
    private(set) var flat: [DictationRecord] = []
    @Published private(set) var storedCount = 0
    @Published private(set) var shownCount = 0
    @Published private(set) var languageChips: [LanguageChip] = []
    /// False on a Mac that never dictated: the empty Stream then says how to start.
    @Published private(set) var everDictated = false

    /// Shift-click selection.
    @Published private(set) var selection: Set<UUID> = []
    private var selectionAnchor: UUID?
    /// The bubble the arrow keys are on.
    @Published var focusedID: UUID?
    /// The bubble whose action menu (Enter) is open.
    @Published var menuID: UUID?
    /// The bubble waiting for words to be picked for Teach a fix.
    @Published var teachSelectID: UUID?
    @Published var originalShown: Set<UUID> = []
    @Published var expanded: Set<UUID> = []
    /// The dictation that just arrived: it rises in and keeps a raised shadow for a second.
    @Published private(set) var freshID: UUID?
    /// Bumped when a dictation arrives, so the timeline can follow it.
    @Published private(set) var arrivals = 0

    @Published private(set) var toast: Toast?
    @Published var pendingDelete: DictationRecord?

    private var all: [DictationRecord] = []
    private var newestID: UUID?
    private var loaded = false
    private var cancellables: Set<AnyCancellable> = []
    private var toastTask: Task<Void, Never>?
    private var freshTask: Task<Void, Never>?

    /// Offscreen renders only (they need `UV_SNAPSHOT`). `UV_STREAM_SAMPLE=1` shows the
    /// board's sample dictations, `=empty` a Mac that never dictated, `=deleted` an empty
    /// Stream after Delete all. `UV_STREAM_QUERY`, `UV_STREAM_SCOPE` (`today`, `week`, a
    /// language key) and `UV_STREAM_PREVIEW` (see `applyPreview`) set the view state.
    private static let environment: [String: String] = {
        let env = ProcessInfo.processInfo.environment
        return env["UV_SNAPSHOT"] != nil ? env : [:]
    }()
    static let sampleMode: String? = environment["UV_STREAM_SAMPLE"]
    static let sample: Bool = sampleMode != nil
    static let preview: String? = environment["UV_STREAM_PREVIEW"]

    init(viewModel: UsefulVoiceViewModel) {
        self.viewModel = viewModel
        reload()
        if Self.sample { applyPreview() }
        viewModel.$recent
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    /// Offscreen renders only: puts the Stream in a state that needs a click or a hover.
    private func applyPreview() {
        let env = StreamStore.environment
        if let text = env["UV_STREAM_QUERY"] { query = text }
        if let name = env["UV_STREAM_SCOPE"] {
            switch name {
            case "today": scope = .today
            case "week": scope = .week
            default: scope = .language(name)
            }
        }
        switch StreamStore.preview {
        case "selected": selection = Set(flat.suffix(3).map(\.id))
        case "original": originalShown = Set(flat.suffix(1).map(\.id))
        case "focus": focusedID = flat.dropLast().last?.id
        case "select": teachSelectID = flat.last?.id
        case "dialog": pendingDelete = flat.last
        case "toast": show("Added to Launch checklist") {}
        default: break
        }
    }

    // MARK: Loading

    func reload() {
        let previousNewest = newestID
        all = (Self.sample ? (Self.sampleMode == "1" ? StreamSampleData.records()
                : (Int(Self.sampleMode ?? "").map(StreamSampleData.many) ?? []))
               : viewModel.historyStore.all())
            .sorted { $0.createdAt > $1.createdAt }
        storedCount = all.count
        newestID = all.first?.id
        if all.isEmpty {
            everDictated = Self.sample ? Self.sampleMode == "deleted"
                : viewModel.usageStats.insights(range: .all).hasAnyData
        }

        var counts: [String: (name: String, count: Int)] = [:]
        for record in all {
            guard let language = StreamFormat.language(forCode: record.language) else { continue }
            counts[language.key, default: (language.name, 0)].count += 1
        }
        languageChips = counts
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .map { LanguageChip(key: $0.key, name: $0.value.name) }
        if case .language(let key) = scope, counts[key] == nil { scope = .all }

        let arrived = loaded && newestID != previousNewest && all.first != nil
        if arrived {
            withAnimation(BrandMotion.resolved(BrandMotion.rise)) { rebuild() }
            freshID = newestID
            arrivals += 1
            freshTask?.cancel()
            freshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled { self?.freshID = nil }
            }
        } else {
            rebuild()
        }
        loaded = true
    }

    private func rebuild() {
        let calendar = Calendar.current
        var records = all
        switch scope {
        case .all: break
        case .today:
            records = records.filter { calendar.isDateInToday($0.createdAt) }
        case .week:
            if let week = calendar.dateInterval(of: .weekOfYear, for: Date()) {
                records = records.filter { week.contains($0.createdAt) }
            }
        case .language(let key):
            records = records.filter { StreamFormat.language(forCode: $0.language)?.key == key }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            records = records.filter {
                $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        shownCount = records.count
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.createdAt) }
        days = grouped
            .map { StreamDay(day: $0.key, records: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.day < $1.day }
        flat = days.flatMap(\.records)
        let ids = Set(flat.map(\.id))
        selection.formIntersection(ids)
        if let focusedID, !ids.contains(focusedID) { self.focusedID = nil }
        if selection.isEmpty { selectionAnchor = nil }
    }

    var hasFilter: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scope != .all }

    func clearFilters() {
        query = ""
        scope = .all
    }

    // MARK: Keyboard and selection

    func moveFocus(_ delta: Int) {
        guard !flat.isEmpty else { return }
        guard let current = focusedID, let index = flat.firstIndex(where: { $0.id == current }) else {
            focusedID = flat.last?.id
            return
        }
        focusedID = flat[min(max(index + delta, 0), flat.count - 1)].id
    }

    /// Shift-click: the first click selects, the next ones extend the range from the anchor.
    func shiftClick(_ id: UUID) {
        guard let index = flat.firstIndex(where: { $0.id == id }) else { return }
        if let anchor = selectionAnchor, let anchorIndex = flat.firstIndex(where: { $0.id == anchor }),
           !selection.isEmpty {
            let range = min(anchorIndex, index)...max(anchorIndex, index)
            selection.formUnion(flat[range].map(\.id))
        } else {
            selection = [id]
            selectionAnchor = id
        }
    }

    func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    var selectedRecords: [DictationRecord] { flat.filter { selection.contains($0.id) } }

    func toggleOriginal(_ id: UUID) {
        if originalShown.contains(id) { originalShown.remove(id) } else { originalShown.insert(id) }
    }

    func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Toasts

    func show(_ message: String, kind: Toast.Kind = .success, undo: (() -> Void)? = nil) {
        let item = Toast(message: message, kind: kind, undo: undo)
        withAnimation(BrandMotion.resolved(BrandMotion.hudEnter)) { toast = item }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: undo == nil ? 2_400_000_000 : 5_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(BrandMotion.resolved(BrandMotion.hudExit)) {
                if self?.toast?.id == item.id { self?.toast = nil }
            }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(BrandMotion.resolved(BrandMotion.hudExit)) { toast = nil }
    }

    // MARK: Actions

    func copy(_ records: [DictationRecord]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(records.map(\.text).joined(separator: "\n\n"), forType: .string)
        show("Copied")
    }

    /// Every dictation the Stream is showing, as plain text: a time line, then the text.
    func exportShown() {
        guard !flat.isEmpty else { return }
        let text = days.map { day in
            day.records.map { "\(StreamFormat.day(day.day)) \(StreamFormat.time($0.createdAt))\n\($0.text)" }
                .joined(separator: "\n\n")
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("\(StreamFormat.dictations(flat.count)) copied")
    }

    func addToNote(_ records: [DictationRecord], note: ScratchpadNote) {
        let text = records.map(\.text).joined(separator: "\n\n")
        let scratchpad = viewModel.scratchpad
        // Nil means the note is gone or the save failed: never say it was added.
        guard let previous = scratchpad.append(text, toNoteID: note.id) else {
            show("Couldn't add to \(note.title). Notes can't be saved right now.", kind: .danger)
            return
        }
        clearSelection()
        show("Added to \(note.title)") { [weak self] in
            if !scratchpad.restoreBody(previous, noteID: note.id) {
                self?.show("Couldn't undo. Notes can't be saved right now.", kind: .danger)
            }
        }
    }

    func addToNewNote(_ records: [DictationRecord]) {
        let text = records.map(\.text).joined(separator: "\n\n")
        let scratchpad = viewModel.scratchpad
        guard let note = scratchpad.createDictationNote(text) else {
            show("Couldn't create the note. Notes can't be saved right now.", kind: .danger)
            return
        }
        clearSelection()
        show("Added to \(note.title)") { [weak self] in
            scratchpad.select(note.id)
            scratchpad.deleteSelected()
            if scratchpad.saveState == .failed {
                self?.show("Couldn't undo. Notes can't be saved right now.", kind: .danger)
            }
        }
    }

    func learn(observed: String, corrected: String) {
        let result = viewModel.languageMemory.learnCorrection(observed: observed, corrected: corrected)
        viewModel.refreshLanguageMemory()
        if result.pairs.isEmpty {
            show("Nothing new to learn", kind: .info)
        } else {
            show(result.replacementCount <= 1 ? "Fix saved" : "\(result.replacementCount) fixes saved")
        }
    }

    func reprocess(_ record: DictationRecord) {
        viewModel.reprocessHistoryWithLanguageMemory(record)
        show("Reprocessing…", kind: .info)
    }

    /// Delete at once with Undo when records can be restored (preview), otherwise ask first.
    func requestDelete(_ record: DictationRecord) {
        if PreviewFeatures.enabled {
            delete(record, offerUndo: true)
        } else {
            pendingDelete = record
        }
    }

    func confirmDelete() {
        guard let record = pendingDelete else { return }
        pendingDelete = nil
        delete(record, offerUndo: false)
    }

    private func delete(_ record: DictationRecord, offerUndo: Bool) {
        let history = viewModel.historyStore
        history.delete(id: record.id)
        selection.remove(record.id)
        viewModel.refreshRecent()
        reload()
        if offerUndo {
            show("Dictation deleted", kind: .info) { [weak self] in
                history.append(record)
                self?.viewModel.refreshRecent()
                self?.reload()
            }
        } else {
            show("Dictation deleted", kind: .info)
        }
    }
}

// MARK: - Sample data

/// The board's dictations, for offscreen renders only (`UV_STREAM_SAMPLE=1`).
enum StreamSampleData {
    /// `UV_STREAM_SAMPLE=<count>`: that many dictations over many days, for a load check.
    static func many(_ count: Int) -> [DictationRecord] {
        let base = records()
        let now = Date()
        return (0..<count).map { index in
            let source = base[index % base.count]
            return DictationRecord(
                text: source.text, createdAt: now.addingTimeInterval(-Double(index) * 1_800),
                language: source.language, provider: "Deepgram", durationSeconds: source.durationSeconds,
                rawText: source.rawText)
        }
    }

    static func records() -> [DictationRecord] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        func record(_ date: Date, _ text: String, _ language: String, _ seconds: Double,
                    raw: String? = nil) -> DictationRecord {
            DictationRecord(text: text, createdAt: date, language: language, provider: "Deepgram",
                            durationSeconds: seconds, mode: raw == nil ? .raw : .formatted, rawText: raw)
        }
        let long = "Okay, so here's what I did. I ran tsc across the whole repo and it came back clean, then I ran the Next build and that passed too, so the type work is done. After that I restarted the services with Node 24 and checked the logs for each one, nothing unusual. Then I verified the two-bot group chat end to end: the first bot answers the comment, the second bot picks up the thread and replies once, and neither of them answers its own message. Please review it in its worktree and report findings with severity and line numbers. Then run the same pass on the second worktree and compare the two, because the second one has the retry change and I want to be sure it did not touch the queue logic."
        return [
            record(at(-1, 11, 20), "I'll review the launch checklist tonight and send you the changes.", "en", 6),
            record(at(-1, 18, 20), "How do I restore the document from the trash? Give me the command.", "en", 6),
            record(at(-1, 21, 3), "بنده همان شخصی هستم که چند هفته پیش برای شما یک برنامه ساختم که سوالات تکراری را در کامنت‌ها پاسخ می‌دهد.", "fa", 19),
            record(at(0, 16, 21), "Book the dentist for Thursday morning.", "en", 5),
            record(at(0, 16, 40), long, "en", 72),
            record(at(0, 16, 52), "Kannst du bitte die Datenschutz-Folgenabschätzung bis Freitag fertig machen und mir dann eine kurze Zusammenfassung schicken?", "de", 14),
            record(at(0, 16, 58), "Can you check whether the build is green?", "en", 5),
            record(at(0, 17, 3), "Ask the Barry to check the build before we ship, and put the launch checklist in the notes.", "en", 8),
            record(at(0, 17, 14), "After the performance review, skip the Devin VM and run it on this computer. I'll keep the computer quiet so you can run the performance check here, and remove the Devin dependency from the cloud setup.", "en", 24),
            record(at(0, 17, 15), "Also, from the language dropdown in the UI, I'm not sure we should keep the other languages or remove them. The model does support them, so you decide as the expert. If the other languages work, maybe not as well as English, keep them, but English is our priority and it has to be very strong.", "en", 29),
            record(at(0, 17, 16),
                   "And again, when you run the reviews for this, skip the Opus review completely and just run the Sonnet reviews, maybe two of them.", "en", 9,
                   raw: "and again when you run the reviews for this skip the opus review completely and just run the sonnet reviews maybe two of them"),
        ]
    }
}
