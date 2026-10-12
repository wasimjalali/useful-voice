import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite(.serialized) struct KeychainTests {
    private let account = "test-azure-key"

    @Test func testSetGetDelete() throws {
        // Guarantee cleanup of the real keychain even if an expectation fails.
        defer { try? Keychain.delete(account: account) }

        try Keychain.delete(account: account) // start clean in case a prior run left state
        #expect(Keychain.get(account: account) == nil)
        try Keychain.set("sk-secret-123", account: account)
        #expect(Keychain.get(account: account) == "sk-secret-123")
        try Keychain.set("sk-rotated-456", account: account) // overwrite
        #expect(Keychain.get(account: account) == "sk-rotated-456")
        try Keychain.delete(account: account)
        #expect(Keychain.get(account: account) == nil)
    }

    @Test func testExistsTracksPresenceWithoutReturningData() throws {
        defer { try? Keychain.delete(account: account) }

        try Keychain.delete(account: account)
        #expect(Keychain.exists(account: account) == false)
        try Keychain.set("sk-secret-123", account: account)
        #expect(Keychain.exists(account: account) == true)
        try Keychain.delete(account: account)
        #expect(Keychain.exists(account: account) == false)
    }

    /// The service parameter is what the identity migration relies on: the same
    /// account under two services is two separate items.
    @Test func testServicesAreSeparateItems() throws {
        let other = "uv.test.service.\(UUID().uuidString)"
        defer {
            try? Keychain.delete(account: account)
            try? Keychain.delete(account: account, service: other)
        }

        try Keychain.delete(account: account)
        try Keychain.set("default-service-value", account: account)
        #expect(Keychain.exists(account: account, service: other) == false)
        try Keychain.set("other-service-value", account: account, service: other)
        #expect(Keychain.get(account: account) == "default-service-value")
        #expect(Keychain.lookup(account: account, service: other) == .found("other-service-value"))
        try Keychain.delete(account: account, service: other)
        #expect(Keychain.exists(account: account, service: other) == false)
        #expect(Keychain.get(account: account) == "default-service-value")
    }
}
