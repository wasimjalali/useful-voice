import Foundation

/// A prefilter that says, cheaply, "this phrase cannot be in this text", so the
/// word-boundary matcher can skip the regex scan for it.
///
/// Why: a lived-in dictionary has thousands of rules and term candidates, and each one
/// used to run its own ICU regex over the whole transcript on every dictation, for every
/// stage. Nearly all of them match nothing. This index answers "could it match?" with a
/// hash lookup instead.
///
/// The contract is one-sided, and that is what keeps output identical to the unindexed
/// matcher: `mayContain` may return true for a phrase that does not match (the caller then
/// runs the real regex, as before), but it never returns false for a phrase the regex would
/// match. A skipped phrase is therefore always one the regex would have left alone.
///
/// How it stays one-sided with ICU's case-insensitive matching. The regex compares
/// case-folded text, and folding can change length and merge scripts: "ß" matches "ss",
/// "ﬁ" matches "fi", the Kelvin sign matches "k", "ſ" matches "s", "İ" matches "i" plus a
/// combining dot. So both the phrase and the text are reduced to the same *skeleton*, one
/// scalar at a time: the full uppercase mapping, then the full lowercase mapping of that.
/// The skeleton is coarser than case folding (it also equates the dotless "ı" with "i",
/// for one), never finer, so a regex match implies the phrase's skeleton is a substring of
/// the text's skeleton. The index stores every 1-, 2- and 3-scalar window of the text's
/// skeleton; a phrase is checked by looking up its windows. Presence of all windows is
/// necessary, not sufficient, hence "may".
///
/// Two stages. The first looks the phrase's windows up in sets that only ever grow
/// (`absorb`): rules rewrite the text as they go, so those sets cover every version of the
/// text seen so far and answer in a few hash lookups, which is what disposes of the
/// thousands of phrases that are nowhere near the text. The second looks for the phrase's
/// skeleton in the skeleton of the *current* text, and refuses an occurrence flanked by an
/// ASCII letter, digit or underscore, which the regex's word boundaries would refuse too.
/// That one is exact about what the text holds now, so a phrase whose windows are all
/// present but never together costs a short array scan instead of a regex scan.
struct LanguageMemoryTextIndex {
    /// The phrase side: the skeleton of the trimmed phrase.
    struct Signature {
        fileprivate let skeleton: [UInt32]
    }

    private var unigrams = Set<UInt32>()
    private var bigrams = Set<UInt64>()
    private var trigrams = Set<UInt64>()
    /// The skeleton of the text as of the last `absorb`, and per entry whether it comes
    /// from an ASCII letter, digit or underscore (the only word characters whose status
    /// does not depend on the Unicode tables of the ICU in use).
    private var current: [UInt32] = []
    private var currentIsASCIIWord: [Bool] = []

    init(text: String) {
        absorb(text)
    }

    /// The signature of `phrase` as the regex would see it, or nil when the phrase is one
    /// the matcher refuses outright (empty, or longer than `maxPhraseLength`). Callers
    /// send nil through the unindexed path, which handles those cases.
    static func signature(for phrase: String) -> Signature? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= LanguageMemoryMatcher.maxPhraseLength else { return nil }
        return Signature(skeleton: skeleton(of: trimmed))
    }

    /// Makes `text` the current text and adds every window of its skeleton to the index.
    mutating func absorb(_ text: String) {
        (current, currentIsASCIIWord) = Self.skeletonWithWordFlags(of: text)
        let s = current
        for i in 0..<s.count {
            unigrams.insert(s[i])
            if i + 1 < s.count {
                bigrams.insert(Self.pack(s[i], s[i + 1]))
                if i + 2 < s.count {
                    trigrams.insert(Self.pack(s[i], s[i + 1], s[i + 2]))
                }
            }
        }
    }

    /// False only when the regex for this phrase certainly finds nothing in the current
    /// text. (Stage one alone speaks for every text absorbed so far; see above.)
    func mayContain(_ signature: Signature) -> Bool {
        let p = signature.skeleton
        switch p.count {
        case 0:
            return true
        case 1:
            if !unigrams.contains(p[0]) { return false }
        case 2:
            if !bigrams.contains(Self.pack(p[0], p[1])) { return false }
        default:
            for i in 0...(p.count - 3) where !trigrams.contains(Self.pack(p[i], p[i + 1], p[i + 2])) {
                return false
            }
        }
        return occursInCurrentText(p)
    }

    private func occursInCurrentText(_ p: [UInt32]) -> Bool {
        let n = current.count
        let m = p.count
        guard m <= n else { return false }
        let first = p[0]
        var i = 0
        while i <= n - m {
            if current[i] == first {
                var j = 1
                while j < m && current[i + j] == p[j] { j += 1 }
                if j == m {
                    let leftBlocked = i > 0 && currentIsASCIIWord[i - 1]
                    let rightBlocked = i + m < n && currentIsASCIIWord[i + m]
                    if !leftBlocked && !rightBlocked { return true }
                }
            }
            i += 1
        }
        return false
    }

    // Scalars are at most 0x10FFFF, which fits in 21 bits; three of them fit in a UInt64.
    private static func pack(_ a: UInt32, _ b: UInt32) -> UInt64 {
        UInt64(a) << 21 | UInt64(b)
    }

    private static func pack(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt64 {
        UInt64(a) << 42 | UInt64(b) << 21 | UInt64(c)
    }

    /// Uppercase then lowercase, per scalar, using the context-free full mappings (the
    /// regex has no context either), repeated until the scalar stops changing. One round is
    /// not enough: "ẞ" lowercases to "ß", which is not yet "ss", although the regex treats
    /// all three as the same letters. ASCII and scalars no case mapping touches take the
    /// fast path.
    static func skeleton(of text: String) -> [UInt32] {
        skeletonWithWordFlags(of: text).skeleton
    }

    static func skeletonWithWordFlags(of text: String) -> (skeleton: [UInt32], isASCIIWord: [Bool]) {
        var out: [UInt32] = []
        var flags: [Bool] = []
        out.reserveCapacity(text.utf8.count)
        flags.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v < 0x80 {
                out.append(v >= 0x41 && v <= 0x5A ? v + 0x20 : v)
                flags.append((v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x5F)
            } else {
                let before = out.count
                appendSkeleton(of: scalar, to: &out, depth: 0)
                flags.append(contentsOf: repeatElement(false, count: out.count - before))
            }
        }
        return (out, flags)
    }

    private static func appendSkeleton(of scalar: Unicode.Scalar, to out: inout [UInt32], depth: Int) {
        let props = scalar.properties
        guard depth < 4, props.changesWhenCaseMapped || props.changesWhenCaseFolded else {
            out.append(scalar.value)
            return
        }
        for upper in props.uppercaseMapping.unicodeScalars {
            for lower in upper.properties.lowercaseMapping.unicodeScalars {
                if lower == scalar {
                    out.append(lower.value)
                } else {
                    appendSkeleton(of: lower, to: &out, depth: depth + 1)
                }
            }
        }
    }
}
