import Foundation

/// Thread-safe, non-blocking access to one provider's API key (Deepgram,
/// ElevenLabs, Gemini or Anthropic). Each lives under its own Keychain account;
/// `DeepgramKeyStore` is the old name for this type and still works.
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
///
/// Ordering: every keychain read, write and delete of this item runs on one
/// serial queue, and the cache (with `problem`) is written only on that queue,
/// in the same step as the keychain operation it reflects. So the cache always
/// matches what the last completed operation left in the keychain: a read can't
/// interleave with a write, and a slow save can't land over a later removal.
public final class ProviderKeyStore: @unchecked Sendable {
    /// The Deepgram key, as before.
    public static let shared = ProviderKeyStore()
    public static let deepgram = shared
    public static let elevenLabs = ProviderKeyStore(provider: .elevenLabs)
    public static let gemini = ProviderKeyStore(provider: .gemini)
    public static let anthropic = ProviderKeyStore(provider: .anthropic)

    /// The Deepgram Keychain account. Kept under this name for the migration code.
    public static let account = KeyProvider.deepgram.account

    /// The store for a provider.
    public static func store(for provider: KeyProvider) -> ProviderKeyStore {
        switch provider {
        case .deepgram: return deepgram
        case .elevenLabs: return elevenLabs
        case .gemini: return gemini
        case .anthropic: return anthropic
        }
    }

    /// Whether a provider's key is stored, from the Keychain's attributes (never prompts,
    /// never the cache).
    public static func keyIsStored(for provider: KeyProvider) -> Bool {
        provider == .deepgram ? keyIsStored() : Keychain.exists(account: provider.account)
    }

    /// Every key currently cached, for redacting error text by value.
    public static func currentKeys() -> [String] {
        KeyProvider.allCases.compactMap { store(for: $0).current }
    }

    public let provider: KeyProvider
    private let backend: DeepgramKeyBackend
    /// Owns every keychain operation on this item and every cache write.
    private let queue: DispatchQueue

    /// Guards the three fields below for readers on other threads. Written only
    /// from `queue`.
    private let lock = NSLock()
    private var cached: String?
    private var loaded = false
    /// Set when a completed read failed for a reason other than "nothing stored".
    private var problem: String?

    public convenience init(provider: KeyProvider = .deepgram) {
        self.init(backend: KeychainKeyBackend(account: provider.account), provider: provider)
    }

    /// Injects the storage, so tests never touch the user's keychain.
    init(backend: DeepgramKeyBackend, provider: KeyProvider = .deepgram) {
        self.backend = backend
        self.provider = provider
        self.queue = DispatchQueue(label: "ai.useful.voice.\(provider.account)", qos: .userInitiated)
    }

    /// Runs the one-time move of the key from the previous app identity's Keychain
    /// service, on this store's queue and so ahead of any read or write of the key.
    /// Off the main thread only: reading the old item may show one Keychain prompt.
    @discardableResult
    public func migrateLegacyKey(
        with migration: IdentityMigration,
        diagnostics: Diagnostics = .shared
    ) -> IdentityMigration.KeychainOutcome {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { migration.migrateKeychain(diagnostics: diagnostics) }
    }

    /// Whether a key is stored, from the Keychain itself (attributes only, so it
    /// never prompts) and never from the cache. Counts the previous identity's
    /// item until the migration has had its one try; see `IdentityMigration`.
    public static func keyIsStored() -> Bool {
        IdentityMigration.live().keyIsStored()
    }

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

    /// Why the last read found no key, when the reason was not simply "nothing
    /// stored". `nil` after a successful read, a genuine absence, or a successful
    /// save or removal.
    ///
    /// Exposed so the UI can say "your keychain is locked" instead of the
    /// misleading "no transcription provider configured".
    public var lookupProblem: String? {
        lock.lock()
        defer { lock.unlock() }
        return problem
    }

    /// Reads the key from the keychain and caches it. Returns the cached key.
    ///
    /// Call this off the main thread: the read may block on securityd or on a
    /// user authorization prompt, and it waits for any key change in flight.
    @discardableResult
    public func load() -> String? {
        reload().value
    }

    /// Reads the keychain afresh, publishes the result, and returns it.
    ///
    /// Off the main thread only, for the same reasons as `load()`.
    public func reload() -> Keychain.Lookup {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { readAndPublish() }
    }

    /// Reads the keychain afresh without touching the cache.
    ///
    /// For checks such as Test connection: a locked keychain at that moment must
    /// not wipe the key dictation is using. Ordered with key changes like every
    /// other read. Off the main thread only, for the same reasons as `load()`.
    public func peek() -> Keychain.Lookup {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { backend.lookup() }
    }

    /// Resolves the key, preferring the cache, and reports why it is missing.
    ///
    /// Used where the difference between absent and unreadable changes what the
    /// user should do. Off the main thread only: without a completed read it
    /// reads the keychain.
    public func resolve() -> Keychain.Lookup {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            let state = snapshot()
            if let key = state.cached { return .found(key) }
            if state.loaded {
                // A completed read that produced nothing: absent and unreadable are
                // distinguished by `problem`, which that read recorded.
                if let problem = state.problem { return .unavailable(problem) }
                return .absent
            }
            return readAndPublish()
        }
    }

    /// True when a key is present, without decrypting it.
    ///
    /// Uses an attributes-only existence check (no `kSecReturnData`), which never
    /// prompts, and short-circuits on the cache when it is already loaded.
    public func isConfigured() -> Bool {
        if isLoaded { return !(current ?? "").isEmpty }
        return backend.exists()
    }

    /// Saves the key to the keychain and, in the same step, publishes it to the
    /// cache the dictation pipeline reads and clears any read problem. The only
    /// way to change the key.
    ///
    /// Throws when the keychain write fails; the cache is left as it was.
    public func save(_ value: String) async throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try await perform {
            try self.backend.write(trimmed)
            self.publish(trimmed, problem: nil)
        }
    }

    /// Deletes the key and, in the same step, clears the cache and any read
    /// problem. Ordered with `save` and every read.
    ///
    /// Throws when the keychain refuses the delete (anything but success or
    /// "nothing stored"); the cache is left as it was, since the key is still there.
    public func remove() async throws {
        try await perform {
            try self.backend.delete()
            self.publish(nil, problem: nil)
            // Marked at once, before anything can be interrupted: whatever happens to
            // the queued delete below, a leftover old item never counts as a key and
            // never migrates back.
            self.backend.forgetLegacyKey()
            // A key left under the previous app identity would stay readable (and
            // be migrated back) after the user removed theirs. Best effort, and
            // queued AFTER the caller is released: the old item trusts the old app,
            // so the delete may sit on a Keychain prompt, and the UI must not wait
            // for it. It is still ahead of any later key operation on this queue.
            self.queue.async { self.backend.deleteLegacyBestEffort() }
        }
    }

    /// Runs `work` on the queue, in submission order. The submission happens
    /// before the caller suspends, so calls made in order run in that order.
    private func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Reads the keychain and publishes value and problem together. On `queue` only.
    private func readAndPublish() -> Keychain.Lookup {
        dispatchPrecondition(condition: .onQueue(queue))
        let lookup = backend.lookup()
        switch lookup {
        case .found(let value):
            publish(value, problem: nil)
        case .absent:
            publish(nil, problem: nil)
        case .unavailable(let reason):
            // Worth a log line: silent refusal to read a stored key is exactly
            // the failure that produced unhelpful support conversations.
            Diagnostics.shared.error("keychain", "could not read the \(provider.displayName) key: \(reason)")
            publish(nil, problem: reason)
        }
        return lookup
    }

    /// The single cache write. On `queue` only, right after the keychain
    /// operation it reflects.
    private func publish(_ value: String?, problem newProblem: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        cached = (trimmed?.isEmpty ?? true) ? nil : trimmed
        problem = newProblem
        loaded = true
    }

    private func snapshot() -> (cached: String?, loaded: Bool, problem: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (cached, loaded, problem)
    }
}

/// Where the key is stored. The real one is the login keychain; tests inject a
/// fake so ordering can be checked without touching it.
protocol DeepgramKeyBackend: Sendable {
    func lookup() -> Keychain.Lookup
    func write(_ value: String) throws
    func delete() throws
    /// Attributes only: must never decrypt, so it never prompts.
    func exists() -> Bool
    /// Removes any copy under the previous app identity. Failures are logged, never thrown.
    func deleteLegacyBestEffort()
    /// Records, synchronously and without touching the Keychain, that the previous
    /// identity's item must be ignored from now on.
    func forgetLegacyKey()
}

extension DeepgramKeyBackend {
    func deleteLegacyBestEffort() {}
    func forgetLegacyKey() {}
}

struct KeychainKeyBackend: DeepgramKeyBackend {
    let account: String

    func lookup() -> Keychain.Lookup { Keychain.lookup(account: account) }
    func write(_ value: String) throws { try Keychain.set(value, account: account) }
    func delete() throws { try Keychain.delete(account: account) }
    /// Only the Deepgram key ever lived under the previous app identity.
    private var isDeepgram: Bool { account == KeyProvider.deepgram.account }
    func exists() -> Bool {
        isDeepgram ? ProviderKeyStore.keyIsStored() : Keychain.exists(account: account)
    }
    func deleteLegacyBestEffort() { if isDeepgram { IdentityMigration.live().removeLegacyKey(force: true) } }
    func forgetLegacyKey() { if isDeepgram { IdentityMigration.live().forgetLegacyKey() } }
}

/// The providers that take an API key.
public enum KeyProvider: String, CaseIterable, Sendable {
    case deepgram, elevenLabs, gemini, anthropic

    /// Keychain account under the app's service.
    public var account: String {
        switch self {
        case .deepgram: return "deepgram-key"
        case .elevenLabs: return "elevenlabs-key"
        case .gemini: return "gemini-key"
        case .anthropic: return "anthropic-key"
        }
    }

    public var displayName: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .elevenLabs: return "ElevenLabs"
        case .gemini: return "Gemini"
        case .anthropic: return "Anthropic"
        }
    }

    /// Where the person makes a key.
    public var getKeyURL: URL {
        switch self {
        case .deepgram: return URL(string: "https://console.deepgram.com")!
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        }
    }

    /// The key a catalog provider id needs.
    public init?(catalogProvider: String) {
        switch catalogProvider {
        case "deepgram": self = .deepgram
        case "elevenlabs": self = .elevenLabs
        case "gemini": self = .gemini
        case "anthropic": self = .anthropic
        default: return nil
        }
    }
}

public typealias DeepgramKeyStore = ProviderKeyStore
