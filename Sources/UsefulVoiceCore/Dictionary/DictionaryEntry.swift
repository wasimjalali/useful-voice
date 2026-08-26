import Foundation

public struct DictionaryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var word: String
    public var soundsLike: String?

    public init(id: UUID = UUID(), word: String, soundsLike: String? = nil) {
        self.id = id
        self.word = word
        self.soundsLike = soundsLike
    }
}
