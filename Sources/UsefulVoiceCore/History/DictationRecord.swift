import Foundation

public struct DictationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let language: String?
    public let provider: String
    public let durationSeconds: Double?
    /// How the text was produced (raw or formatted). Optional so pre-mode
    /// history.json still decodes.
    public let mode: FormattingMode?
    /// Diagnostics added by the premium redesign. Optional so all older
    /// history.json files still decode.
    public let rawText: String?
    public let intermediateText: String?
    public let modelDeployment: String?
    public let memoryHitIDs: [UUID]?
    public let replacementRuleIDs: [UUID]?
    public let snippetIDs: [UUID]?
    /// Retained recording path for history reprocessing. Optional so older
    /// history files still decode, and because retention pruning can remove it.
    public let audioPath: String?

    public init(id: UUID = UUID(), text: String, createdAt: Date,
                language: String?, provider: String, durationSeconds: Double?,
                mode: FormattingMode? = nil,
                rawText: String? = nil,
                intermediateText: String? = nil,
                modelDeployment: String? = nil,
                memoryHitIDs: [UUID]? = nil,
                replacementRuleIDs: [UUID]? = nil,
                snippetIDs: [UUID]? = nil,
                audioPath: String? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.language = language
        self.provider = provider
        self.durationSeconds = durationSeconds
        self.mode = mode
        self.rawText = rawText
        self.intermediateText = intermediateText
        self.modelDeployment = modelDeployment
        self.memoryHitIDs = memoryHitIDs
        self.replacementRuleIDs = replacementRuleIDs
        self.snippetIDs = snippetIDs
        self.audioPath = audioPath
    }
}
