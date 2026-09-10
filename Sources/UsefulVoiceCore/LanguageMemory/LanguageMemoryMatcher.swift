import Foundation

public enum LanguageMemoryMatcher {
    public static func canonical(_ text: String) -> String {
        TermMatcher.canonical(text)
    }

    public static func duplicates(_ a: String, _ b: String) -> Bool {
        TermMatcher.matches(a, b)
    }

    public static func containsWordBoundaryPhrase(_ phrase: String, in text: String) -> Bool {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard let regex = wordBoundaryRegex(for: phrase) else { return false }
        return regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }

    public static func matchingTermIDs(_ terms: [MemoryTerm],
                                       in text: String,
                                       language: MemoryLanguage = .auto) -> [UUID] {
        let filtered = terms.filter { term in
            term.language == .auto || language == .auto || term.language == language
        }
        var result: [UUID] = []

        for term in filtered {
            let candidates = [term.phrase] + term.aliases + term.pronunciations
            guard candidates.contains(where: { containsWordBoundaryPhrase($0, in: text) }) else {
                continue
            }
            if !result.contains(term.id) {
                result.append(term.id)
            }
        }

        return result
    }

    /// Longest phrase we will compile a matcher for. A dictionary term or
    /// snippet trigger is a short phrase; anything longer is a paste. Bounding
    /// the length bounds the compiled regex, which matters because this is
    /// compiled and run on every dictation.
    static let maxPhraseLength = 200

    /// Cache of compiled matchers, keyed by the phrase.
    ///
    /// Word-boundary matching runs once per dictionary term per dictation, and
    /// `DictionaryCorrector` synthesizes a rule per term, so a several-hundred
    /// term dictionary meant tens of thousands of ICU compilations per dictation
    /// on the main actor. Compiling each distinct phrase once removes that cost;
    /// `NSRegularExpression` is documented as thread-safe for matching, and the
    /// lock keeps the dictionary itself safe.
    private static let cacheLock = NSLock()
    private static var cache: [String: NSRegularExpression] = [:]
    /// Bound on the cache so a pathological stream of distinct phrases (for
    /// example a huge imported snippet set) cannot grow it without limit.
    private static let cacheLimit = 4096

    /// Compiles (or reuses) the word-boundary matcher for `phrase`.
    ///
    /// Returns `nil` rather than trapping when the phrase cannot be compiled
    /// (over-long input, or a pattern the ICU engine rejects). A dictionary
    /// entry is user data: it must never be able to crash the app.
    static func wordBoundaryRegex(for phrase: String) -> NSRegularExpression? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPhraseLength else { return nil }

        cacheLock.lock()
        if let cached = cache[trimmed] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        let pattern = #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive]) else {
            return nil
        }

        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[trimmed] = regex
        cacheLock.unlock()
        return regex
    }
}
