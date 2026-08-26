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
    public static func apply(_ rules: [ReplacementRule],
                             to text: String,
                             language: MemoryLanguage) -> ReplacementResult {
        var output = text
        var applied: [UUID] = []

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
                let regex = LanguageMemoryMatcher.wordBoundaryRegex(for: match)
                let range = NSRange(output.startIndex..<output.endIndex, in: output)
                output = regex.stringByReplacingMatches(
                    in: output,
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement)
                )
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
