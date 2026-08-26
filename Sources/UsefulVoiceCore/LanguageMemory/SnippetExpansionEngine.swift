import Foundation

public struct SnippetExpansionResult: Equatable, Sendable {
    public let text: String
    public let appliedSnippetIDs: [UUID]

    public init(text: String, appliedSnippetIDs: [UUID]) {
        self.text = text
        self.appliedSnippetIDs = appliedSnippetIDs
    }
}

public enum SnippetExpansionEngine {
    public static func apply(_ snippets: [MemorySnippet],
                             to text: String,
                             language: MemoryLanguage) -> SnippetExpansionResult {
        var output = text
        var applied: [UUID] = []

        for snippet in snippets where snippet.isEnabled && languageMatches(snippet.language, language) {
            let trigger = snippet.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
            let expansion = snippet.expansion.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !expansion.isEmpty else { continue }

            let before = output
            let regex = LanguageMemoryMatcher.wordBoundaryRegex(for: trigger)
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: expansion)
            )
            if output != before {
                applied.append(snippet.id)
            }
        }

        return SnippetExpansionResult(text: output, appliedSnippetIDs: applied)
    }

    private static func languageMatches(_ snippetLanguage: MemoryLanguage,
                                        _ current: MemoryLanguage) -> Bool {
        snippetLanguage == .auto || current == .auto || snippetLanguage == current
    }
}
