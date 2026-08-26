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
    public let invalid: [String]

    public init(inserted: Int, updated: Int, invalid: [String]) {
        self.inserted = inserted
        self.updated = updated
        self.invalid = invalid
    }
}

struct ScratchpadPersisted: Codable {
    static let currentVersion = 1

    var version: Int
    var notes: [ScratchpadNote]
}
