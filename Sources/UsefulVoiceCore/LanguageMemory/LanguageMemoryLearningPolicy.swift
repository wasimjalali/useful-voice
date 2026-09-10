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
    /// Words that are ordinary parts of speech rather than names or jargon.
    ///
    /// Auto-learning a substitution between two of these is almost always wrong:
    /// the user fixed a one-off slip while editing, and the learned rule then
    /// rewrites that word in *every* future dictation. The Levenshtein acceptance
    /// test cannot tell a mis-hearing from an intentional textual edit between
    /// short common words — `then`/`than` scores 0.25, `there`/`three` 0.4,
    /// `form`/`from` 0.5, all well inside the 0.65 allowance — so "I fixed 'then'
    /// to 'than' once" used to make the app say "and than I went" forever after.
    /// Pairs drawn from this list are still learned, but only on explicit
    /// confirmation.
    public static let commonWords: Set<String> = [
        // English function words and easily-confused neighbours.
        "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can",
        "could", "did", "do", "does", "for", "form", "from", "had", "has",
        "have", "he", "her", "here", "hers", "him", "his", "how", "i", "if",
        "in", "into", "is", "it", "its", "just", "know", "like", "me", "more",
        "most", "much", "my", "no", "not", "now", "of", "off", "on", "one",
        "only", "or", "other", "our", "out", "over", "own", "quiet", "quite",
        "said", "same", "say", "she", "should", "so", "some", "such", "than",
        "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "those", "though", "thought", "three", "through", "to", "too",
        "trial", "trail", "two", "up", "us", "very", "was", "we", "were",
        "what", "when", "where", "which", "while", "who", "why", "will",
        "with", "would", "you", "your",
        // German function words, for the same reason.
        "aber", "als", "auch", "auf", "aus", "bei", "bin", "bis", "bist",
        "das", "dass", "dem", "den", "der", "des", "die", "dies", "doch",
        "ein", "eine", "einem", "einen", "einer", "eines", "er", "es", "für",
        "hat", "habe", "haben", "ich", "ihr", "ihre", "im", "in", "ist", "ja",
        "kann", "mit", "nach", "nicht", "noch", "nur", "oder", "schon", "sein",
        "sie", "sind", "so", "über", "und", "uns", "von", "vor", "war",
        "waren", "was", "wenn", "wer", "wie", "wir", "wo", "zu", "zum", "zur",
    ]

    /// True when an observed → corrected pair is a swap between ordinary words,
    /// which must be confirmed by the user before it becomes a global rule.
    public static func requiresConfirmation(observed: String, corrected: String) -> Bool {
        let left = TermMatcher.canonical(observed)
        let right = TermMatcher.canonical(corrected)
        guard !left.isEmpty, !right.isEmpty, left != right else { return false }
        // Single-word swaps between two common words are the dangerous class.
        // "agent" -> "Agent Smith" touches a common word but is a real name fix,
        // so only treat it as risky when *both* sides are common.
        return commonWords.contains(left) && commonWords.contains(right)
    }

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

        func addPair(_ observed: String, _ corrected: String, isWordLevel: Bool) {
            let key = "\(observed.lowercased())=>\(corrected)"
            guard seenPairKeys.insert(key).inserted else { return }
            pairs.append(CorrectionPair(observed: observed, corrected: corrected))
            for entry in makeEntries(observed: observed, corrected: corrected,
                                     language: language, now: now,
                                     attachPronunciation: !isWordLevel) {
                entries.append(entry)
            }
        }

        let observedWords = CorrectionLearner.tokenize(observedTrimmed)
        let correctedWords = CorrectionLearner.tokenize(correctedTrimmed)

        // Short phrases are intentional teaching (Dictionary "Fix a mistake").
        // Long library pastes rely on word-level extraction instead of storing
        // whole-sentence rules that almost never match again.
        if observedWords.count <= 6, correctedWords.count <= 6 {
            addPair(observedTrimmed, correctedTrimmed, isWordLevel: false)
        }

        // Word-level auto-learn (OpenWhispr correctionLearner).
        let wordPairs = CorrectionLearner.extractPairs(
            original: observedTrimmed,
            corrected: correctedTrimmed,
            existingDictionary: existingDictionary
        )
        for pair in wordPairs {
            // A pair the user never typed as a phrase is an inference, so it
            // gets no pronunciation. That halves the artefacts one correction
            // creates and stops the inferred term from generating a second,
            // independently firing correction rule through DictionaryCorrector.
            addPair(pair.observed, pair.corrected, isWordLevel: true)
        }

        // Fallback: texts differ but nothing was extracted (e.g. pure casing
        // on a longer phrase) → still teach the corrected form as a term.
        if pairs.isEmpty {
            addPair(observedTrimmed, correctedTrimmed, isWordLevel: false)
        }

        return LanguageMemoryLearnResult(entries: entries, pairs: pairs)
    }

    /// Single-pair policy used by tests and simple call sites.
    ///
    /// Returns `nil` for empty input rather than trapping: these strings come
    /// from user-entered text, and `[0]` on the empty array was a crash waiting
    /// for the first blank field to reach here.
    public static func makeEntry(observed: String,
                                 corrected: String,
                                 language: MemoryLanguage = .auto,
                                 now: Date = Date()) -> LanguageMemoryLearningEntry? {
        makeEntries(observed: observed, corrected: corrected, language: language,
                    now: now, attachPronunciation: true).first
    }

    private static func makeEntries(observed: String,
                                    corrected: String,
                                    language: MemoryLanguage,
                                    now: Date,
                                    attachPronunciation: Bool) -> [LanguageMemoryLearningEntry] {
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
        let pronunciation = (attachPronunciation
                             && !TermMatcher.matches(observedTrimmed, correctedTrimmed))
            ? [observedTrimmed] : []
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
