import Foundation

public struct ReplacementResult: Equatable, Sendable {
    public let text: String
    public let appliedRuleIDs: [UUID]

    public init(text: String, appliedRuleIDs: [UUID]) {
        self.text = text
        self.appliedRuleIDs = appliedRuleIDs
    }
}

public enum ReplacementEngine {
    /// With fewer rules than this, building a text index costs more than the few regex
    /// scans it would save, so every rule scans directly.
    static let indexMinRules = 16

    public static func apply(_ rules: [ReplacementRule],
                             to text: String,
                             language: MemoryLanguage) -> ReplacementResult {
        apply(rules, to: text, language: language, indexMinRules: indexMinRules)
    }

    /// `indexMinRules` exists so tests can force the indexed path (0) or the plain one
    /// (`Int.max`) and compare them; the result is the same either way.
    static func apply(_ rules: [ReplacementRule],
                      to text: String,
                      language: MemoryLanguage,
                      indexMinRules: Int) -> ReplacementResult {
        var output = text
        var applied: [UUID] = []
        // Rules run one after another over the evolving text, so the index must cover
        // every version of it: it absorbs the new text before the next lookup.
        var index: LanguageMemoryTextIndex?
        var indexIsCurrent = false
        let useIndex = rules.count >= indexMinRules

        for rule in rules where rule.isEnabled && languageMatches(rule.language, language) {
            let match = rule.match.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !match.isEmpty else { continue }

            let before = output
            switch rule.matchMode {
            case .exactPhrase:
                output = output.replacingOccurrences(of: match, with: rule.replacement)
            case .caseInsensitivePhrase:
                output = output.replacingOccurrences(
                    of: match,
                    with: rule.replacement,
                    options: [.caseInsensitive]
                )
            case .wordBoundaryPhrase:
                if useIndex, let signature = LanguageMemoryTextIndex.signature(for: match) {
                    if index == nil {
                        index = LanguageMemoryTextIndex(text: output)
                    } else if !indexIsCurrent {
                        index?.absorb(output)
                    }
                    indexIsCurrent = true
                    // The regex cannot match: it would leave `output` as it is.
                    if index?.mayContain(signature) == false { continue }
                }
                guard let regex = LanguageMemoryMatcher.wordBoundaryRegex(for: match) else { continue }
                let range = NSRange(output.startIndex..<output.endIndex, in: output)
                output = regex.stringByReplacingMatches(
                    in: output,
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement)
                )
            }

            // Byte comparison: `!=` treats canonically equal strings (NFC and NFD of the
            // same text) as equal, and the index is byte-exact like the regex.
            if !output.utf8.elementsEqual(before.utf8) {
                indexIsCurrent = false
            }
            if output != before {
                applied.append(rule.id)
            }
        }

        return ReplacementResult(text: output, appliedRuleIDs: applied)
    }

    private static func languageMatches(_ ruleLanguage: MemoryLanguage,
                                        _ current: MemoryLanguage) -> Bool {
        ruleLanguage == .auto || current == .auto || ruleLanguage == current
    }
}
