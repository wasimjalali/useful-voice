import Foundation

/// Character helpers shared by the per-category formatter files.
/// `windows/src/core/formatting/categoryText.ts` mirrors them. Text is handled as an
/// array of characters so the Swift and TypeScript rules index the same way.
enum CategoryText {
    static func isWS(_ c: Character) -> Bool { c.isWhitespace }

    static func isNewline(_ c: Character) -> Bool { c == "\n" || c == "\r" || c == "\r\n" }

    static func isAlnum(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    static func trimWS(_ text: String) -> String {
        let cs = Array(text)
        var start = 0
        var end = cs.count
        while start < end && isWS(cs[start]) { start += 1 }
        while end > start && isWS(cs[end - 1]) { end -= 1 }
        return String(cs[start..<end])
    }

    /// The text split on runs of whitespace, without empty pieces.
    static func splitWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for c in text {
            if isWS(c) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The text split at every "\n". Done on scalars because a "\r\n" pair is one Character in Swift, and
    /// splitting on Characters (or with Foundation's `components`, which differs between platforms) would not
    /// split there, while the TypeScript side does.
    static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        lines.append(String(current))
        return lines
    }

    static func containsNewline(_ text: String) -> Bool { text.contains(where: isNewline) }
}
