import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct HistoryReprocessorTests {
    @Test func testFailureDoesNotMutateOriginalRecord() async {
        let record = DictationRecord(text: "old", createdAt: Date(), language: nil,
                                     provider: "test", durationSeconds: 1)
        let result = await HistoryReprocessor.reprocess(record: record) {
            throw ProviderError.badResponse
        }
        #expect(result.original == record)
        #expect(result.reprocessed == nil)
        #expect(result.errorMessage != nil)
    }

    @Test func testSuccessCreatesNewRecordAndPreservesOriginal() async {
        let ruleID = UUID()
        let memoryID = UUID()
        let snippetID = UUID()
        let record = DictationRecord(text: "cloud code", createdAt: Date(timeIntervalSince1970: 1),
                                     language: "en", provider: "Azure", durationSeconds: 2)
        let result = await HistoryReprocessor.reprocess(
            record: record,
            now: Date(timeIntervalSince1970: 2)
        ) {
            FormattingResult(text: "Claude Code", newTerms: [],
                             mode: .raw, replacementRuleIDs: [ruleID],
                             memoryHitIDs: [memoryID],
                             snippetIDs: [snippetID])
        }

        #expect(result.original == record)
        #expect(result.reprocessed?.text == "Claude Code")
        #expect(result.reprocessed?.rawText == "cloud code")
        #expect(result.reprocessed?.replacementRuleIDs == [ruleID])
        #expect(result.reprocessed?.memoryHitIDs == [memoryID])
        #expect(result.reprocessed?.snippetIDs == [snippetID])
    }

    @Test func testAudioReprocessCreatesRecordFromFreshTranscript() async {
        let audioURL = URL(fileURLWithPath: "/tmp/sadaa-test.wav")
        let memoryID = UUID()
        let snippetID = UUID()
        let record = DictationRecord(
            text: "old text",
            createdAt: Date(timeIntervalSince1970: 1),
            language: "en",
            provider: "Azure",
            durationSeconds: 2,
            audioPath: audioURL.path
        )

        let result = await HistoryReprocessor.reprocessAudio(
            record: record,
            audioURL: audioURL,
            now: Date(timeIntervalSince1970: 3),
            providerName: "Azure reprocess",
            transcribe: { url in
                #expect(url == audioURL)
                return Transcript(text: "fresh raw", detectedLanguage: "en", durationSeconds: 4)
            },
            format: { raw in
                #expect(raw == "fresh raw")
                return FormattingResult(text: "Fresh raw.", newTerms: [], mode: .formatted,
                                        memoryHitIDs: [memoryID],
                                        snippetIDs: [snippetID])
            }
        )

        #expect(result.original == record)
        #expect(result.reprocessed?.text == "Fresh raw.")
        #expect(result.reprocessed?.rawText == "fresh raw")
        #expect(result.reprocessed?.intermediateText == "old text")
        #expect(result.reprocessed?.audioPath == audioURL.path)
        #expect(result.reprocessed?.provider == "Azure reprocess")
        #expect(result.reprocessed?.durationSeconds == 4)
        #expect(result.reprocessed?.memoryHitIDs == [memoryID])
        #expect(result.reprocessed?.snippetIDs == [snippetID])
    }
}
