import Foundation

/// A spoken trigger and the text it expands to during formatting. Spec section 4.
public struct Snippet: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var trigger: String
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}
