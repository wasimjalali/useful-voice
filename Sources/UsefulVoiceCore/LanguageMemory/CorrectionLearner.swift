import Foundation

/// One observed → corrected substitution extracted from a user edit.
public struct CorrectionPair: Equatable, Sendable {
    public let observed: String
    public let corrected: String

    public init(observed: String, corrected: String) {
        self.observed = observed
        self.corrected = corrected
    }
}

/// Port of OpenWhispr's `correctionLearner.js`, extended to return both sides of
/// each substitution so Useful Voice can create deterministic auto-corrections.
///
/// Algorithm:
/// 1. Tokenize original and edited text (punctuation stripped at edges).
/// 2. Reject wholesale rewrites (more than half the words changed).
/// 3. Align tokens with word-level LCS.
/// 4. Treat consecutive delete+insert as a substitution.
/// 5. Keep pairs that look phonetic (Levenshtein ratio ≤ 0.65), length ≥ 3,
///    and not already in the dictionary.
public enum CorrectionLearner {
    /// Maximum relative edit distance for a pair to count as a correction.
    /// 0.65 allows phonetic fixes like "Shunade" → "Sinead" while filtering
    /// unrelated word swaps.
    public static let maxRelativeDistance: Double = 0.65

    public static func extractPairs(original: String,
                                    corrected: String,
                                    existingDictionary: [String] = []) -> [CorrectionPair] {
        let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctedTrimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalTrimmed.isEmpty, !correctedTrimmed.isEmpty else { return [] }
        guard originalTrimmed != correctedTrimmed else { return [] }

        let origWords = tokenize(originalTrimmed)
        let editedWords = tokenize(correctedTrimmed)
        guard !origWords.isEmpty, !editedWords.isEmpty else { return [] }

        let subs = findSubstitutions(origWords: origWords, editedWords: editedWords)
        // More than half the words changed → rewrite, not correction teaching.
        if subs.count > max(1, origWords.count / 2) { return [] }

        let dictSet = Set(existingDictionary.map { TermMatcher.canonical($0) }.filter { !$0.isEmpty })
        var seen = Set<String>()
        var results: [CorrectionPair] = []

        for (observed, correctedWord) in subs {
            let observedTrim = observed.trimmingCharacters(in: .whitespacesAndNewlines)
            let correctedTrim = correctedWord.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !observedTrim.isEmpty, !correctedTrim.isEmpty else { continue }
            guard observedTrim.caseInsensitiveCompare(correctedTrim) != .orderedSame else { continue }
            guard correctedTrim.count >= 3 else { continue }

            let correctedKey = TermMatcher.canonical(correctedTrim)
            guard !correctedKey.isEmpty else { continue }
            if dictSet.contains(correctedKey) { continue }
            if seen.contains(correctedKey) { continue }

            let dist = editDistance(observedTrim.lowercased(), correctedTrim.lowercased())
            let maxLen = max(observedTrim.count, correctedTrim.count)
            guard maxLen > 0, Double(dist) / Double(maxLen) <= maxRelativeDistance else { continue }

            results.append(CorrectionPair(observed: observedTrim, corrected: correctedTrim))
            seen.insert(correctedKey)
        }

        return results
    }

    // MARK: - Tokenization

    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
            let stripped = stripEdgePunctuation(String(token))
            return stripped.isEmpty ? nil : stripped
        }
    }

    private static func stripEdgePunctuation(_ word: String) -> String {
        var s = word
        let lettersAndDigits = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        while let first = s.unicodeScalars.first, !lettersAndDigits.contains(first) {
            s = String(s.dropFirst())
        }
        while let last = s.unicodeScalars.last, !lettersAndDigits.contains(last) {
            s = String(s.dropLast())
        }
        return s
    }

    // MARK: - Word-level LCS alignment → substitutions

    static func findSubstitutions(origWords: [String], editedWords: [String]) -> [(String, String)] {
        let m = origWords.count
        let n = editedWords.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if origWords[i - 1].caseInsensitiveCompare(editedWords[j - 1]) == .orderedSame {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // aligned entries: (orig?, edit?)
        var aligned: [(String?, String?)] = []
        var i = m
        var j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0,
               origWords[i - 1].caseInsensitiveCompare(editedWords[j - 1]) == .orderedSame {
                aligned.insert((origWords[i - 1], editedWords[j - 1]), at: 0)
                i -= 1
                j -= 1
            } else if j > 0, i == 0 || dp[i][j - 1] >= dp[i - 1][j] {
                aligned.insert((nil, editedWords[j - 1]), at: 0)
                j -= 1
            } else {
                aligned.insert((origWords[i - 1], nil), at: 0)
                i -= 1
            }
        }

        // Consecutive [orig, nil] + [nil, edit] = substitution
        var subs: [(String, String)] = []
        var k = 0
        while k < aligned.count - 1 {
            let (origW, editW) = aligned[k]
            let (nextOrigW, nextEditW) = aligned[k + 1]
            if let origW, editW == nil, nextOrigW == nil, let nextEditW {
                subs.append((origW, nextEditW))
                k += 2
            } else {
                k += 1
            }
        }
        return subs
    }

    // MARK: - Levenshtein

    static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = Array(repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                if aChars[i - 1] == bChars[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + min(prev[j], curr[j - 1], prev[j - 1])
                }
            }
            prev = curr
        }
        return prev[n]
    }
}
