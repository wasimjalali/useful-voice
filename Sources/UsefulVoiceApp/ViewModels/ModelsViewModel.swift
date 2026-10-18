import Combine
import Foundation
import UsefulVoiceCore

/// Where a local model stands, whichever engine runs it.
enum LocalModelStatus: Equatable {
    case notDownloaded(bytes: Int64)
    /// `fraction` is nil while the engine can't report it.
    case downloading(fraction: Double?)
    case verifying
    case paused(canResume: Bool)
    case ready(bytes: Int64?)
    case failed(String)
}

/// What "Test" on a key row found.
enum KeyTestState: Equatable {
    case idle
    case testing
    case ok(milliseconds: Int)
    case rejected
    case offline
    case failed(String)
}

/// The state behind Settings > Models: which voice model and AI formatting model are
/// chosen, which keys are saved, and the local downloads. Selection rules live here so
/// the rows stay plain.
@MainActor
final class ModelsViewModel: ObservableObject {
    @Published private(set) var voiceID: String
    @Published private(set) var formatterID: String?
    @Published private(set) var keyStored: [KeyProvider: Bool] = [:]
    @Published var keyTests: [KeyProvider: KeyTestState] = [:]
    @Published private(set) var savingKey: KeyProvider?
    /// A local model picked before it was on this Mac: it becomes the voice model when ready.
    @Published private(set) var pendingLocalID: String?
    /// Set by "Add key": the key row for this provider opens and takes focus.
    @Published var focusRequest: KeyProvider?
    /// A problem a key store reported (a locked Keychain), per provider.
    @Published private(set) var keyProblem: [KeyProvider: String] = [:]

    let whisper: LocalModelManager
    let parakeet: ParakeetModelManager
    private let settings: AppSettings
    private var awaitingKey: (kind: ModelKind, id: String)?
    private var bag = Set<AnyCancellable>()

    enum ModelKind { case voice, formatter }

    /// The page tells the app the config changed (status line, banners).
    var onChanged: (() -> Void)?
    /// A change the person made: the page says "Saved".
    var onSaved: (() -> Void)?
    /// Scroll to the API keys group.
    var onShowKeys: (() -> Void)?
    /// A key could not be saved or removed.
    var onKeyError: ((String) -> Void)?
    var languagePin: () -> LanguagePin = { .auto }
    /// Whether the dictation pipeline can read this provider's key right now. It reads the
    /// same in-memory cache, which fills in off the main thread at launch.
    var keyReadable: (KeyProvider) -> Bool = { ProviderKeyStore.store(for: $0).current != nil }

    init(settings: AppSettings, whisper: LocalModelManager, parakeet: ParakeetModelManager) {
        self.settings = settings
        self.whisper = whisper
        self.parakeet = parakeet
        voiceID = settings.voiceModelID
        formatterID = settings.formatterModelID
        refreshKeys()
        whisper.objectWillChange.sink { [weak self] _ in self?.localsChanged() }.store(in: &bag)
        parakeet.objectWillChange.sink { [weak self] _ in self?.localsChanged() }.store(in: &bag)
    }

    // MARK: - Reading

    func refreshKeys() {
        var next: [KeyProvider: Bool] = [:]
        for provider in KeyProvider.allCases {
            next[provider] = ProviderKeyStore.store(for: provider).isConfigured()
        }
        keyStored = next
        var problems: [KeyProvider: String] = [:]
        for provider in KeyProvider.allCases {
            if let problem = ProviderKeyStore.store(for: provider).lookupProblem { problems[provider] = problem }
        }
        keyProblem = problems
    }

    /// Re-reads everything the settings own, after the setup flow ran.
    func reload() {
        voiceID = settings.voiceModelID
        formatterID = settings.formatterModelID
        refreshKeys()
        whisper.refreshAvailability()
    }

    /// A key that is stored but can't be read (a locked Keychain) counts as missing: the
    /// row says "Add key", and nothing pretends the model it serves is working.
    func hasKey(_ provider: KeyProvider) -> Bool {
        (keyStored[provider] ?? false) && keyProblem[provider] == nil
    }

    /// The formatter in effect: a selected model whose key can't be used, or isn't loaded
    /// yet, is not on. Nothing claims formatting is running while the formatter can't
    /// read its key.
    var effectiveFormatterID: String? {
        guard let id = formatterID, let entry = ModelCatalog.languageModel(id: id),
              let provider = entry.keyProvider, !needsKey(entry), keyReadable(provider) else { return nil }
        return id
    }

    /// A key finished loading in the background: look again.
    func keysLoaded() {
        refreshKeys()
        objectWillChange.send()
    }

    /// A cloud model whose key isn't saved can't be picked; "Add key" takes its place.
    func needsKey(_ entry: ModelEntry) -> Bool {
        guard let provider = entry.keyProvider else { return false }
        return !hasKey(provider)
    }

    func isSelected(_ entry: ModelEntry, kind: ModelKind) -> Bool {
        switch kind {
        case .voice: return (pendingLocalID ?? voiceID) == entry.id
        case .formatter: return effectiveFormatterID == entry.id
        }
    }

    /// Sample state for offscreen snapshots only (`UV_SETTINGS_STATE`); nothing is saved.
    private var previewStatus: [String: LocalModelStatus] = [:]

    enum Preview { case noKeys, sample, rejectedKey }

    func applyPreview(_ preview: Preview) {
        switch preview {
        case .noKeys:
            keyReadable = { _ in false }
            keyStored = Dictionary(uniqueKeysWithValues: KeyProvider.allCases.map { ($0, false) })
            keyProblem = [:]
            voiceID = ModelCatalog.defaultVoiceID
            formatterID = nil
        case .sample:
            keyReadable = { [weak self] in self?.keyStored[$0] ?? false }
            keyStored = [.deepgram: true, .gemini: true, .elevenLabs: false, .anthropic: false]
            keyProblem = [:]
            keyTests = [.deepgram: .ok(milliseconds: 412)]
            voiceID = "deepgram:nova-3"
            formatterID = "gemini:gemini-3.8-flash"
            previewStatus = [
                "whisper:large-v3-turbo": .ready(bytes: 1_624_555_275),
                "whisper:large-v3": .notDownloaded(bytes: 3_095_033_483),
                "parakeet:v2": .downloading(fraction: 0.42),
                "parakeet:v3": .failed("The download stopped."),
            ]
        case .rejectedKey:
            keyStored = [.deepgram: true, .gemini: false, .elevenLabs: false, .anthropic: false]
            keyTests = [.deepgram: .rejected]
        }
    }

    func status(of entry: ModelEntry) -> LocalModelStatus? {
        if let preview = previewStatus[entry.id] { return preview }
        if let model = ModelCatalog.whisperModel(forVoiceID: entry.id) {
            switch whisper.state(for: model) {
            case .downloading(let received, let total):
                return .downloading(fraction: Double(received) / Double(max(total, 1)))
            case .validating: return .verifying
            case .paused: return .paused(canResume: whisper.canResume(model))
            case .failed(let message, _): return .failed(message)
            case .idle:
                switch whisper.availability(of: model) {
                case .usable: return .ready(bytes: model.expectedBytes)
                case .missing: return .notDownloaded(bytes: model.expectedBytes)
                case .invalid: return .failed("The file didn't pass its check. Download it again.")
                }
            }
        }
        if let version = ParakeetVersion(catalogID: entry.id) {
            switch parakeet.state(of: version) {
            case .notDownloaded: return .notDownloaded(bytes: Self.parakeetApproximateBytes)
            case .downloading(let progress): return .downloading(fraction: progress)
            case .ready(let bytes): return .ready(bytes: bytes ?? Self.parakeetApproximateBytes)
            case .failed(let message): return .failed(message)
            }
        }
        return nil
    }

    /// Parakeet's download is about 480 MB (v3 per the FluidAudio docs; v2 is the same size class).
    static let parakeetApproximateBytes: Int64 = 480_000_000

    // MARK: - Choosing

    func selectVoice(_ entry: ModelEntry) {
        // Picking anything drops an earlier "switch when it's downloaded".
        pendingLocalID = nil
        if needsKey(entry) { requestKey(for: entry, kind: .voice); return }
        if entry.isLocal, let status = status(of: entry), !isReady(status) {
            // Picked before it was here: download now, switch when it lands.
            pendingLocalID = entry.id
            switch status {
            case .paused, .notDownloaded, .failed: download(entry)
            default: break
            }
            return
        }
        commitVoice(entry.id)
    }

    func selectFormatter(_ entry: ModelEntry?) {
        guard let entry else {
            settings.formatterModelID = nil
            formatterID = nil
            onChanged?(); onSaved?()
            return
        }
        if needsKey(entry) { requestKey(for: entry, kind: .formatter); return }
        settings.formatterModelID = entry.id
        formatterID = settings.formatterModelID
        onChanged?(); onSaved?()
    }

    private func isReady(_ status: LocalModelStatus) -> Bool {
        if case .ready = status { return true }
        return false
    }

    private func commitVoice(_ id: String) {
        pendingLocalID = nil
        settings.voiceModelID = id
        voiceID = settings.voiceModelID
        if let model = ModelCatalog.whisperModel(forVoiceID: id) { whisper.activate(model) }
        whisper.engineChanged(to: settings.transcriptionEngine)
        onChanged?(); onSaved?()
    }

    private func requestKey(for entry: ModelEntry, kind: ModelKind) {
        guard let provider = entry.keyProvider else { return }
        awaitingKey = (kind, entry.id)
        focusRequest = provider
        onShowKeys?()
    }

    /// Asks for the key row of this provider ("Add key" next to a model).
    func addKey(for entry: ModelEntry, kind: ModelKind) { requestKey(for: entry, kind: kind) }

    /// A local download may have finished: switch to the model that was waiting for it.
    private func localsChanged() {
        Task { @MainActor [weak self] in
            guard let self, let id = self.pendingLocalID,
                  let entry = ModelCatalog.voiceModel(id: id),
                  let status = self.status(of: entry) else { return }
            switch status {
            case .ready: self.commitVoice(id)
            // A failed download keeps the pending switch, so a successful retry still
            // selects the model. Picking another model clears it.
            default: break
            }
        }
    }

    // MARK: - Local downloads

    func download(_ entry: ModelEntry) {
        if let model = ModelCatalog.whisperModel(forVoiceID: entry.id) {
            whisper.download(model)
        } else if let version = ParakeetVersion(catalogID: entry.id) {
            parakeet.download(version)
        }
    }

    func cancelDownload(_ entry: ModelEntry) {
        if pendingLocalID == entry.id { pendingLocalID = nil }
        if let model = ModelCatalog.whisperModel(forVoiceID: entry.id) {
            whisper.pause(model)
        } else if let version = ParakeetVersion(catalogID: entry.id) {
            parakeet.cancelDownload(version)
        }
    }

    /// Removes the files. A deleted model that was the voice model stays selected, and
    /// dictation says to download it again: nothing swaps to another provider quietly.
    func delete(_ entry: ModelEntry) {
        if let model = ModelCatalog.whisperModel(forVoiceID: entry.id) {
            whisper.delete(model)
        } else if let version = ParakeetVersion(catalogID: entry.id) {
            do { try parakeet.delete(version) } catch {
                onKeyError?("Couldn't delete \(entry.name). Close other apps using it and try again.")
            }
        }
        onChanged?()
    }

    // MARK: - Keys

    func saveKey(_ provider: KeyProvider, value: String) async -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, savingKey == nil else { return false }
        savingKey = provider
        defer { savingKey = nil }
        do {
            try await ProviderKeyStore.store(for: provider).save(trimmed)
        } catch {
            onKeyError?("Could not save the Keychain value")
            return false
        }
        refreshKeys()
        keyTests[provider] = .idle
        onChanged?(); onSaved?()
        if let waiting = awaitingKey, let entry = Self.entry(id: waiting.id, kind: waiting.kind),
           entry.keyProvider == provider {
            awaitingKey = nil
            switch waiting.kind {
            case .voice: selectVoice(entry)
            case .formatter: selectFormatter(entry)
            }
        }
        test(provider, typed: trimmed)
        return true
    }

    func removeKey(_ provider: KeyProvider) async {
        guard savingKey == nil else { return }
        savingKey = provider
        defer { savingKey = nil }
        do {
            try await ProviderKeyStore.store(for: provider).remove()
        } catch {
            onKeyError?("Couldn't remove the key from your Keychain. Try again.")
            return
        }
        keyTests[provider] = .idle
        // A formatter that needs the removed key goes back to Off rather than failing silently.
        if let formatter = settings.formatterModel, formatter.keyProvider == provider {
            settings.formatterModelID = nil
            formatterID = nil
        }
        refreshKeys()
        onChanged?(); onSaved?()
    }

    private static func entry(id: String, kind: ModelKind) -> ModelEntry? {
        kind == .voice ? ModelCatalog.voiceModel(id: id) : ModelCatalog.languageModel(id: id)
    }

    /// Checks the key: the one just typed, or the saved one.
    func test(_ provider: KeyProvider, typed: String? = nil) {
        keyTests[provider] = .testing
        let pin = languagePin()
        Task { [weak self] in
            let key: String
            if let typed, !typed.isEmpty {
                key = typed
            } else {
                // Off the main actor: the Keychain call can block on a prompt. A peek, so a
                // test never changes the key dictation uses.
                let lookup = await Task.detached(priority: .userInitiated) {
                    ProviderKeyStore.store(for: provider).peek()
                }.value
                switch lookup {
                case .found(let value): key = value
                case .unavailable(let reason):
                    await MainActor.run { self?.keyTests[provider] = .failed("Your saved key could not be read (\(reason)). Unlock your login keychain and try again.") }
                    return
                case .absent:
                    await MainActor.run { self?.keyTests[provider] = .failed("Add a key first.") }
                    return
                }
            }
            let state: KeyTestState
            if provider == .deepgram {
                let result = await ProviderHealthCheck.check(
                    provider: DeepgramProvider(config: .init(apiKey: key, smartFormat: true)),
                    endpoint: "https://api.deepgram.com/v1/listen",
                    hint: TranscriptionHint(languagePin: pin, dictionaryWords: []))
                if result.ok {
                    state = .ok(milliseconds: result.latencyMilliseconds ?? 0)
                } else {
                    switch result.failure {
                    case .rejected: state = .rejected
                    case .network: state = .offline
                    default: state = .failed(result.message)
                    }
                }
            } else {
                switch await ProviderKeyTester.test(provider: provider, key: key) {
                case .ok(let ms): state = .ok(milliseconds: ms)
                case .rejected: state = .rejected
                case .offline: state = .offline
                case .failed(let message): state = .failed(message)
                }
            }
            await MainActor.run { self?.keyTests[provider] = state }
        }
    }
}
