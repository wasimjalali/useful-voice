import Foundation

public struct DictationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    /// A detected-code-or-requested-pin union: the raw detected code the
    /// provider returned, or the requested pin (which may be a request mode
    /// like `multi`) when detection is absent. Not guaranteed sendable — a
    /// regional tag like `de-DE` is stored verbatim for fidelity but must be
    /// validated (`LanguagePin(recordedCode:)`) before reuse as `language=`.
    public let language: String?

    /// The pin this dictation ran under, resolved from `language` — the value
    /// reprocessing must request so a record re-runs its own language's rules
    /// rather than whatever is pinned now. Nil when the record predates stored
    /// languages, leaving the caller's current-pin fallback in place.
    ///
    /// Kept on the record itself rather than resolved at each call site: the
    /// union semantics (a stored `multi` must re-send `language=multi`, a
    /// stored `de-DE` must scope as `de`, an unknown code must scope as
    /// `auto`) live in `LanguagePin(recordedCode:)`, and funnelling through
    /// here is what keeps both reprocess paths on the same rule.
    public var resolvedPin: LanguagePin? {
        language.map { LanguagePin(recordedCode: $0) }
    }
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
