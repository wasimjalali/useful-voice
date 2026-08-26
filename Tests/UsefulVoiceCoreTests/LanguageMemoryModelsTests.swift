import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite struct LanguageMemoryModelsTests {
    @Test func testMemoryTermCodableRoundTrip() throws {
        let term = MemoryTerm(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            phrase: "Karko AI",
            pronunciations: ["car co ai"],
            aliases: ["Karko"],
            language: .auto,
            priority: .high,
            notes: "Company name",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            usageCount: 3
        )
        let data = try JSONEncoder().encode(term)
        let decoded = try JSONDecoder().decode(MemoryTerm.self, from: data)
        #expect(decoded == term)
    }
}
