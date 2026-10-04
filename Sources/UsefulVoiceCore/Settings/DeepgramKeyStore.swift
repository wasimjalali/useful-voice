import Foundation

/// Thread-safe, non-blocking access to the Deepgram API key.
///
/// Why this exists rather than calling `Keychain` directly:
///
/// Reading a keychain item with `kSecReturnData` can block the calling thread
/// until securityd answers, and it can put up an authorization prompt that
/// blocks until the *user* answers it. That behaviour is documented in
/// `Keychain.swift` itself. The dictation pipeline used to call `Keychain.get`
/// from the main actor to build the provider list, and the global CGEvent tap
/// runs on the main run loop, so a blocked read meant a blocked event tap:
/// macOS disables a stalling tap and system-wide keyboard handling stalls.
///
/// The fix is to read the key once, off the main thread, and keep it in memory.
/// Provider construction then reads a cached value with no keychain call on any
/// hot path. A small lock keeps that cache safe from every thread without
/// forcing callers into `async`.
public final class DeepgramKeyStore: @unchecked Sendable {
    public static let shared = DeepgramKeyStore()

    public static let account = "deepgram-key"

    private let lock = NSLock()
    private var cached: String?
    private var loaded = false
    /// Set when a completed read failed for a reason other than "nothing stored".
    private var problem: String?
    /// Which cache publishes still count (see `KeyPublishGate`). Guarded by `lock`.
    private var gate = KeyPublishGate()
    /// Keychain writes run here, one at a time, in the order they were requested.
    private let writeQueue = DispatchQueue(label: "ai.karko.sadaa.deepgram-key-writes",
                                           qos: .userInitiated)

    public init() {}

    /// The key as last read, or `nil` when none is configured. Never touches the
    /// keychain, so it returns immediately and is safe on any thread — including
    /// inside a CGEvent tap callback.
    public var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// True once the keychain has been consulted at least once.
    public var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded
    }

    /// Reads the key from the keychain and caches it.
    ///
    /// Call this off the main thread: the read may block on securityd or on a
    /// user authorization prompt. Returns the resolved key.
    @discardableResult
    public func load() -> String? {
        let generation = beginRead()
        let lookup = Keychain.lookup(account: Self.account)
        recordLookupFailure(lookup)
        store(lookup.value, readGeneration: generation)
        return current
    }

    /// Why the last `load()` found no key, when the reason was not simply
    /// "nothing stored". `nil` after a successful read or a genuine absence.
    ///
    /// Exposed so the UI can say "your keychain is locked" instead of the
    /// misleading "no transcription provider configured".
    public var lookupProblem: String? {
        lock.lock()
        defer { lock.unlock() }
        return problem
    }

    /// Resolves the key, preferring the cache, and reports why it is missing.
    ///
    /// Used where the difference between absent and unreadable changes what the
    /// user should do.
    public func resolve() -> Keychain.Lookup {
        if let cached, !cached.isEmpty { return .found(cached) }
        if loaded {
            // A completed read that produced nothing: absent and unreadable are
            // distinguished by `problem`, which the read already recorded.
            if let problem { return .unavailable(problem) }
            return .absent
        }
        let generation = beginRead()
        let lookup = Keychain.lookup(account: Self.account)
        recordLookupFailure(lookup)
        store(lookup.value, readGeneration: generation)
        return lookup
    }

    private func recordLookupFailure(_ lookup: Keychain.Lookup) {
        let resolution: String?
        switch lookup {
        case .found:
            resolution = nil
        case .absent:
            resolution = nil
        case .unavailable(let reason):
            resolution = reason
            // Worth a log line: silent refusal to read a stored key is exactly
            // the failure that produced unhelpful support conversations.
            Diagnostics.shared.error("keychain", "could not read the Deepgram key: \(reason)")
        }
        lock.lock()
        problem = resolution
        lock.unlock()
    }

    /// True when a key is present, without decrypting it.
    ///
    /// Uses `Keychain.exists` (no `kSecReturnData`), which never prompts, and
    /// short-circuits on the cache when it is already loaded.
    public func isConfigured() -> Bool {
        if isLoaded { return !(current ?? "").isEmpty }
        return Keychain.exists(account: Self.account)
    }

    /// Saves the key to the keychain and, once that succeeded, publishes it to the
    /// cache the dictation pipeline reads. The only way to change the key.
    ///
    /// Writes run one at a time in the order they were requested, and each one
    /// carries a generation, so a slow earlier write or a read that started before
    /// it can never publish an older key over a newer save or a removal.
    /// Throws when the keychain write fails; nothing is published then.
    public func save(_ value: String) async throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = beginWrite()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async {
                do {
                    try Keychain.set(trimmed, account: Self.account)
                    self.publish(trimmed, generation: generation)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Deletes the key and clears the cache, in order with `save`.
    public func remove() async {
        let generation = beginWrite()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeQueue.async {
                Keychain.delete(account: Self.account)
                self.publish(nil, generation: generation)
                continuation.resume()
            }
        }
    }

    /// Sets the cache directly, for tests. App code goes through `save` and `remove`.
    func update(_ value: String?) {
        store(value, readGeneration: beginRead())
    }

    private func beginWrite() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return gate.beginWrite()
    }

    private func beginRead() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return gate.latest
    }

    private func publish(_ value: String?, generation: UInt64) {
        store(value, readGeneration: generation)
    }

    /// Forgets the cached value so the next `load()` re-reads the keychain.
    public func invalidate() {
        lock.lock()
        cached = nil
        loaded = false
        lock.unlock()
    }

    /// Publishes to the cache unless a newer write has started since `readGeneration`.
    private func store(_ value: String?, readGeneration: UInt64) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        guard gate.accepts(readGeneration) else { return }
        cached = (trimmed?.isEmpty ?? true) ? nil : trimmed
        loaded = true
    }
}

/// The rule that keeps the key cache honest: every write takes a new generation,
/// and a cache publish (from a write or from a keychain read) counts only while
/// no newer write has started. Pure, so it is unit-tested without a keychain.
struct KeyPublishGate {
    private(set) var latest: UInt64 = 0

    mutating func beginWrite() -> UInt64 {
        latest += 1
        return latest
    }

    func accepts(_ generation: UInt64) -> Bool {
        generation == latest
    }
}
