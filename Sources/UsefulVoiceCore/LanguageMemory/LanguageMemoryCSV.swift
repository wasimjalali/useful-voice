import Foundation

public enum LanguageMemoryCSV {
    public enum Kind: String, Sendable {
        case terms, replacements
    }

    public static func exportTerms(_ terms: [MemoryTerm]) -> String {
        let rows = [["phrase", "pronunciations", "aliases", "language", "priority", "notes"]]
            + terms.map { term in
                [
                    term.phrase,
                    term.pronunciations.joined(separator: "; "),
                    term.aliases.joined(separator: "; "),
                    term.language.rawValue,
                    term.priority.rawValue,
                    term.notes,
                ]
            }
        return encode(rows)
    }

    public static func exportReplacements(_ replacements: [ReplacementRule]) -> String {
        let rows = [["match", "replacement", "matchMode", "language", "isEnabled"]]
            + replacements.map { rule in
                [
                    rule.match,
                    rule.replacement,
                    rule.matchMode.rawValue,
                    rule.language.rawValue,
                    rule.isEnabled ? "true" : "false",
                ]
            }
        return encode(rows)
    }

    public static func importTerms(_ csv: String,
                                   now: Date = Date()) -> (terms: [MemoryTerm], invalid: [String]) {
        let rows = decode(csv)
        guard !rows.isEmpty else { return ([], []) }
        let dataRows = rowsAfterOptionalHeader(rows, requiredFirstHeader: "phrase")
        var terms: [MemoryTerm] = []
        var invalid: [String] = []

        for row in dataRows {
            let phrase = value(row, 0)
            guard !TermMatcher.canonical(phrase).isEmpty else {
                invalid.append(row.joined(separator: ","))
                continue
            }
            let language = MemoryLanguage(rawValue: value(row, 3)) ?? .auto
            let priority = MemoryPriority(rawValue: value(row, 4)) ?? .high
            terms.append(MemoryTerm(
                phrase: phrase,
                pronunciations: splitList(value(row, 1)),
                aliases: splitList(value(row, 2)),
                language: language,
                priority: priority,
                notes: value(row, 5),
                createdAt: now,
                updatedAt: now
            ))
        }

        return (terms, invalid)
    }

    public static func importReplacements(_ csv: String,
                                          now: Date = Date()) -> (replacements: [ReplacementRule], invalid: [String]) {
        let rows = decode(csv)
        guard !rows.isEmpty else { return ([], []) }
        let dataRows = rowsAfterOptionalHeader(rows, requiredFirstHeader: "match")
        var replacements: [ReplacementRule] = []
        var invalid: [String] = []

        for row in dataRows {
            let match = value(row, 0)
            let replacement = value(row, 1)
            guard !TermMatcher.canonical(match).isEmpty,
                  !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                invalid.append(row.joined(separator: ","))
                continue
            }
            replacements.append(ReplacementRule(
                match: match,
                replacement: replacement,
                matchMode: ReplacementMatchMode(rawValue: value(row, 2)) ?? .wordBoundaryPhrase,
                language: MemoryLanguage(rawValue: value(row, 3)) ?? .auto,
                isEnabled: boolValue(value(row, 4), defaultValue: true),
                createdAt: now,
                updatedAt: now
            ))
        }

        return (replacements, invalid)
    }

    static func encode(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map(escape).joined(separator: ",")
        }
        .joined(separator: "\n")
    }

    static func decode(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = csv.makeIterator()

        while let character = iterator.next() {
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            consumeDelimiter(next, inQuotes: &inQuotes,
                                             row: &row, field: &field, rows: &rows)
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                consumeDelimiter(character, inQuotes: &inQuotes,
                                 row: &row, field: &field, rows: &rows)
            }
        }

        row.append(field)
        if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            rows.append(row)
        }
        return rows
    }

    private static func escape(_ field: String) -> String {
        let mustQuote = field.contains(",") || field.contains("\"") ||
            field.contains("\n") || field.contains("\r")
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return mustQuote ? "\"\(escaped)\"" : escaped
    }

    private static func consumeDelimiter(_ character: Character,
                                         inQuotes: inout Bool,
                                         row: inout [String],
                                         field: inout String,
                                         rows: inout [[String]]) {
        switch character {
        case "\"":
            if field.isEmpty { inQuotes = true }
            else { field.append(character) }
        case ",":
            row.append(field)
            field = ""
        case "\n":
            row.append(field)
            rows.append(row)
            row = []
            field = ""
        case "\r":
            break
        default:
            field.append(character)
        }
    }

    private static func rowsAfterOptionalHeader(_ rows: [[String]],
                                                requiredFirstHeader: String) -> ArraySlice<[String]> {
        guard let first = rows.first?.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              first == requiredFirstHeader else {
            return rows[rows.startIndex...]
        }
        return rows.dropFirst()
    }

    private static func value(_ row: [String], _ index: Int) -> String {
        guard row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitList(_ text: String) -> [String] {
        text.split(separator: ";")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func boolValue(_ text: String, defaultValue: Bool) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return defaultValue }
        return ["true", "yes", "1", "enabled", "on"].contains(normalized)
    }
}
