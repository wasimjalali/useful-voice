import Testing
import Foundation
@testable import UsefulVoiceCore

@Suite(.serialized) struct KeychainTests {
    private let account = "test-azure-key"

    @Test func testSetGetDelete() throws {
        // Guarantee cleanup of the real keychain even if an expectation fails.
        defer { Keychain.delete(account: account) }

        Keychain.delete(account: account) // start clean in case a prior run left state
        #expect(Keychain.get(account: account) == nil)
        try Keychain.set("sk-secret-123", account: account)
        #expect(Keychain.get(account: account) == "sk-secret-123")
        try Keychain.set("sk-rotated-456", account: account) // overwrite
        #expect(Keychain.get(account: account) == "sk-rotated-456")
        Keychain.delete(account: account)
        #expect(Keychain.get(account: account) == nil)
    }

    @Test func testExistsTracksPresenceWithoutReturningData() throws {
        defer { Keychain.delete(account: account) }

        Keychain.delete(account: account)
        #expect(Keychain.exists(account: account) == false)
        try Keychain.set("sk-secret-123", account: account)
        #expect(Keychain.exists(account: account) == true)
        Keychain.delete(account: account)
        #expect(Keychain.exists(account: account) == false)
    }
}
