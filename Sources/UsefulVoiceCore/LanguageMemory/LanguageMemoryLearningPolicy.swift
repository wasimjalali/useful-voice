import Foundation

public enum LanguageMemoryLearningEntry: Equatable, Sendable {
    case term(MemoryTerm)
    case replacement(ReplacementRule)
}

public struct LanguageMemoryLearnResult: Equatable, Sendable {
    public let entries: [LanguageMemoryLearningEntry]
    public let pairs: [CorrectionPair]

    public init(entries: [LanguageMemoryLearningEntry], pairs: [CorrectionPair]) {
        self.entries = entries
        self.pairs = pairs
    }

    public var termCount: Int {
        entries.reduce(0) { count, entry in
            if case .term = entry { return count + 1 }
            return count
        }
    }

    public var replacementCount: Int {
        entries.reduce(0) { count, entry in
            if case .replacement = entry { return count + 1 }
            return count
        }
    }
}

public enum LanguageMemoryLearningPolicy {
    /// Build the full set of dictionary updates from an observed → corrected pair.
    ///
    /// - Always teaches the full phrase the user entered (explicit teaching).
    /// - For multi-word edits, also extracts OpenWhispr-style word substitutions
    ///   so one Library correction can learn several recurring mistakes.
    public static func entries(observed: String,
                               corrected: String,
                               language: MemoryLanguage = .auto,
                               existingDictionary: [String] = [],
                               now: Date = Date()) -> LanguageMemoryLearnResult {
        let observedTrimmed = observed.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctedTrimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !observedTrimmed.isEmpty, !correctedTrimmed.isEmpty else {
            return LanguageMemoryLearnResult(entries: [], pairs: [])
        }

        var entries: [LanguageMemoryLearningEntry] = []
        var pairs: [CorrectionPair] = []
        var seenPairKeys = Set<String>()

        func addPair(_ observed: String, _ corrected: String) {
            let key = "\(observed.lowercased())=>\(corrected)"
            guard seenPairKeys.insert(key).inserted else { return }
            pairs.append(CorrectionPair(observed: observed, corrected: corrected))
            for entry in makeEntries(observed: observed, corrected: corrected,
                                     language: language, now: now) {
                entries.append(entry)
            }
        }

        let observedWords = CorrectionLearner.tokenize(observedTrimmed)
        let correctedWords = CorrectionLearner.tokenize(correctedTrimmed)

        // Short phrases are intentional teaching (Dictionary "Fix a mistake").
        // Long library pastes rely on word-level extraction instead of storing
        // whole-sentence rules that almost never match again.
        if observedWords.count <= 6, correctedWords.count <= 6 {
            addPair(observedTrimmed, correctedTrimmed)
        }

        // Word-level auto-learn (OpenWhispr correctionLearner).
        let wordPairs = CorrectionLearner.extractPairs(
            original: observedTrimmed,
            corrected: correctedTrimmed,
            existingDictionary: existingDictionary
        )
        for pair in wordPairs {
            addPair(pair.observed, pair.corrected)
        }

        // Fallback: texts differ but nothing was extracted (e.g. pure casing
        // on a longer phrase) → still teach the corrected form as a term.
        if pairs.isEmpty {
            addPair(observedTrimmed, correctedTrimmed)
        }

        return LanguageMemoryLearnResult(entries: entries, pairs: pairs)
    }

    /// Single-pair policy used by tests and simple call sites.
    public static func makeEntry(observed: String,
                                 corrected: String,
                                 language: MemoryLanguage = .auto,
                                 now: Date = Date()) -> LanguageMemoryLearningEntry {
        makeEntries(observed: observed, corrected: corrected, language: language, now: now)[0]
    }

    private static func makeEntries(observed: String,
                                    corrected: String,
                                    language: MemoryLanguage,
                                    now: Date) -> [LanguageMemoryLearningEntry] {
        let observedTrimmed = observed.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctedTrimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)

        // Case-only (or identical) → high-priority term for STT bias + case fix.
        if observedTrimmed.caseInsensitiveCompare(correctedTrimmed) == .orderedSame {
            return [.term(MemoryTerm(
                phrase: correctedTrimmed,
                language: language,
                priority: .high,
                createdAt: now,
                updatedAt: now
            ))]
        }

        // Different words → local auto-correction AND a dictionary term so
        // Deepgram is biased toward the correct spelling next time.
        let pronunciation = TermMatcher.matches(observedTrimmed, correctedTrimmed)
            ? [] : [observedTrimmed]
        return [
            .replacement(ReplacementRule(
                match: observedTrimmed,
                replacement: correctedTrimmed,
                matchMode: .wordBoundaryPhrase,
                language: language,
                createdAt: now,
                updatedAt: now
            )),
            .term(MemoryTerm(
                phrase: correctedTrimmed,
                pronunciations: pronunciation,
                language: language,
                priority: .high,
                notes: "Learned from correction",
                createdAt: now,
                updatedAt: now
            )),
        ]
    }
}
