import Foundation

public struct ScratchpadNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var body: String
    public var tags: [String]
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastOpenedAt: Date?

    public init(id: UUID = UUID(),
                title: String,
                body: String,
                tags: [String] = [],
                isPinned: Bool = false,
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                lastOpenedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.tags = tags
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOpenedAt = lastOpenedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, tags, isPinned, createdAt, updatedAt, lastOpenedAt
    }

    /// Tolerant decoding: files written before `updatedAt`/`isPinned`/`tags`
    /// existed still load, with `updatedAt` falling back to `createdAt` so an
    /// older note is never treated as newer than a local edit. Decoding an
    /// older file must never fail on a missing field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        let created = try container.decode(Date.self, forKey: .createdAt)
        createdAt = created
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
    }

    public var wordCount: Int {
        Self.wordCount(in: body)
    }

    public var characterCount: Int {
        body.count
    }

    public static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

public struct ScratchpadImportResult: Equatable, Sendable {
    public let inserted: Int
    public let updated: Int
    /// Incoming records that matched a local note but were older, so the local
    /// (newer) copy was preserved.
    public let keptLocal: Int
    public let invalid: [String]

    public init(inserted: Int, updated: Int, keptLocal: Int = 0, invalid: [String]) {
        self.inserted = inserted
        self.updated = updated
        self.keptLocal = keptLocal
        self.invalid = invalid
    }
}

/// The result of merging an imported backup into the local notes: the merged
/// array plus the counts the UI reports.
public struct ScratchpadMergeOutcome: Equatable, Sendable {
    /// Fully merged, validated and sorted (pinned first, then newest).
    public let notes: [ScratchpadNote]
    public let result: ScratchpadImportResult

    public init(notes: [ScratchpadNote], result: ScratchpadImportResult) {
        self.notes = notes
        self.result = result
    }
}

struct ScratchpadPersisted: Codable {
    static let currentVersion = 1

    var version: Int
    var notes: [ScratchpadNote]
}
