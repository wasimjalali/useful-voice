import Foundation
@testable import UsefulVoiceCore

/// Deterministic generator (SplitMix64), so the same seed gives the same corpus on every
/// machine and every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The benchmark corpus: a 15,149-character transcript (the size the September audit
/// used) and a dictionary of N terms with aliases, pronunciations and language scopes.
/// About a third of the terms are English-scoped, a third German-scoped and a third
/// language-neutral, so a detected `de` run uses about two thirds of them, as in the audit.
enum LanguageMemoryBenchCorpus {
    static let transcriptLength = 15_149

    private static let onsets = ["b", "br", "c", "ch", "cl", "d", "dr", "f", "fl", "g", "gr", "h", "j", "k", "kr", "l",
                                 "m", "n", "p", "pl", "pr", "r", "s", "sch", "sh", "sp", "st", "str", "t", "th", "tr",
                                 "v", "w", "z"]
    private static let nuclei = ["a", "e", "i", "o", "u", "ai", "ea", "ou", "au", "ei", "ie", "oo"]
    private static let codas = ["", "", "n", "r", "l", "s", "t", "d", "m", "k", "nd", "st", "ng", "rt", "ck"]
    private static let germanBits = ["ä", "ö", "ü", "ß", "tz", "sch", "ung", "keit", "ge", "ver"]

    static func word(_ rng: inout SplitMix64, german: Bool) -> String {
        var w = ""
        let syllables = Int.random(in: 1...3, using: &rng)
        for _ in 0..<syllables {
            w += onsets.randomElement(using: &rng)!
            w += nuclei.randomElement(using: &rng)!
            w += codas.randomElement(using: &rng)!
        }
        if german, Int.random(in: 0..<3, using: &rng) == 0 {
            w += germanBits.randomElement(using: &rng)!
        }
        return w
    }

    static func vocabulary(count: Int, seed: UInt64) -> [String] {
        var rng = SplitMix64(seed: seed)
        var seen = Set<String>()
        var out: [String] = []
        while out.count < count {
            let w = word(&rng, german: out.count % 3 == 0)
            if seen.insert(w).inserted { out.append(w) }
        }
        return out
    }

    /// Exactly `transcriptLength` characters of mixed English and German prose.
    static func transcript(seed: UInt64 = 1) -> String {
        var rng = SplitMix64(seed: seed)
        let vocab = vocabulary(count: 2_500, seed: 77)
        var out = ""
        var sentenceStart = true
        while out.count < transcriptLength {
            // Zipf-ish: low indexes are far more frequent.
            let r = Double.random(in: 0..<1, using: &rng)
            var w = vocab[min(vocab.count - 1, Int(pow(r, 2.6) * Double(vocab.count)))]
            if sentenceStart { w = w.prefix(1).uppercased() + w.dropFirst() }
            out += w
            sentenceStart = false
            switch Int.random(in: 0..<14, using: &rng) {
            case 0: out += ". "; sentenceStart = true
            case 1: out += ", "
            default: out += " "
            }
        }
        return String(out.prefix(transcriptLength))
    }

    /// `count` terms. About 8% reuse real phrases cut from the transcript (with different
    /// casing), so some rules and hits fire the way a lived-in dictionary does.
    static func terms(count: Int, transcript: String, seed: UInt64 = 5) -> [MemoryTerm] {
        var rng = SplitMix64(seed: seed)
        let words = transcript.split(whereSeparator: { " .,".contains($0) }).map(String.init)
        var terms: [MemoryTerm] = []
        var seen = Set<String>()
        var idCounter: UInt64 = 0
        func nextID() -> UUID {
            idCounter += 1
            return UUID(uuid: (UInt8(truncatingIfNeeded: idCounter >> 56), UInt8(truncatingIfNeeded: idCounter >> 48),
                               UInt8(truncatingIfNeeded: idCounter >> 40), UInt8(truncatingIfNeeded: idCounter >> 32),
                               UInt8(truncatingIfNeeded: idCounter >> 24), UInt8(truncatingIfNeeded: idCounter >> 16),
                               UInt8(truncatingIfNeeded: idCounter >> 8), UInt8(truncatingIfNeeded: idCounter),
                               1, 2, 3, 4, 5, 6, 7, 8))
        }
        while terms.count < count {
            let german = terms.count % 3 == 1
            var phrase: String
            if Int.random(in: 0..<100, using: &rng) < 8 {
                let start = Int.random(in: 0..<(words.count - 3), using: &rng)
                let n = Int.random(in: 1...2, using: &rng)
                phrase = words[start..<(start + n)].joined(separator: " ")
                phrase = Bool.random(using: &rng) ? phrase.capitalized : phrase.uppercased()
            } else {
                let n = Int.random(in: 1...3, using: &rng)
                phrase = (0..<n).map { _ in word(&rng, german: german) }.joined(separator: " ")
                if Bool.random(using: &rng) { phrase = phrase.capitalized }
                if Int.random(in: 0..<10, using: &rng) == 0 { phrase += "-\(Int.random(in: 2...9, using: &rng))" }
            }
            guard seen.insert(phrase.lowercased()).inserted else { continue }
            var aliases: [String] = []
            var pron: [String] = []
            for _ in 0..<Int.random(in: 0...2, using: &rng) {
                aliases.append((0..<Int.random(in: 1...2, using: &rng)).map { _ in word(&rng, german: german) }
                    .joined(separator: " "))
            }
            if Int.random(in: 0..<3, using: &rng) == 0 {
                pron.append(word(&rng, german: german) + " " + word(&rng, german: german))
            }
            let language: MemoryLanguage = terms.count % 3 == 0 ? .auto : (german ? .de : .en)
            terms.append(MemoryTerm(id: nextID(), phrase: phrase, pronunciations: pron, aliases: aliases,
                                    language: language))
        }
        return terms
    }

    /// A fixed id for the n-th object, so fingerprints agree across processes.
    static func fixedID(_ n: UInt64) -> UUID {
        UUID(uuid: (UInt8(truncatingIfNeeded: n >> 56), UInt8(truncatingIfNeeded: n >> 48),
                    UInt8(truncatingIfNeeded: n >> 40), UInt8(truncatingIfNeeded: n >> 32),
                    UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                    UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n),
                    9, 9, 9, 9, 9, 9, 9, 9))
    }

    static func snapshot(terms count: Int, transcript: String) -> LanguageMemorySnapshot {
        let terms = terms(count: count, transcript: transcript)
        var rng = SplitMix64(seed: 99)
        let words = transcript.split(whereSeparator: { " .,".contains($0) }).map(String.init)
        var replacements: [ReplacementRule] = []
        for n in 0..<50 {
            let heard = words[Int.random(in: 0..<words.count, using: &rng)]
            replacements.append(ReplacementRule(id: fixedID(1_000_000 + UInt64(n)), match: heard, replacement: heard.capitalized + "!"))
        }
        var snippets: [MemorySnippet] = []
        for i in 0..<20 {
            let w = words[Int.random(in: 0..<words.count, using: &rng)]
            snippets.append(MemorySnippet(id: fixedID(2_000_000 + UInt64(i)), trigger: "snip \(w)", expansion: "expansion \(i)"))
        }
        return LanguageMemorySnapshot(terms: terms, replacements: replacements, snippets: snippets)
    }

    /// FNV-1a over the result, so before/after runs can show they produced the same output.
    /// `DictionaryCorrector` mints a fresh random id for every synthetic rule on each call,
    /// so ids of rules outside `stableIDs` count as "synthetic" and only their position and
    /// number are hashed.
    static func fingerprint(_ r: LanguageMemoryProcessingResult, stableIDs: Set<UUID>) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: some Sequence<UInt8>) {
            for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            h = (h ^ 0xff) &* 0x100_0000_01b3
        }
        mix(Array(r.text.utf8))
        for id in r.replacementRuleIDs {
            mix(Array((stableIDs.contains(id) ? id.uuidString : "synthetic").utf8))
        }
        for id in r.memoryHitIDs + r.snippetIDs { mix(Array(id.uuidString.utf8)) }
        return String(h, radix: 16)
    }
}
