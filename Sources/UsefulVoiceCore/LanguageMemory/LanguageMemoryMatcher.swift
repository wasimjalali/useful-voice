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
        matchingTermIDs(terms, inTexts: [text], language: language)[0]
    }

    /// With fewer candidate phrases than this, building a text index costs more than the
    /// handful of regex scans it would save, so the matcher scans directly.
    static let indexMinCandidates = 16

    /// `matchingTermIDs` for several texts at once: element `i` is exactly what
    /// `matchingTermIDs(terms, in: texts[i], language:)` returns.
    ///
    /// For a large dictionary each text gets a `LanguageMemoryTextIndex`, and a phrase only
    /// reaches its regex when the index says the text could contain it. The phrases'
    /// signatures are computed once and shared by every text.
    static func matchingTermIDs(_ terms: [MemoryTerm],
                                inTexts texts: [String],
                                language: MemoryLanguage = .auto,
                                indexMinCandidates: Int = LanguageMemoryMatcher.indexMinCandidates) -> [[UUID]] {
        let filtered = terms.filter { term in
            term.language == .auto || language == .auto || term.language == language
        }
        let candidates: [[String]] = filtered.map { [$0.phrase] + $0.aliases + $0.pronunciations }
        let candidateCount = candidates.reduce(0) { $0 + $1.count }
        let useIndex = candidateCount >= indexMinCandidates

        let signatures: [[LanguageMemoryTextIndex.Signature?]] = useIndex
            ? candidates.map { $0.map(LanguageMemoryTextIndex.signature(for:)) }
            : []

        return texts.map { text in
            let index = useIndex ? LanguageMemoryTextIndex(text: text) : nil
            var result: [UUID] = []
            var seen = Set<UUID>()

            for (t, term) in filtered.enumerated() {
                let hit = candidates[t].indices.contains { c in
                    if let index, let signature = signatures[t][c], !index.mayContain(signature) {
                        return false
                    }
                    return containsWordBoundaryPhrase(candidates[t][c], in: text)
                }
                guard hit else { continue }
                if seen.insert(term.id).inserted {
                    result.append(term.id)
                }
            }

            return result
        }
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
    /// Keyed on the phrase's UTF-8 bytes, not the `String`: `String` equality and hashing
    /// treat canonically equivalent text (NFC "é" and NFD "e" + U+0301) as one key, so a
    /// phrase typed one way was served the regex compiled for the other. The ICU matcher
    /// compares code points and treats them as different, so what a phrase matched
    /// depended on which spelling happened to be looked up first.
    private static var cache: [[UInt8]: NSRegularExpression] = [:]
    /// Bound on how many compiled phrases are retained — not on what works.
    /// Once the cache is full, a new phrase still compiles and matches; it is
    /// simply not stored. Clearing at the bound would evict a large
    /// dictionary's own hot entries and recompile every one of them on the
    /// next dictation, which is exactly the cost this cache exists to remove.
    private static let cacheLimit = 4096

    /// Compiles (or reuses) the word-boundary matcher for `phrase`.
    ///
    /// Returns `nil` rather than trapping when the phrase cannot be compiled
    /// (over-long input, or a pattern the ICU engine rejects). A dictionary
    /// entry is user data: it must never be able to crash the app.
    static func wordBoundaryRegex(for phrase: String) -> NSRegularExpression? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxPhraseLength else { return nil }

        let key = Array(trimmed.utf8)
        cacheLock.lock()
        if let cached = cache[key] {
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
        if cache.count < cacheLimit {
            cache[key] = regex
        }
        cacheLock.unlock()
        return regex
    }
}
