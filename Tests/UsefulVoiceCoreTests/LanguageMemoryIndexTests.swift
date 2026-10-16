import Foundation
import Testing
@testable import UsefulVoiceCore

/// The indexed Language Memory matcher against the old matcher (`LegacyLanguageMemory`,
/// the code as it was before the index) over random dictionaries and texts. The two must
/// agree on everything: the text, the rules that fired, the term hits, the snippets.
@Suite(.serialized) struct LanguageMemoryIndexTests {
    // MARK: - Scenario generator

    /// Pieces that stress the matcher: case folding that changes length, other scripts,
    /// composed and decomposed accents, regex metacharacters, joiners and spaces.
    static let atoms: [String] = [
        "claude", "Claude", "code", "cloud", "teh", "the", "cat", "a", "I", "AI", "PR", "api", "x",
        "useful", "voice", "acme", "inc", "new", "york", "newyork",
        "straße", "STRASSE", "Strasse", "strasse", "ß", "ẞ", "SS", "ss", "s", "ſ", "weiß", "größe", "GRÖSSE",
        "ﬁnal", "final", "ﬂow", "flow", "ﬃ", "ffi", "office", "oﬃce",
        "K", "k", "kelvin", "Kelvin",
        "İstanbul", "istanbul", "ISTANBUL", "ıı", "ii", "I",
        "ΣΊΣΥΦΟΣ", "σίσυφος", "ς", "σ", "Σ", "οδός", "ΟΔΟΣ",
        "привет", "Привет", "ПРИВЕТ", "мир", "Ёлка", "ёлка",
        "東京", "ありがとう", "ｱｲｳ", "Ǆ", "ǆ", "ǅ", "ŉ", "ʼn",
        "café", "cafe\u{301}", "CAFÉ", "Cafe\u{301}", "naïve", "nai\u{308}ve", "ü", "u\u{308}", "Ü",
        "🙂", "👍🏽", "a\u{200D}b", "x\u{FE0F}",
        "C++", "c++", "gpt-4o", "GPT-4O", "a.b", "(x)", "[y]", "$1", "\\", "\\d", "*", "a+b", "q?", "^z", "p|q", "{2}",
        "a/b", "#tag", "&co", "O'Neil", "o\u{2019}neil", "snake_case", "100%", "€5", "e-mail", "a_b", "1,000",
        "123", "v2", "2fast", "ü2",
    ]

    static let separators = [" ", " ", " ", " ", ", ", ". ", "\n", "\t", "  ", " - ", "\u{00A0}", "\u{3000}", "", ":", "(", ")"]

    static let languages: [MemoryLanguage] = [.auto, .auto, .en, .de, MemoryLanguage(rawValue: "ja"), MemoryLanguage(rawValue: "tr")]

    struct Scenario {
        var terms: [MemoryTerm]
        var rules: [ReplacementRule]
        var snippets: [MemorySnippet]
        var text: String
        var language: MemoryLanguage
        var snapshot: LanguageMemorySnapshot {
            LanguageMemorySnapshot(terms: terms, replacements: rules, snippets: snippets)
        }
        var stableIDs: Set<UUID> {
            Set(rules.map(\.id) + terms.map(\.id) + snippets.map(\.id))
        }
    }

    static func recase(_ s: String, _ rng: inout SplitMix64) -> String {
        switch Int.random(in: 0..<8, using: &rng) {
        case 0: return s.lowercased()
        case 1: return s.uppercased()
        case 2: return s.capitalized
        case 3: return s.map { Bool.random(using: &rng) ? $0.uppercased() : $0.lowercased() }.joined()
        case 4: return s.decomposedStringWithCanonicalMapping
        case 5: return s.precomposedStringWithCanonicalMapping
        default: return s
        }
    }

    static func phrase(_ rng: inout SplitMix64) -> String {
        var out = ""
        for i in 0..<Int.random(in: 1...3, using: &rng) {
            if i > 0 { out += separators.randomElement(using: &rng)! }
            out += atoms.randomElement(using: &rng)!
        }
        switch Int.random(in: 0..<20, using: &rng) {
        case 0: out = "  " + out + " \n"
        case 1: out = ""
        case 2: out = String(repeating: "word ", count: 50)  // longer than the matcher accepts
        default: break
        }
        return out
    }

    static func scenario(seed: UInt64, size: Int) -> Scenario {
        var rng = SplitMix64(seed: seed &* 0x9E37_79B9 &+ 17)
        let termCount = Int.random(in: 0...size, using: &rng)
        var terms: [MemoryTerm] = []
        var heard: [String] = []
        for _ in 0..<termCount {
            let p = phrase(&rng)
            let aliases = (0..<Int.random(in: 0...2, using: &rng)).map { _ in phrase(&rng) }
            let prons = (0..<Int.random(in: 0...1, using: &rng)).map { _ in phrase(&rng) }
            heard.append(contentsOf: [p] + aliases + prons)
            terms.append(MemoryTerm(phrase: p, pronunciations: prons, aliases: aliases,
                                    language: languages.randomElement(using: &rng)!))
        }
        var rules: [ReplacementRule] = []
        for _ in 0..<Int.random(in: 0...(size / 2 + 1), using: &rng) {
            let match = Bool.random(using: &rng) && !heard.isEmpty ? heard.randomElement(using: &rng)! : phrase(&rng)
            var replacement = Bool.random(using: &rng) ? phrase(&rng) : match + " " + atoms.randomElement(using: &rng)!
            if Int.random(in: 0..<10, using: &rng) == 0 { replacement = "$0 \\1 $&" }
            let mode: ReplacementMatchMode
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: mode = .exactPhrase
            case 1: mode = .caseInsensitivePhrase
            default: mode = .wordBoundaryPhrase
            }
            rules.append(ReplacementRule(match: match, replacement: replacement, matchMode: mode,
                                         language: languages.randomElement(using: &rng)!,
                                         isEnabled: Int.random(in: 0..<12, using: &rng) != 0))
        }
        var snippets: [MemorySnippet] = []
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            let trigger = Bool.random(using: &rng) && !heard.isEmpty ? heard.randomElement(using: &rng)! : phrase(&rng)
            snippets.append(MemorySnippet(trigger: trigger, expansion: phrase(&rng),
                                          language: languages.randomElement(using: &rng)!,
                                          isEnabled: Int.random(in: 0..<10, using: &rng) != 0))
        }
        var text = ""
        for _ in 0..<Int.random(in: 0...60, using: &rng) {
            let piece: String
            if !heard.isEmpty && Int.random(in: 0..<3, using: &rng) == 0 {
                piece = recase(heard.randomElement(using: &rng)!, &rng)
            } else {
                piece = recase(atoms.randomElement(using: &rng)!, &rng)
            }
            // Sometimes glue pieces together so word boundaries have to hold.
            text += piece + (Int.random(in: 0..<6, using: &rng) == 0 ? "" : separators.randomElement(using: &rng)!)
        }
        return Scenario(terms: terms, rules: rules, snippets: snippets, text: text,
                        language: languages.randomElement(using: &rng)!)
    }

    /// Rule ids that are not the caller's own are minted fresh on every call, so only their
    /// position and number can be compared.
    static func normalized(_ ids: [UUID], stable: Set<UUID>) -> [String] {
        ids.map { stable.contains($0) ? $0.uuidString : "synthetic" }
    }

    static var caseCount: Int {
        Int(ProcessInfo.processInfo.environment["UV_LM_DIFF_CASES"] ?? "") ?? 250
    }

    // MARK: - Differential tests

    @Test func testReplacementEngineMatchesLegacyOnRandomRuleSets() {
        var differences = 0
        for seed in 0..<UInt64(Self.caseCount) {
            let size = [4, 12, 40, 120][Int(seed % 4)]
            let s = Self.scenario(seed: seed, size: size)
            let expected = LegacyLanguageMemory.applyRules(s.rules, to: s.text, language: s.language)
            for threshold in [0, ReplacementEngine.indexMinRules, Int.max] {
                let actual = ReplacementEngine.apply(s.rules, to: s.text, language: s.language, indexMinRules: threshold)
                if actual != expected {
                    differences += 1
                    Issue.record("seed \(seed) size \(size) threshold \(threshold): \(actual) != \(expected) for \(s.text.debugDescription)")
                    if differences > 5 { return }
                }
            }
        }
        #expect(differences == 0)
    }

    @Test func testMatchingTermIDsMatchesLegacyOnRandomDictionaries() {
        var differences = 0
        var skippedByIndex = 0
        for seed in 0..<UInt64(Self.caseCount) {
            let size = [4, 12, 40, 120][Int(seed % 4)]
            let s = Self.scenario(seed: seed &+ 1_000_000, size: size)
            let texts = [s.text, s.text.uppercased(), "", String(s.text.prefix(20))]
            for threshold in [0, LanguageMemoryMatcher.indexMinCandidates, Int.max] {
                let actual = LanguageMemoryMatcher.matchingTermIDs(s.terms, inTexts: texts, language: s.language,
                                                                   indexMinCandidates: threshold)
                for (i, text) in texts.enumerated() {
                    let expected = LegacyLanguageMemory.matchingTermIDs(s.terms, in: text, language: s.language)
                    if actual[i] != expected {
                        differences += 1
                        Issue.record("seed \(seed) threshold \(threshold) text \(i): hit lists differ for \(text.debugDescription)")
                    }
                }
            }
            if LanguageMemoryMatcher.matchingTermIDs(s.terms, in: s.text, language: s.language)
                != LegacyLanguageMemory.matchingTermIDs(s.terms, in: s.text, language: s.language) {
                differences += 1
            }
            // The phrases the index rules out for this text are the regex scans the indexed
            // configuration skips; counting them keeps the assertion below from being vacuous.
            let index = LanguageMemoryTextIndex(text: s.text)
            for term in s.terms {
                for phrase in [term.phrase] + term.aliases + term.pronunciations {
                    if let signature = LanguageMemoryTextIndex.signature(for: phrase), !index.mayContain(signature) {
                        skippedByIndex += 1
                    }
                }
            }
            if differences > 5 { return }
        }
        #expect(differences == 0)
        #expect(skippedByIndex > 0)
    }

    @Test func testApplyDeterministicMatchesLegacyOnRandomMemory() {
        var differences = 0
        for seed in 0..<UInt64(Self.caseCount) {
            let size = [4, 12, 40, 120][Int(seed % 4)]
            let s = Self.scenario(seed: seed &+ 2_000_000, size: size)
            let expected = LegacyLanguageMemory.applyDeterministic(to: s.text, snapshot: s.snapshot, language: s.language)
            let actual = LanguageMemoryPostProcessor.applyDeterministic(to: s.text, snapshot: s.snapshot, language: s.language)
            let same = actual.text.utf8.elementsEqual(expected.text.utf8)
                && Self.normalized(actual.replacementRuleIDs, stable: s.stableIDs)
                    == Self.normalized(expected.replacementRuleIDs, stable: s.stableIDs)
                && actual.memoryHitIDs == expected.memoryHitIDs
                && actual.snippetIDs == expected.snippetIDs
            if !same {
                differences += 1
                Issue.record("seed \(seed) size \(size): \(actual) != \(expected) for \(s.text.debugDescription)")
                if differences > 5 { return }
            }
        }
        #expect(differences == 0)
    }

    // MARK: - The index never says "no" to a phrase the regex finds

    @Test func testIndexNeverRejectsAPhraseTheRegexMatches() {
        var matched = 0
        var rejected = 0
        for seed in 0..<UInt64(Self.caseCount) {
            let s = Self.scenario(seed: seed &+ 3_000_000, size: 40)
            let texts = [s.text, s.text.uppercased(), s.text.lowercased()]
            for text in texts {
                let index = LanguageMemoryTextIndex(text: text)
                for term in s.terms {
                    for phrase in [term.phrase] + term.aliases + term.pronunciations {
                        guard let signature = LanguageMemoryTextIndex.signature(for: phrase) else { continue }
                        let regexMatches = LegacyLanguageMemory.containsWordBoundaryPhrase(phrase, in: text)
                        let mayContain = index.mayContain(signature)
                        if regexMatches {
                            matched += 1
                            if !mayContain {
                                let ns = text as NSString
                                let found = LanguageMemoryMatcher.wordBoundaryRegex(for: phrase)!
                                    .firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
                                    .map { ns.substring(with: $0.range) } ?? ""
                                Issue.record("index rejected \(phrase.unicodeScalars.map { String($0.value, radix: 16) }) but the regex found \(found.unicodeScalars.map { String($0.value, radix: 16) })")
                            }
                        } else if !mayContain {
                            rejected += 1
                        }
                    }
                }
            }
        }
        #expect(matched > 100)
        #expect(rejected > 100)
    }

    /// Case folding by ICU, checked scalar by scalar against the skeleton the index uses:
    /// whatever a (case-insensitive, word-boundary) regex for one letter or letter pair
    /// matches, the index must say it may contain.
    @Test func testIndexSkeletonCoversEveryCaseFoldingTheRegexKnows() {
        var cased: [Unicode.Scalar] = []
        for v in UInt32(0x20)...UInt32(0x1_FFFF) {
            guard let scalar = Unicode.Scalar(v) else { continue }
            let p = scalar.properties
            if p.changesWhenCaseMapped || p.changesWhenCaseFolded || p.isCased { cased.append(scalar) }
        }
        #expect(cased.count > 2000)
        // Every cased scalar, each in its own space-separated slot, so the production
        // word-boundary regex sees it as a word.
        let slots = cased.map { String($0) }
        let haystack = " " + slots.joined(separator: " ") + " "

        var patterns = Set<String>()
        for a in UInt32(0x61)...UInt32(0x7A) {
            let one = String(Unicode.Scalar(a)!)
            patterns.insert(one)
            for b in UInt32(0x61)...UInt32(0x7A) { patterns.insert(one + String(Unicode.Scalar(b)!)) }
        }
        for extra in ["ffi", "ffl", "fff", "sss", "ssi", "ist", "ij", "ǆ", "ss", "st", "fi", "fl", "ff"] { patterns.insert(extra) }
        for scalar in cased {
            patterns.insert(String(scalar))
            patterns.insert(scalar.properties.lowercaseMapping)
            patterns.insert(scalar.properties.uppercaseMapping)
            patterns.insert(scalar.properties.titlecaseMapping)
        }

        var checked = 0
        var failures: [String] = []
        let nsHaystack = haystack as NSString
        for pattern in patterns {
            guard let signature = LanguageMemoryTextIndex.signature(for: pattern),
                  let regex = LanguageMemoryMatcher.wordBoundaryRegex(for: pattern) else { continue }
            for match in regex.matches(in: haystack, range: NSRange(location: 0, length: nsHaystack.length)) {
                let found = nsHaystack.substring(with: match.range)
                checked += 1
                if !LanguageMemoryTextIndex(text: found).mayContain(signature) {
                    failures.append("\(pattern.unicodeScalars.map { String($0.value, radix: 16) }) matches \(found.unicodeScalars.map { String($0.value, radix: 16) })")
                }
            }
        }
        #expect(checked > 3000)
        #expect(failures.isEmpty, "\(failures.prefix(10))")
    }

    /// `absorb` re-derives only the stretch of text that changed. After any sequence of
    /// edits its view of the text must equal a fresh build's, and every window of every
    /// version it has seen must still be in its sets.
    @Test func testIncrementallyUpdatedIndexEqualsAFreshOne() {
        let pieces = ["ab", "ß", "ﬁ", "🙂", "K", "İ", " ", "x\u{301}", "Σ", "cafe", "e\u{301}", "", "Ǆ"]
        for seed in 0..<UInt64(Self.caseCount) {
            var rng = SplitMix64(seed: seed &+ 4_000_000)
            func randomText(_ n: Int) -> [String] {
                (0..<n).map { _ in pieces.randomElement(using: &rng)! }
            }
            var units = randomText(Int.random(in: 0...30, using: &rng))
            var index = LanguageMemoryTextIndex(text: units.joined())
            var seen = [LanguageMemoryTextIndex.skeleton(of: units.joined())]
            for step in 0..<8 {
                let from = Int.random(in: 0...units.count, using: &rng)
                let to = min(units.count, from + Int.random(in: 0...4, using: &rng))
                units.replaceSubrange(from..<to, with: randomText(Int.random(in: 0...3, using: &rng)))
                let text = units.joined()
                index.absorb(text)
                let fresh = LanguageMemoryTextIndex.skeletonWithWordFlags(of: text.unicodeScalars)
                #expect(index.currentSkeleton.skeleton == fresh.skeleton, "seed \(seed) step \(step)")
                #expect(index.currentSkeleton.isASCIIWord == fresh.isASCIIWord, "seed \(seed) step \(step)")
                seen.append(fresh.skeleton)
                for skeleton in seen {
                    for i in 0..<skeleton.count {
                        for len in 1...3 where i + len <= skeleton.count {
                            let probe = LanguageMemoryTextIndex.Signature(skeleton: Array(skeleton[i..<(i + len)]))
                            if !index.windowsPresent(probe) {
                                Issue.record("seed \(seed) step \(step): window lost")
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Targeted cases

    private func agree(_ rules: [ReplacementRule], _ text: String, _ language: MemoryLanguage = .auto,
                       sourceLocation: SourceLocation = #_sourceLocation) {
        let expected = LegacyLanguageMemory.applyRules(rules, to: text, language: language)
        for threshold in [0, Int.max, ReplacementEngine.indexMinRules] {
            let actual = ReplacementEngine.apply(rules, to: text, language: language, indexMinRules: threshold)
            #expect(actual == expected, "threshold \(threshold) for \(text.debugDescription)", sourceLocation: sourceLocation)
        }
    }

    @Test func testCascadeInsideOnePassReachesLaterRules() {
        // "teh cat" -> "the cat" is written by the first rule; the second only matches that.
        let rules = [
            ReplacementRule(match: "teh", replacement: "the"),
            ReplacementRule(match: "the cat", replacement: "a cat"),
        ]
        agree(rules, "teh cat sat")
        let out = ReplacementEngine.apply(rules, to: "teh cat sat", language: .auto, indexMinRules: 0)
        #expect(out.text == "a cat sat")
        #expect(out.appliedRuleIDs == rules.map(\.id))
    }

    @Test func testRuleLaterInTheListCanMatchTextAnEarlierRuleWrote() {
        let rules = [
            ReplacementRule(match: "zebra", replacement: "ZEBRA"),
            ReplacementRule(match: "alpha", replacement: "zebra"),
        ]
        agree(rules, "alpha and zebra")
    }

    @Test func testCanonicallyEqualRewriteStillFeedsTheIndex() {
        // The first rule rewrites NFC "é" to NFD "é": Swift calls the strings equal, so the
        // rule does not count as applied, but the bytes changed and the second rule matches
        // only the new bytes.
        let nfc = "caf\u{E9}"
        let nfd = "cafe\u{301}"
        let rules = [
            ReplacementRule(match: nfc, replacement: nfd),
            ReplacementRule(match: nfd, replacement: "coffee"),
        ]
        agree(rules, "un caf\u{E9} noir")
    }

    @Test func testFoldingThatChangesLength() {
        for (match, text) in [("straße", "STRASSE"), ("STRASSE", "straße"), ("ss", "ß"), ("ß", "SS"), ("ẞ", "ss"),
                              ("ß", "ẞ"), ("ﬁ", "fi"), ("fi", "ﬁ"), ("office", "oﬃce"), ("k", "\u{212A}"),
                              ("\u{212A}", "k"), ("s", "ſ"), ("istanbul", "İstanbul"), ("σ", "ς"), ("ς", "Σ"),
                              ("ǆ", "ǅ"), ("ʼn", "ŉ"), ("ΟΔΟΣ", "οδός")] {
            agree([ReplacementRule(match: match, replacement: "<\(match)>")], "x \(text) y")
        }
    }

    /// A scalar the Unicode tables do not assign could be case-mapped by a newer ICU than
    /// the tables the skeleton was built from, so the index must not rule anything out for
    /// it: the text goes to the regex, and a phrase containing one is not indexed at all.
    @Test func testUnassignedScalarsAreWildcards() {
        let unassigned: [Unicode.Scalar] = ["\u{0378}", "\u{FFFF}", "\u{10FFFF}"]
        for scalar in unassigned {
            #expect(LanguageMemoryTextIndex.isUncertain(scalar))
        }
        #expect(!LanguageMemoryTextIndex.isUncertain("a"))
        #expect(!LanguageMemoryTextIndex.isUncertain("é"))

        let plain = LanguageMemoryTextIndex(text: "hello world")
        let withUnassigned = LanguageMemoryTextIndex(text: "hello \u{0378} world")
        let probe = LanguageMemoryTextIndex.signature(for: "zzz")!
        #expect(!plain.mayContain(probe))
        #expect(withUnassigned.mayContain(probe))
        #expect(withUnassigned.windowsPresent(probe))

        // The wildcard is sticky: later versions of the text keep it, since the windows
        // of every version are in the sets.
        var rewritten = LanguageMemoryTextIndex(text: "hello \u{0378} world")
        rewritten.absorb("hello world")
        #expect(rewritten.mayContain(probe))

        for scalar in unassigned {
            #expect(LanguageMemoryTextIndex.signature(for: "ab\(scalar)cd") == nil)
        }

        for scalar in unassigned {
            agree([ReplacementRule(match: "zzz", replacement: "R"),
                   ReplacementRule(match: "world", replacement: "W\(scalar)")],
                  "hello \(scalar) world zzz")
            agree([ReplacementRule(match: "x\(scalar)y", replacement: "R")], "a x\(scalar)y b")
        }
    }

    @Test func testShortPhrasesAndMetacharactersAgree() {
        for match in ["a", "AI", "x", "C++", "a.b", "(x)", "[y]", "$1", "\\", "*", "a+b", "q?", "^z", "p|q", "{2}", "a/b"] {
            agree([ReplacementRule(match: match, replacement: "R")], "a AI x C++ a.b (x) [y] $1 \\ * a+b q? ^z p|q {2} a/b ax")
        }
    }

    @Test func testDisabledEmptyAndOverlongRulesAreLeftAlone() {
        let long = String(repeating: "abc ", count: 100)
        let rules = [
            ReplacementRule(match: "", replacement: "x"),
            ReplacementRule(match: "  ", replacement: "x"),
            ReplacementRule(match: long, replacement: "x"),
            ReplacementRule(match: "abc", replacement: "x", isEnabled: false),
            ReplacementRule(match: "abc", replacement: "ABC", language: .de),
        ]
        agree(rules, long, .en)
        agree(rules, long, .de)
    }

    @Test func testSecondPassStillCatchesWhatSnippetsIntroduce() {
        let snapshot = LanguageMemorySnapshot(
            terms: (0..<30).map { MemoryTerm(phrase: "Term\($0)", aliases: ["alias\($0)"]) } + [MemoryTerm(phrase: "Acme AI", aliases: ["acme"])],
            replacements: [ReplacementRule(match: "boilerplate", replacement: "acme")],
            snippets: [MemorySnippet(trigger: "sig", expansion: "boilerplate here")]
        )
        let text = "please add sig and alias7 and Acme"
        let expected = LegacyLanguageMemory.applyDeterministic(to: text, snapshot: snapshot, language: .auto)
        let actual = LanguageMemoryPostProcessor.applyDeterministic(to: text, snapshot: snapshot, language: .auto)
        #expect(actual.text == expected.text)
        #expect(actual.memoryHitIDs == expected.memoryHitIDs)
        #expect(actual.snippetIDs == expected.snippetIDs)
        #expect(actual.replacementRuleIDs.count == expected.replacementRuleIDs.count)
    }

    @Test func testDuplicateTermIDsAreReportedOnce() {
        let id = UUID()
        let terms = [MemoryTerm(id: id, phrase: "foo"), MemoryTerm(id: id, phrase: "bar")]
        let expected = LegacyLanguageMemory.matchingTermIDs(terms, in: "foo bar")
        #expect(expected == [id])
        for threshold in [0, Int.max] {
            #expect(LanguageMemoryMatcher.matchingTermIDs(terms, inTexts: ["foo bar"], indexMinCandidates: threshold) == [[id]])
        }
    }
}
