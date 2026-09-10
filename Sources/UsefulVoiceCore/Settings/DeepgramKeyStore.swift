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
        let lookup = Keychain.lookup(account: Self.account)
        recordLookupFailure(lookup)
        store(lookup.value)
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
        let lookup = Keychain.lookup(account: Self.account)
        recordLookupFailure(lookup)
        store(lookup.value)
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

    /// Updates the cache after the user edits the key in Settings. Persisting to
    /// the keychain stays the caller's job (it is a user action, where a prompt
    /// is expected); this only refreshes what the pipeline reads.
    public func update(_ value: String?) {
        store(value)
    }

    /// Forgets the cached value so the next `load()` re-reads the keychain.
    public func invalidate() {
        lock.lock()
        cached = nil
        loaded = false
        lock.unlock()
    }

    private func store(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        cached = (trimmed?.isEmpty ?? true) ? nil : trimmed
        loaded = true
        lock.unlock()
    }
}
