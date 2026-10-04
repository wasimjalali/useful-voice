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
    /// Each test uses its own store over a fake backend, so the shared singleton
    /// and the user's real keychain are never touched.
    @Test("a cached key resolves without reading the keychain again")
    func cachedKeyResolves() {
        let backend = FakeKeyBackend(stored: "dg-cached")
        let store = DeepgramKeyStore(backend: backend)
        store.load()

        #expect(store.resolve() == .found("dg-cached"))
        #expect(backend.lookupCount == 1)
        #expect(store.lookupProblem == nil)
    }

    @Test("resolve reads the keychain when nothing was loaded yet")
    func resolveReadsWhenUnloaded() {
        let backend = FakeKeyBackend(stored: nil)
        backend.lookupOverride = .unavailable("the keychain is locked")
        let store = DeepgramKeyStore(backend: backend)

        #expect(store.resolve() == .unavailable("the keychain is locked"))
        #expect(store.lookupProblem == "the keychain is locked")
        #expect(store.isLoaded)
    }

    @Test("whitespace-only input is not a key")
    func whitespaceIsNotAKey() {
        let store = DeepgramKeyStore(backend: FakeKeyBackend(stored: "   \n  "))
        store.load()

        // A key of spaces would build a provider that always fails auth; treating
        // it as absent is the honest answer.
        #expect(store.current == nil)
    }

    @Test("a key is trimmed before use")
    func keyIsTrimmed() async throws {
        let backend = FakeKeyBackend(stored: nil)
        let store = DeepgramKeyStore(backend: backend)
        try await store.save("  dg-key\n")

        // Pasting a key from the Deepgram console routinely brings whitespace, and
        // a trailing newline in an Authorization header fails the request.
        #expect(store.current == "dg-key")
        #expect(backend.stored == "dg-key")
    }

    @Test("a failed save keeps the key the keychain still holds")
    func failedSaveKeepsCache() async throws {
        let backend = FakeKeyBackend(stored: nil)
        let store = DeepgramKeyStore(backend: backend)
        try await store.save("dg-first")
        backend.failWrites = true

        await #expect(throws: KeychainError.self) { try await store.save("dg-second") }
        #expect(store.current == "dg-first")
        #expect(backend.stored == "dg-first")
    }

    @Test("a failed remove throws and keeps the key it could not delete")
    func failedRemoveKeepsCache() async throws {
        let backend = FakeKeyBackend(stored: nil)
        let store = DeepgramKeyStore(backend: backend)
        try await store.save("dg-key")
        backend.failDeletes = true

        await #expect(throws: KeychainError.self) { try await store.remove() }
        #expect(store.current == "dg-key")
        #expect(backend.stored == "dg-key")
    }

    @Test("save and remove clear a read problem")
    func mutationsClearProblem() async throws {
        let backend = FakeKeyBackend(stored: "dg-old")
        backend.lookupOverride = .unavailable("the keychain is locked")
        let store = DeepgramKeyStore(backend: backend)
        store.load()
        #expect(store.lookupProblem == "the keychain is locked")

        try await store.save("dg-new")
        #expect(store.lookupProblem == nil)
        #expect(store.current == "dg-new")

        store.load()
        #expect(store.lookupProblem == "the keychain is locked")
        try await store.remove()
        #expect(store.lookupProblem == nil)
        #expect(store.current == nil)
        #expect(backend.stored == nil)
    }

    @Test("a removal requested during a slow save wins, in the keychain and the cache")
    func removeAfterSlowSave() async throws {
        let backend = FakeKeyBackend(stored: "dg-old")
        let gate = OperationGate()
        backend.writeGate = gate
        let store = DeepgramKeyStore(backend: backend)

        let saving = Task { try await store.save("dg-new") }
        await gate.waitUntilStarted()
        let removing = Task { try await store.remove() }
        gate.release()
        try await saving.value
        try await removing.value

        #expect(backend.stored == nil)
        #expect(store.current == nil)
    }

    @Test("a read waits for a write in flight and sees its result")
    func readWaitsForWrite() async throws {
        let backend = FakeKeyBackend(stored: "dg-old")
        let gate = OperationGate()
        backend.writeGate = gate
        let store = DeepgramKeyStore(backend: backend)

        let saving = Task { try await store.save("dg-new") }
        await gate.waitUntilStarted()
        let read = BackgroundCall { store.load() }
        // While the write is held, the read must not complete with the old key.
        #expect(await read.finished(within: 0.2) == false)
        gate.release()
        try await saving.value

        #expect(await read.result() == "dg-new")
        #expect(store.current == "dg-new")
    }

    @Test("a read that started before a save can't publish over it")
    func earlierReadCantOverwriteSave() async throws {
        let backend = FakeKeyBackend(stored: "dg-old")
        let gate = OperationGate()
        backend.lookupGate = gate
        let store = DeepgramKeyStore(backend: backend)

        let read = BackgroundCall { store.load() }
        await gate.waitUntilStarted()
        let saving = Task { try await store.save("dg-new") }
        gate.release()
        try await saving.value

        #expect(await read.result() == "dg-old")
        #expect(store.current == "dg-new")
        #expect(backend.stored == "dg-new")
    }
}

/// In-memory stand-in for the keychain item, with switches for failures and
/// gates that hold an operation mid-flight.
private final class FakeKeyBackend: DeepgramKeyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: String?
    private var _lookups = 0
    var lookupOverride: Keychain.Lookup? {
        get { locked { _lookupOverride } }
        set { locked { _lookupOverride = newValue } }
    }
    private var _lookupOverride: Keychain.Lookup?
    var failWrites: Bool {
        get { locked { _failWrites } }
        set { locked { _failWrites = newValue } }
    }
    private var _failWrites = false
    var failDeletes: Bool {
        get { locked { _failDeletes } }
        set { locked { _failDeletes = newValue } }
    }
    private var _failDeletes = false
    /// Set before the store is used; read on the store's queue.
    var writeGate: OperationGate?
    var lookupGate: OperationGate?

    init(stored: String?) { _stored = stored }

    var stored: String? { locked { _stored } }
    var lookupCount: Int { locked { _lookups } }

    func lookup() -> Keychain.Lookup {
        let snapshot: (String?, Keychain.Lookup?) = locked {
            _lookups += 1
            return (_stored, _lookupOverride)
        }
        lookupGate?.enter()
        if let override = snapshot.1 { return override }
        guard let value = snapshot.0 else { return .absent }
        return .found(value)
    }

    func write(_ value: String) throws {
        writeGate?.enter()
        try locked {
            if _failWrites { throw KeychainError.unexpectedStatus(errSecIO) }
            _stored = value
        }
    }

    func delete() throws {
        try locked {
            if _failDeletes { throw KeychainError.unexpectedStatus(errSecIO) }
            _stored = nil
        }
    }

    func exists() -> Bool { stored != nil }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Holds one operation on the store's queue until the test releases it. Waits run
/// on GCD threads, never on the Swift concurrency pool, so a held queue can't
/// starve the test.
private final class OperationGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    /// Called by the fake backend on the store's queue.
    func enter() {
        started.signal()
        released.wait()
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.started.wait()
                continuation.resume()
            }
        }
    }

    func release() { released.signal() }
}

/// Runs a blocking store call on a GCD thread and lets the test check whether it
/// has finished.
private final class BackgroundCall: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: String?

    init(_ body: @escaping @Sendable () -> String?) {
        DispatchQueue.global().async {
            let result = body()
            self.lock.lock()
            self.value = result
            self.lock.unlock()
            self.done.signal()
        }
    }

    /// True if the call finished within `seconds`. Leaves `result()` usable.
    func finished(within seconds: Double) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                let outcome = self.done.wait(timeout: .now() + seconds)
                if outcome == .success { self.done.signal() }
                continuation.resume(returning: outcome == .success)
            }
        }
    }

    func result() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global().async {
                self.done.wait()
                self.lock.lock()
                let value = self.value
                self.lock.unlock()
                continuation.resume(returning: value)
            }
        }
    }
}
