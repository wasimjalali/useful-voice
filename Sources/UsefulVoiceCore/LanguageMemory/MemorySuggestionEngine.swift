import Foundation

public enum MemorySuggestionEngine {
    public static func termSuggestions(from observedTerms: [String],
                                       snapshot: LanguageMemorySnapshot,
                                       source: MemorySuggestionSource = .formatter,
                                       now: Date = Date()) -> [MemorySuggestion] {
        var counts: [String: (display: String, count: Int)] = [:]
        for observed in observedTerms {
            let display = observed.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = TermMatcher.canonical(display)
            guard isGoodCandidate(display, canonical: canonical) else { continue }
            guard !snapshot.terms.contains(where: { TermMatcher.matches($0.phrase, display) }) else { continue }
            guard !snapshot.replacements.contains(where: { TermMatcher.matches($0.match, display) }) else { continue }
            guard !snapshot.snippets.contains(where: { TermMatcher.matches($0.trigger, display) }) else { continue }

            let current = counts[canonical]
            counts[canonical] = (
                display: current?.display ?? display,
                count: (current?.count ?? 0) + 1
            )
        }

        return counts.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending
            }
            .prefix(10)
            .map {
                MemorySuggestion(
                    kind: .term,
                    observed: $0.display,
                    proposed: $0.display,
                    evidenceCount: $0.count,
                    lastSeenAt: now,
                    source: source
                )
            }
    }

    static func isGoodCandidate(_ display: String, canonical: String) -> Bool {
        guard !canonical.isEmpty else { return false }
        guard canonical.count >= 3 else { return false }
        guard canonical.contains(where: { $0.isLetter }) else { return false }
        guard canonical.split(separator: " ").count <= 5 else { return false }
        return !display.contains("\n")
    }
}
