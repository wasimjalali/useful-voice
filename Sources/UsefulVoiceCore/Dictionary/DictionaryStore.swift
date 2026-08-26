import Foundation

/// Personal dictionary plus formatter-driven suggestions, persisted as JSON.
/// Mirrors DictationHistory's best-effort, corruption-tolerant approach.
/// Used on the main actor; not Sendable.
public final class DictionaryStore {
    private struct Persisted: Codable {
        var entries: [DictionaryEntry]
        var dismissed: [String]
        var pending: [String]
        /// Keyed by canonical term; optional so legacy JSON without this field
        /// still decodes successfully.
        var pendingCounts: [String: Int]?
    }

    private let fileURL: URL
    private var entries: [DictionaryEntry]   // newest/most-recent first
    private var dismissed: [String]          // canonical form, never suggested again
    private var pending: [String]            // awaiting accept/dismiss, insertion order
    private var pendingCounts: [String: Int] // keyed by canonical

    public init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []; dismissed = []; pending = []; pendingCounts = [:]
            return
        }
        if let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            entries = decoded.entries
            dismissed = decoded.dismissed
            pending = decoded.pending
            pendingCounts = decoded.pendingCounts ?? [:]
        } else {
            try? FileManager.default.moveItem(
                at: fileURL, to: fileURL.appendingPathExtension("bak"))
            entries = []; dismissed = []; pending = []; pendingCounts = [:]
        }
    }

    // MARK: - Personal entries

    public func all() -> [DictionaryEntry] { entries }

    public func add(word: String, soundsLike: String? = nil) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Re-adding without an alias (accept() does this) must not wipe a
        // "sounds like" the user set on the same word earlier.
        let alias = soundsLike
            ?? entries.first(where: { TermMatcher.matches($0.word, trimmed) })?.soundsLike
        // Dedupe using canonical matches instead of exact case-insensitive compare.
        entries.removeAll { TermMatcher.matches($0.word, trimmed) }
        entries.insert(DictionaryEntry(word: trimmed, soundsLike: alias), at: 0)
        // Adding a word resolves any matching pending suggestion; a stale chip
        // would otherwise linger forever (suggest() skips terms matching
        // entries, and accepting it would just re-add the word).
        removeFromPending(matching: trimmed)
        save()
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Personal words (most-recent first) then base terms, de-duped
    /// by canonical key and capped at `budget`. Spec section 4 step 2.
    public func biasList(budget: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for word in entries.map(\.word) + BaseVocabulary.terms {
            let key = TermMatcher.canonical(word)
            if seen.insert(key).inserted { result.append(word) }
            if result.count == budget { break }
        }
        return result
    }

    // MARK: - Suggestions

    /// Pending suggestions sorted by count descending, ties in insertion order.
    public func pendingSuggestions() -> [String] {
        pending.sorted { a, b in
            let ca = TermMatcher.canonical(a)
            let cb = TermMatcher.canonical(b)
            let countA = pendingCounts[ca] ?? 1
            let countB = pendingCounts[cb] ?? 1
            return countA > countB
        }
    }

    public func pendingSuggestionEvidence() -> [(term: String, evidenceCount: Int)] {
        pendingSuggestions().map { term in
            let count = pendingCounts[TermMatcher.canonical(term)] ?? 1
            return (term: term, evidenceCount: max(1, count))
        }
    }

    /// Queues formatter-guessed terms that pass quality filters, are not
    /// already personal, not BaseVocabulary terms, and not dismissed.
    /// When a term canonically matches an already-pending term, bumps that
    /// term's count instead of adding a duplicate. Keeps at most 10 pending,
    /// dropping the lowest-count oldest first when over cap.
    public func suggest(_ terms: [String]) {
        for term in terms {
            let can = TermMatcher.canonical(term)

            // Quality filter: empty canonical.
            guard !can.isEmpty else { continue }
            // Quality filter: fewer than 3 characters.
            guard can.count >= 3 else { continue }
            // Quality filter: no letters at all.
            guard can.contains(where: { $0.isLetter }) else { continue }
            // Quality filter: more than 4 space-separated words.
            guard can.split(separator: " ").count <= 4 else { continue }

            // Reject if it matches any saved entry.
            if entries.contains(where: { TermMatcher.matches($0.word, term) }) { continue }
            // Reject if it matches any BaseVocabulary term.
            if BaseVocabulary.terms.contains(where: { TermMatcher.matches($0, term) }) { continue }
            // Reject if it matches any dismissed canonical.
            if dismissed.contains(where: { TermMatcher.matches($0, can) }) { continue }

            // If it matches an already-pending term, bump count and move on.
            if let existingIndex = pending.firstIndex(where: { TermMatcher.matches($0, term) }) {
                let existingCan = TermMatcher.canonical(pending[existingIndex])
                pendingCounts[existingCan, default: 1] += 1
                continue
            }

            // New term: append and initialise count.
            pending.append(term)
            pendingCounts[can] = 1
        }

        // Enforce cap of 10: drop lowest-count oldest first.
        while pending.count > 10 {
            // Find the index of the first term with the minimum count.
            let minCount = pending.map { pendingCounts[TermMatcher.canonical($0)] ?? 1 }.min() ?? 1
            if let idx = pending.firstIndex(where: {
                (pendingCounts[TermMatcher.canonical($0)] ?? 1) == minCount
            }) {
                pendingCounts.removeValue(forKey: TermMatcher.canonical(pending[idx]))
                pending.remove(at: idx)
            } else {
                pending.removeFirst()
            }
        }

        save()
    }

    public func accept(_ term: String) {
        removeFromPending(matching: term)
        add(word: term) // save() called inside add()
    }

    public func dismiss(_ term: String) {
        removeFromPending(matching: term)
        let can = TermMatcher.canonical(term)
        dismissed.append(can)
        // Cap dismissed at 200, oldest dropped first.
        if dismissed.count > 200 {
            dismissed.removeFirst(dismissed.count - 200)
        }
        save()
    }

    // MARK: - Private helpers

    private func removeFromPending(matching term: String) {
        let toRemove = pending.filter { TermMatcher.matches($0, term) }
        for t in toRemove {
            pendingCounts.removeValue(forKey: TermMatcher.canonical(t))
        }
        pending.removeAll { TermMatcher.matches($0, term) }
    }

    private func save() {
        let snapshot = Persisted(
            entries: entries,
            dismissed: dismissed,
            pending: pending,
            pendingCounts: pendingCounts
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
