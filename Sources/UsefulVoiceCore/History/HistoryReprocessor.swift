import Foundation

public struct HistoryReprocessResult: Equatable, Sendable {
    public let original: DictationRecord
    public let reprocessed: DictationRecord?
    public let errorMessage: String?

    public init(original: DictationRecord,
                reprocessed: DictationRecord?,
                errorMessage: String?) {
        self.original = original
        self.reprocessed = reprocessed
        self.errorMessage = errorMessage
    }
}

public enum HistoryReprocessor {
    public static func reprocess(
        record: DictationRecord,
        now: Date = Date(),
        transform: () async throws -> FormattingResult
    ) async -> HistoryReprocessResult {
        do {
            let result = try await transform()
            let next = DictationRecord(
                text: result.text,
                createdAt: now,
                language: record.language,
                provider: record.provider,
                durationSeconds: record.durationSeconds,
                mode: result.mode,
                rawText: record.rawText ?? record.text,
                intermediateText: record.text,
                modelDeployment: record.modelDeployment,
                memoryHitIDs: result.memoryHitIDs.isEmpty ? nil : result.memoryHitIDs,
                replacementRuleIDs: result.replacementRuleIDs.isEmpty ? nil : result.replacementRuleIDs,
                snippetIDs: result.snippetIDs.isEmpty ? nil : result.snippetIDs,
                audioPath: record.audioPath
            )
            return HistoryReprocessResult(original: record, reprocessed: next, errorMessage: nil)
        } catch {
            return HistoryReprocessResult(
                original: record,
                reprocessed: nil,
                errorMessage: error.localizedDescription
            )
        }
    }

    public static func reprocessAudio(
        record: DictationRecord,
        audioURL: URL,
        now: Date = Date(),
        providerName: String,
        transcribe: (URL) async throws -> Transcript,
        format: (String) async throws -> FormattingResult
    ) async -> HistoryReprocessResult {
        do {
            let transcript = try await transcribe(audioURL)
            let result = try await format(transcript.text)
            let next = DictationRecord(
                text: result.text,
                createdAt: now,
                language: transcript.detectedLanguage ?? record.language,
                provider: providerName,
                durationSeconds: transcript.durationSeconds ?? record.durationSeconds,
                mode: result.mode,
                rawText: transcript.text,
                intermediateText: record.text,
                modelDeployment: record.modelDeployment,
                memoryHitIDs: result.memoryHitIDs.isEmpty ? nil : result.memoryHitIDs,
                replacementRuleIDs: result.replacementRuleIDs.isEmpty ? nil : result.replacementRuleIDs,
                snippetIDs: result.snippetIDs.isEmpty ? nil : result.snippetIDs,
                audioPath: audioURL.path
            )
            return HistoryReprocessResult(original: record, reprocessed: next, errorMessage: nil)
        } catch {
            return HistoryReprocessResult(
                original: record,
                reprocessed: nil,
                errorMessage: error.localizedDescription
            )
        }
    }
}
