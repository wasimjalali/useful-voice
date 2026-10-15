import Foundation

/// Lays a long dictation out as an email.
/// `windows/src/core/formatting/categoryEmail.ts` mirrors this file rule for rule.
///
/// Restrained on purpose: it only moves what was dictated (and capitalises the first word
/// of each paragraph when it was said in plain lowercase, since it now starts a line). A
/// greeting or sign-off that was not said is never added, and paragraphs are split only at
/// a dictated sign-off or a spoken "new paragraph". The one thing it can add is the user's
/// own name under a dictated sign-off, and only when a non-empty name is passed in.
public enum CategoryEmail {
    /// Dictations shorter than this are left alone unless they open with a greeting.
    public static let minWords = 25

    private static let greetingWords: Set<String> = ["hi", "hey", "hello", "dear"]

    /// Sign-off phrases, longest first so "best regards" wins over "best".
    private static let signOffs: [[String]] = [
        ["yours", "sincerely"],
        ["best", "regards"],
        ["kind", "regards"],
        ["warm", "regards"],
        ["best", "wishes"],
        ["many", "thanks"],
        ["thank", "you"],
        ["thanks"],
        ["best"],
        ["regards"],
        ["cheers"],
        ["sincerely"],
    ]

    /// Stands for a spoken "new paragraph" while the words are being sorted.
    private static let breakMark = "\u{1}"

    private static func endsWithAny(_ word: String, _ marks: String) -> Bool {
        guard let last = word.last else { return false }
        return marks.contains(last)
    }

    private static func stripTrailing(_ word: String, _ marks: String) -> String {
        var out = word
        while let last = out.last, marks.contains(last) { out.removeLast() }
        return out
    }

    /// How many leading words form a greeting ("Hi Sam," is 2), or 0. It must end in a comma or "!".
    private static func greetingLength(_ words: [String]) -> Int {
        guard let first = words.first,
              greetingWords.contains(stripTrailing(first, ",.!").lowercased()) else { return 0 }
        let limit = min(5, words.count)
        for n in 1...limit where endsWithAny(words[n - 1], ",!") { return n }
        return 0
    }

    /// Replaces each spoken "new paragraph" that stands on its own with a break marker.
    private static func markBreaks(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            let next: String? = i + 1 < words.count ? words[i + 1] : nil
            let previous: String? = out.last
            let atBoundary = previous == nil || endsWithAny(previous!, ".!?,") || previous == breakMark
            if let next,
               word.lowercased() == "new",
               stripTrailing(next, ".,!?").lowercased() == "paragraph",
               endsWithAny(next, ".,!?") || i + 1 == words.count - 1,
               atBoundary {
                out.append(breakMark)
                i += 2
            } else {
                out.append(word)
                i += 1
            }
        }
        return out
    }

    /// A dictated name after a sign-off: letters only, capitalised, never "I".
    private static func isNameWord(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase, word != "I" else { return false }
        return word.allSatisfy { $0.isLetter || $0 == "-" }
    }

    private struct SignOff {
        /// Index in the word list where the sign-off phrase starts.
        let start: Int
        let phrase: String
        let name: String?
    }

    private static func findSignOff(_ words: [String]) -> SignOff? {
        guard words.count > 1 else { return nil }
        for start in 1..<words.count {
            if !words[0..<start].contains(where: { $0 != breakMark }) { continue }
            let previous = words[start - 1]
            if previous != breakMark && !endsWithAny(previous, ".!?") { continue }
            for phrase in signOffs {
                let length = phrase.count
                if start + length > words.count { continue }
                var matches = true
                for k in 0..<length {
                    let word = words[start + k]
                    let comparable = k == length - 1 ? stripTrailing(word, ",.!") : word
                    if comparable.lowercased() != phrase[k] {
                        matches = false
                        break
                    }
                }
                if !matches { continue }
                let lastWord = words[start + length - 1]
                let after = Array(words[(start + length)...])
                let phraseText = words[start..<(start + length)].joined(separator: " ")
                if after.isEmpty { return SignOff(start: start, phrase: phraseText, name: nil) }
                if after.count > 3 || !endsWithAny(lastWord, ",.!") { continue }
                var nameWords: [String] = []
                for (idx, w) in after.enumerated() {
                    nameWords.append(idx == after.count - 1 ? stripTrailing(w, ".") : w)
                }
                if !nameWords.allSatisfy(isNameWord) { continue }
                return SignOff(start: start, phrase: phraseText, name: nameWords.joined(separator: " "))
            }
        }
        return nil
    }

    /// "Thanks." or "Thanks" becomes "Thanks," when a name line follows.
    private static func withComma(_ phrase: String) -> String {
        stripTrailing(phrase, ",.!") + ","
    }

    /// Structures a dictation as an email: greeting line, paragraphs, sign-off, and the
    /// user's name under a dictated sign-off. Returns the text unchanged when it is under
    /// the word minimum with no greeting, already contains a line break, or has nothing to
    /// lay out.
    public static func structure(_ text: String, userName: String?,
                                 dictionaryWords: [String] = []) -> String {
        if CategoryText.containsNewline(text) { return text }
        let spoken = CategoryText.splitWords(text)
        let greetingCount = greetingLength(spoken)
        if spoken.count < minWords && greetingCount == 0 { return text }

        let greeting: String? = greetingCount > 0 ? spoken[0..<greetingCount].joined(separator: " ") : nil
        let marked = markBreaks(Array(spoken[greetingCount...]))
        let hadBreak = marked.contains(breakMark)
        let signOff = findSignOff(marked)
        if greeting == nil && signOff == nil && !hadBreak { return text }

        let bodyWords = signOff == nil ? marked : Array(marked[0..<signOff!.start])
        var paragraphs: [String] = []
        var current: [String] = []
        for word in bodyWords {
            if word == breakMark {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                current = []
            } else {
                current.append(word)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }

        var blocks: [String] = []
        if let greeting { blocks.append(greeting) }
        blocks.append(contentsOf: paragraphs.map {
            CategoryContinuation.capitalizeFirstWord($0, dictionaryWords: dictionaryWords)
        })
        if let signOff {
            let typedName = CategoryText.trimWS(userName ?? "")
            let name: String? = signOff.name ?? (typedName.isEmpty ? nil : typedName)
            if let name {
                blocks.append(withComma(signOff.phrase) + "\n" + name)
            } else {
                blocks.append(signOff.phrase)
            }
        }
        return blocks.joined(separator: "\n\n")
    }
}
