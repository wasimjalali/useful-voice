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
/// The set only ever grows (`absorb`). Rules rewrite the text as they go, and a rule later
/// in the list can match text an earlier rule just wrote, so the index must cover every
/// version of the text it has seen. Extra windows only cost an occasional needless regex.
struct LanguageMemoryTextIndex {
    /// The phrase side: the skeleton of the trimmed phrase.
    struct Signature {
        fileprivate let skeleton: [UInt32]
    }

    private var unigrams = Set<UInt32>()
    private var bigrams = Set<UInt64>()
    private var trigrams = Set<UInt64>()

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

    /// Adds every window of `text`'s skeleton to the index.
    mutating func absorb(_ text: String) {
        let s = Self.skeleton(of: text)
        guard !s.isEmpty else { return }
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

    /// False only when the regex for this phrase certainly finds nothing in any text the
    /// index has absorbed.
    func mayContain(_ signature: Signature) -> Bool {
        let p = signature.skeleton
        switch p.count {
        case 0:
            return true
        case 1:
            return unigrams.contains(p[0])
        case 2:
            return bigrams.contains(Self.pack(p[0], p[1]))
        default:
            for i in 0...(p.count - 3) where !trigrams.contains(Self.pack(p[i], p[i + 1], p[i + 2])) {
                return false
            }
            return true
        }
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
        var out: [UInt32] = []
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v < 0x80 {
                out.append(v >= 0x41 && v <= 0x5A ? v + 0x20 : v)
            } else {
                appendSkeleton(of: scalar, to: &out, depth: 0)
            }
        }
        return out
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
