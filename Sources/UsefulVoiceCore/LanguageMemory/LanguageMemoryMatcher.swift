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
        return wordBoundaryRegex(for: phrase).firstMatch(
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

    static func wordBoundaryRegex(for phrase: String) -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
