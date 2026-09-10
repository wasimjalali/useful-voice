import Foundation
import Security
import Testing

@testable import UsefulVoiceCore

/// These test the classification, not the live keychain.
///
/// That distinction is the point: the branches that matter most — a locked
/// keychain, a dismissed authorization prompt — cannot be produced on demand
/// against the real keychain in a test, and they are exactly the ones that used
/// to be misreported as "no key configured".
@Suite("Keychain lookup classification")
struct KeychainLookupTests {
    @Test("a readable item is found")
    func foundItem() {
        let data = Data("dg-test-key".utf8)
        #expect(Keychain.classify(status: errSecSuccess, result: data as AnyObject) == .found("dg-test-key"))
    }

    @Test("a genuinely missing item is absent")
    func missingItemIsAbsent() {
        // The ONLY status that means "you have not set a key".
        #expect(Keychain.classify(status: errSecItemNotFound, result: nil) == .absent)
    }

    @Test("a locked keychain is unavailable, not absent")
    func lockedKeychain() {
        let result = Keychain.classify(status: errSecInteractionNotAllowed, result: nil)
        #expect(result == .unavailable("the keychain is locked"))
        // The whole bug: this must NOT be reported as "not configured".
        #expect(result != .absent)
        #expect(result.value == nil)
    }

    @Test("a dismissed prompt is unavailable, not absent")
    func dismissedPrompt() {
        let result = Keychain.classify(status: errSecUserCanceled, result: nil)
        #expect(result == .unavailable("keychain access was denied"))
        #expect(result != .absent)
    }

    @Test("failed authentication is unavailable, not absent")
    func authenticationFailure() {
        let result = Keychain.classify(status: errSecAuthFailed, result: nil)
        #expect(result == .unavailable("keychain authentication failed"))
        #expect(result != .absent)
    }

    @Test("an unknown status reports the code")
    func unknownStatusIncludesCode() {
        // errSecNotAvailable (-25291) is a plausible real-world case on a machine
        // with no unlocked keychain at all.
        let status: OSStatus = errSecNotAvailable
        let result = Keychain.classify(status: status, result: nil)
        #expect(result == .unavailable("the keychain returned status \(status)"))
        #expect(result != .absent)
    }

    @Test("success with no data is unavailable, not absent")
    func successWithoutData() {
        let result = Keychain.classify(status: errSecSuccess, result: nil)
        #expect(result == .unavailable("the stored key could not be read"))
        #expect(result != .absent)
    }

    @Test("success with non-text data is unavailable, not absent")
    func successWithUndecodableData() {
        // 0xFF 0xFE is not valid UTF-8.
        let data = Data([0xFF, 0xFE, 0xFF])
        let result = Keychain.classify(status: errSecSuccess, result: data as AnyObject)
        #expect(result == .unavailable("the stored key is empty or not valid text"))
        #expect(result != .absent)
    }

    @Test("success with empty data is unavailable, not a usable key")
    func successWithEmptyData() {
        let result = Keychain.classify(status: errSecSuccess, result: Data() as AnyObject)
        // An empty stored value is not a working key; treating it as "found" would
        // build a provider with an empty credential and fail at transcription.
        #expect(result == .unavailable("the stored key is empty or not valid text"))
        #expect(result.value == nil)
    }

    @Test("only the found case exposes a value")
    func onlyFoundCarriesAValue() {
        #expect(Keychain.Lookup.found("k").value == "k")
        #expect(Keychain.Lookup.absent.value == nil)
        #expect(Keychain.Lookup.unavailable("reason").value == nil)
    }
}

@Suite("Deepgram key store resolution")
struct DeepgramKeyStoreTests {
    /// Uses its own instance so the shared singleton (and the user's real keychain)
    /// is never touched.
    @Test("a cached key resolves without touching the keychain")
    func cachedKeyResolves() {
        let store = DeepgramKeyStore()
        store.update("dg-cached")

        #expect(store.resolve() == .found("dg-cached"))
        // A cached read must report no problem, even though no keychain read ran.
        #expect(store.lookupProblem == nil)
    }

    @Test("updating to nil clears the cache and the problem")
    func updateClearsState() {
        let store = DeepgramKeyStore()
        store.update("dg-key")
        store.update(nil)

        #expect(store.current == nil)
    }

    @Test("whitespace-only input is not a key")
    func whitespaceIsNotAKey() {
        let store = DeepgramKeyStore()
        store.update("   \n  ")

        // A key of spaces would build a provider that always fails auth; treating
        // it as absent is the honest answer.
        #expect(store.current == nil)
    }

    @Test("invalidate forgets the cached value")
    func invalidateForgets() {
        let store = DeepgramKeyStore()
        store.update("dg-key")
        store.invalidate()

        #expect(store.current == nil)
        #expect(store.isLoaded == false)
    }

    @Test("a key is trimmed before use")
    func keyIsTrimmed() {
        let store = DeepgramKeyStore()
        store.update("  dg-key\n")

        // Pasting a key from the Deepgram console routinely brings whitespace, and
        // a trailing newline in an Authorization header fails the request.
        #expect(store.current == "dg-key")
    }
}
