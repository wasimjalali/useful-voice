import Foundation

/// A lightweight note dictated or typed inside the app. Spec section 4 (NotesStore).
public struct Note: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}
