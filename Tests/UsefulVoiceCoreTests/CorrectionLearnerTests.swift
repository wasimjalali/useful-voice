import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct CorrectionLearnerTests {
    @Test func testExtractsPhoneticWordSubstitution() {
        let pairs = CorrectionLearner.extractPairs(
            original: "Please deploy to kubernets today",
            corrected: "Please deploy to Kubernetes today"
        )
        #expect(pairs.count == 1)
        #expect(pairs[0].observed == "kubernets")
        #expect(pairs[0].corrected == "Kubernetes")
    }

    @Test func testIgnoresIdenticalText() {
        let pairs = CorrectionLearner.extractPairs(
            original: "Hello world",
            corrected: "Hello world"
        )
        #expect(pairs.isEmpty)
    }

    @Test func testIgnoresWholesaleRewrite() {
        let pairs = CorrectionLearner.extractPairs(
            original: "one two three four",
            corrected: "alpha beta gamma delta"
        )
        #expect(pairs.isEmpty)
    }

    @Test func testSkipsWordsAlreadyInDictionary() {
        let pairs = CorrectionLearner.extractPairs(
            original: "Use claude code please",
            corrected: "Use Claude Code please",
            existingDictionary: ["Claude", "Code"]
        )
        // "claude"→"Claude" and "code"→"Code" are case-only (filtered).
        #expect(pairs.isEmpty)
    }

    @Test func testEditDistanceBasic() {
        #expect(CorrectionLearner.editDistance("kitten", "sitting") == 3)
        #expect(CorrectionLearner.editDistance("cloud", "claude") == 2)
    }

    @Test func testAllowsOpenWhisprStylePhoneticThreshold() {
        // dist("Shunade","Sinead") / maxLen ≈ 0.57 ≤ 0.65
        let pairs = CorrectionLearner.extractPairs(
            original: "Hi Shunade",
            corrected: "Hi Sinead"
        )
        #expect(pairs.map(\.corrected) == ["Sinead"])
    }
}
