import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B, run on this Mac. v2 is English only, v3 speaks 25 European languages.
public enum ParakeetVersion: String, CaseIterable, Sendable {
    case v2
    case v3

    /// The id the model catalog and the saved voice-model setting use.
    public var catalogID: String { "parakeet:\(rawValue)" }

    public init?(catalogID: String) {
        guard catalogID.hasPrefix("parakeet:") else { return nil }
        self.init(rawValue: String(catalogID.dropFirst("parakeet:".count)))
    }

    var displayName: String { "Parakeet \(rawValue)" }

    /// The base language codes v3 transcribes (the 25 European languages of NVIDIA's model card).
    static let v3Languages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk",
    ]

    /// Nil when this version can transcribe `pin`, otherwise the reason it can't.
    /// Modes (auto, multilingual) always pass: the model decodes whatever it hears.
    func languageProblem(for pin: LanguagePin) -> String? {
        if pin.isAuto || pin.isMultilingual { return nil }
        let base = (pin.rawValue.components(separatedBy: "-").first ?? pin.rawValue).lowercased()
        switch self {
        case .v2:
            guard base == "en" else {
                return "Parakeet v2 only transcribes English. Pick Parakeet v3 or another voice model for this language."
            }
        case .v3:
            guard Self.v3Languages.contains(base) else {
                return "Parakeet v3 doesn't cover this language. Pick another voice model or set the language to Auto."
            }
        }
        return nil
    }
}

public enum ParakeetModelState: Equatable, Sendable {
    case notDownloaded
    /// `progress` runs 0...1 when the download reports it, nil while it can't.
    case downloading(progress: Double?)
    case ready(sizeBytes: Int64?)
    case failed(String)
}

/// Where the models live and what counts as downloaded.
///
/// `<models>/parakeet-v2/` and `<models>/parakeet-v3/` sit beside the Whisper weights. FluidAudio
/// puts its files in a repo-named folder under the directory it is given, so the compiled models
/// are at `parakeet-vN/<repo folder>/`. A `.uv-complete` marker is written only after the whole
/// download succeeded: FluidAudio creates the model folders as soon as the first file lands, so
/// "the folders exist" can't tell a finished download from one that was quit halfway.
enum ParakeetStorage {
    static let markerName = ".uv-complete"
    static let trashPrefix = ".parakeet-trash-"

    /// Removes folders a delete renamed but did not finish removing (the app quit first).
    static func sweepTrash(in root: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for name in entries where name.hasPrefix(trashPrefix) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
    }

    static func versionDirectory(_ version: ParakeetVersion, in root: URL) -> URL {
        root.appendingPathComponent("parakeet-\(version.rawValue)", isDirectory: true)
    }

    static func repo(_ version: ParakeetVersion) -> Repo {
        version == .v2 ? .parakeetV2 : .parakeetV3
    }

    static func asrVersion(_ version: ParakeetVersion) -> AsrModelVersion {
        version == .v2 ? .v2 : .v3
    }

    /// The folder FluidAudio reads the compiled models from.
    static func modelsDirectory(_ version: ParakeetVersion, in root: URL) -> URL {
        versionDirectory(version, in: root)
            .appendingPathComponent(repo(version).folderName, isDirectory: true)
    }

    /// Every file or folder FluidAudio expects inside `modelsDirectory`.
    static func requiredEntries(_ version: ParakeetVersion) -> [String] {
        let models = version == .v2
            ? ModelNames.ASR.requiredModels : ModelNames.ASR.requiredModelsV3()
        return models.sorted() + [ModelNames.ASR.vocabularyFile]
    }

    /// Ready means: the completion marker is there, FluidAudio finds every file it needs, and every
    /// file the finished download recorded still has its recorded byte size, so a truncated or
    /// damaged file never reads as ready.
    static func isReady(_ version: ParakeetVersion, in root: URL) -> Bool {
        let dir = versionDirectory(version, in: root)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(markerName)),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker.version == version.rawValue, !marker.files.isEmpty else { return false }
        let modelsDir = modelsDirectory(version, in: root)
        for (path, size) in marker.files {
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: modelsDir.appendingPathComponent(path).path)
            guard (attributes?[.size] as? NSNumber)?.int64Value == size else { return false }
        }
        return AsrModels.modelsExist(at: modelsDir, version: asrVersion(version))
    }

    struct Marker: Codable {
        let version: String
        /// Path under the models folder to byte size, for every regular file.
        let files: [String: Int64]
    }

    static func regularFileSizes(in directory: URL) -> [String: Int64] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return [:] }
        let prefix = directory.standardizedFileURL.path + "/"
        var sizes: [String: Int64] = [:]
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let name = String(path.dropFirst(prefix.count))
            if name.hasSuffix(".partial") { continue }
            sizes[name] = Int64(values?.fileSize ?? 0)
        }
        return sizes
    }

    /// The state a version is in on disk. Walks directories, so call it off the main actor.
    static func diskState(_ version: ParakeetVersion, in root: URL) -> ParakeetModelState {
        isReady(version, in: root) ? .ready(sizeBytes: sizeBytes(version, in: root)) : .notDownloaded
    }

    static func sizeBytes(_ version: ParakeetVersion, in root: URL) -> Int64? {
        let dir = versionDirectory(version, in: root)
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    static func markComplete(_ version: ParakeetVersion, in root: URL) throws {
        let dir = versionDirectory(version, in: root)
        let marker = Marker(
            version: version.rawValue,
            files: regularFileSizes(in: modelsDirectory(version, in: root)))
        try JSONEncoder().encode(marker).write(
            to: dir.appendingPathComponent(markerName), options: .atomic)
        FileProtection.restrictRecursively(dir)
    }
}

/// Downloads one version into `<root>/parakeet-vN/`, reporting progress in 0...1.
/// Replaceable so the state machine can be tested without a network.
typealias ParakeetDownloader = @Sendable (ParakeetVersion, URL, @escaping @Sendable (Double) -> Void) async throws -> Void

/// The real download, through FluidAudio. Files stream into `.partial` files with HTTP range
/// resume, so a download that was quit or cancelled picks up where it stopped. The first call
/// fetches the compiled models; the second covers the vocabulary and loads each model once, which
/// compiles it for this Mac's Neural Engine so the first dictation isn't the slow one.
let fluidAudioDownloader: ParakeetDownloader = { version, root, progress in
    let versionDir = ParakeetStorage.versionDirectory(version, in: root)
    try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
    let variant = version == .v3 ? ParakeetEncoderPrecision.int8.rawValue : nil
    try await ModelHub.download(
        ParakeetStorage.repo(version), to: versionDir, variant: variant,
        progressHandler: { progress($0.fractionCompleted) })
    try Task.checkCancellation()
    let modelsDir = ParakeetStorage.modelsDirectory(version, in: root)
    try await AsrModels.download(
        to: modelsDir, version: ParakeetStorage.asrVersion(version),
        progressHandler: { progress($0.fractionCompleted) })
    try Task.checkCancellation()
    guard AsrModels.modelsExist(at: modelsDir, version: ParakeetStorage.asrVersion(version)) else {
        throw ProviderError.engineFailed("The download finished but some model files are missing.")
    }
}

/// One loaded model. The real one wraps FluidAudio's `AsrManager`; tests use a counting fake.
protocol ParakeetSession: Sendable {
    func transcribe(samples: [Float], language: String?) async throws -> String
    func cleanup() async
}

typealias ParakeetSessionLoader = @Sendable (ParakeetVersion, URL) async throws -> ParakeetSession

private struct FluidAudioSession: ParakeetSession {
    let asr: AsrManager
    let version: ParakeetVersion

    func transcribe(samples: [Float], language: String?) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let hint = version == .v3 ? language.flatMap { Language(rawValue: $0) } : nil
        return try await asr.transcribe(samples, decoderState: &state, language: hint).text
    }

    func cleanup() async { await asr.cleanup() }
}

let fluidAudioSessionLoader: ParakeetSessionLoader = { version, directory in
    let models = try AsrModels.loadLocal(from: directory, version: ParakeetStorage.asrVersion(version))
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    return FluidAudioSession(asr: asr, version: version)
}

/// Holds one version's loaded models. Loads on first use (or on `preload`), keeps them for the next
/// dictation and lets go of them after `idleSeconds` without one (they take a few hundred MB), unless
/// the version is pinned as the selected voice model.
actor ParakeetEngine {
    private let version: ParakeetVersion
    private let modelsDirectory: URL
    private let idleSeconds: Double
    private let loader: ParakeetSessionLoader
    private var session: ParakeetSession?
    private var loading: Task<ParakeetSession, Error>?
    private var idleTask: Task<Void, Never>?
    private var useCount = 0
    private var pinned = false
    private var pinGeneration = 0

    init(version: ParakeetVersion, modelsDirectory: URL, idleSeconds: Double,
         loader: @escaping ParakeetSessionLoader = fluidAudioSessionLoader) {
        self.version = version
        self.modelsDirectory = modelsDirectory
        self.idleSeconds = idleSeconds
        self.loader = loader
    }

    var isLoaded: Bool { session != nil }

    var isPinned: Bool { pinned }

    func setPinned(_ value: Bool, generation: Int) {
        guard generation >= pinGeneration else { return }
        pinGeneration = generation
        pinned = value
        if value { idleTask?.cancel(); idleTask = nil } else { scheduleIdleUnload() }
    }

    /// Loads the models and runs one second of silence through them, so the Neural Engine compile
    /// happens now and not in the first dictation. Does nothing when already loaded or loading.
    func preload() async throws {
        guard session == nil, loading == nil else { return }
        idleTask?.cancel()
        useCount += 1
        defer {
            useCount -= 1
            scheduleIdleUnload()
        }
        let loaded = try await loadedSession(warmUp: true)
        _ = loaded
    }

    func transcribe(samples: [Float], language: String?) async throws -> String {
        idleTask?.cancel()
        useCount += 1
        defer {
            useCount -= 1
            scheduleIdleUnload()
        }
        let loaded = try await loadedSession(warmUp: false)
        try Task.checkCancellation()
        let text = try await loaded.transcribe(samples: samples, language: language)
        try Task.checkCancellation()
        return text
    }

    func unload() {
        idleTask?.cancel()
        idleTask = nil
        loading?.cancel()
        loading = nil
        if let old = session { Task { await old.cleanup() } }
        session = nil
    }

    private func loadedSession(warmUp: Bool) async throws -> ParakeetSession {
        if let session { return session }
        let task: Task<ParakeetSession, Error>
        if let loading {
            task = loading
        } else {
            let directory = modelsDirectory
            let version = self.version
            let loader = self.loader
            // Unstructured on purpose: one caller giving up must not abort the load another waits on.
            task = Task.detached(priority: .userInitiated) {
                let loaded = try await loader(version, directory)
                if warmUp {
                    _ = try? await loaded.transcribe(
                        samples: [Float](repeating: 0, count: WavReader.requiredSampleRate), language: nil)
                }
                return loaded
            }
            loading = task
        }
        do {
            let loaded = try await task.value
            loading = nil
            session = loaded
            return loaded
        } catch {
            loading = nil
            throw error
        }
    }

    private func scheduleIdleUnload() {
        guard useCount == 0, session != nil, !pinned else { return }
        idleTask?.cancel()
        let seconds = idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard useCount == 0, !pinned else { return }
        unload()
    }
}


/// A Parakeet model as a transcription provider. The check for downloaded files runs on every call,
/// so a model deleted after the provider was made fails with the Settings message.
struct ParakeetProvider: TranscriptionProvider {
    let version: ParakeetVersion
    let root: URL
    let engine: ParakeetEngine

    var name: String { "Parakeet \(version.rawValue) (local)" }

    func transcribe(audio: URL, hint: TranscriptionHint) async throws -> Transcript {
        if let problem = version.languageProblem(for: hint.languagePin) {
            throw ProviderError.engineFailed(problem)
        }
        guard ParakeetStorage.isReady(version, in: root) else {
            throw ProviderError.notConfigured(
                "\(version.displayName) is not downloaded. Download it in Settings to use it.")
        }
        try Task.checkCancellation()

        let samples: [Float]
        do {
            samples = try WavReader.readFloatSamples(from: audio)
        } catch let error as WavReadError {
            throw ProviderError.engineFailed("Could not read the recording (\(error)).")
        } catch {
            throw ProviderError.engineFailed("Could not read the recording.")
        }

        let pin = hint.languagePin
        let code = (pin.isAuto || pin.isMultilingual)
            ? nil : pin.rawValue.components(separatedBy: "-").first?.lowercased()
        do {
            let text = try await engine.transcribe(samples: samples, language: code)
            return Transcript(
                text: text,
                detectedLanguage: version == .v2 ? "en" : nil,
                durationSeconds: Double(samples.count) / Double(WavReader.requiredSampleRate))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderError {
            throw error
        } catch ASRError.invalidAudioData {
            throw ProviderError.engineFailed("The recording is too short for \(version.displayName).")
        } catch {
            throw ProviderError.engineFailed(
                "\(version.displayName) could not transcribe this recording (\(error.localizedDescription)). "
                    + "If it keeps happening, delete and download it again in Settings.")
        }
    }
}

/// Downloads, deletes and runs the Parakeet models.
///
/// Every state comes from what is on disk at launch, then changes as downloads start, finish, fail
/// or are cancelled. The models are loaded the first time a provider transcribes with them.
@MainActor
public final class ParakeetModelManager: ObservableObject {
    @Published public private(set) var states: [ParakeetVersion: ParakeetModelState]

    /// The Parakeet version selected as the voice model, nil when another model is selected. The app
    /// sets it. A pinned version stays loaded: it is never unloaded for being idle.
    public var pinned: ParakeetVersion? {
        didSet {
            // Each change gets a number; an engine ignores a number older than one it has applied,
            // so the tasks below can run in any order and the latest value still wins.
            pinGeneration += 1
            let generation = pinGeneration
            for (version, engine) in engines {
                let isPinned = version == pinned
                Task { await engine.setPinned(isPinned, generation: generation) }
            }
        }
    }
    private var pinGeneration = 0

    private let root: URL
    private let downloader: ParakeetDownloader
    private let idleSeconds: Double
    private let loader: ParakeetSessionLoader
    private let diagnostics: Diagnostics
    private var tasks: [ParakeetVersion: (token: UUID, task: Task<Void, Never>)] = [:]
    private var engines: [ParakeetVersion: ParakeetEngine] = [:]

    public convenience init() {
        self.init(directory: LocalModelStore.defaultDirectory)
    }

    init(directory: URL,
         downloader: @escaping ParakeetDownloader = fluidAudioDownloader,
         idleSeconds: Double = 300,
         loader: @escaping ParakeetSessionLoader = fluidAudioSessionLoader,
         diagnostics: Diagnostics = .shared) {
        self.root = directory
        self.downloader = downloader
        self.idleSeconds = idleSeconds
        self.loader = loader
        self.diagnostics = diagnostics
        states = [:]
        for version in ParakeetVersion.allCases { states[version] = diskState(of: version) }
        Task.detached(priority: .utility) { ParakeetStorage.sweepTrash(in: directory) }
    }

    public func state(of version: ParakeetVersion) -> ParakeetModelState {
        states[version] ?? .notDownloaded
    }

    private func diskState(of version: ParakeetVersion) -> ParakeetModelState {
        ParakeetStorage.diskState(version, in: root)
    }

    public func download(_ version: ParakeetVersion) {
        switch state(of: version) {
        case .downloading, .ready: return
        case .notDownloaded, .failed: break
        }
        states[version] = .downloading(progress: nil)
        let token = UUID()
        let root = self.root
        let downloader = self.downloader
        // Detached so the file work (marker, permissions, directory walk) stays off the main actor.
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                try await downloader(version, root) { fraction in
                    Task { @MainActor in self?.reportProgress(fraction, version: version, token: token) }
                }
                try Task.checkCancellation()
                try ParakeetStorage.markComplete(version, in: root)
                let state = ParakeetStorage.diskState(version, in: root)
                await self?.finish(version, token: token, result: .success(state))
            } catch {
                await self?.finish(version, token: token, result: .failure(error))
            }
        }
        tasks[version] = (token, task)
    }

    private func reportProgress(_ fraction: Double, version: ParakeetVersion, token: UUID) {
        guard tasks[version]?.token == token else { return }
        let clamped = min(max(fraction, 0), 1)
        // Two download stages report in turn; never let the bar go backwards.
        if case .downloading(let previous?) = state(of: version), previous >= clamped { return }
        states[version] = .downloading(progress: clamped)
    }

    private func finish(_ version: ParakeetVersion, token: UUID, result: Result<ParakeetModelState, Error>) {
        // A cancel or delete already moved on; a stale task must not overwrite it.
        guard tasks[version]?.token == token else { return }
        tasks[version] = nil
        guard case .failure(let error) = result else {
            if case .success(let state) = result { states[version] = state }
            if case .notDownloaded = states[version] {
                states[version] = .failed("The download finished but the model files are incomplete. Try again.")
            } else {
                preload(version)
            }
            return
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            states[version] = .notDownloaded
            return
        }
        states[version] = .failed(Self.readable(error))
    }

    private static func readable(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet
            || urlError.code == .networkConnectionLost {
            return "No internet connection. Connect and try again."
        }
        if let provider = error as? ProviderError, case .engineFailed(let message) = provider {
            return message
        }
        return "The download failed (\(error.localizedDescription)). Try again."
    }

    /// Stops a running download. What was fetched stays on disk so the next try resumes, but the
    /// model is not ready until a download finishes.
    public func cancelDownload(_ version: ParakeetVersion) {
        guard let running = tasks[version] else { return }
        running.task.cancel()
        tasks[version] = nil
        states[version] = .notDownloaded
    }

    /// Removes the model's files and frees its memory.
    public func delete(_ version: ParakeetVersion) throws {
        if let running = tasks[version] {
            running.task.cancel()
            tasks[version] = nil
        }
        if let engine = engines.removeValue(forKey: version) {
            Task { await engine.unload() }
        }
        // Rename is instant, so the folder is gone from the app's point of view at once; the slow
        // recursive removal of the renamed folder runs in the background.
        let dir = ParakeetStorage.versionDirectory(version, in: root)
        do {
            if FileManager.default.fileExists(atPath: dir.path) {
                let trash = root.appendingPathComponent(
                    "\(ParakeetStorage.trashPrefix)\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.moveItem(at: dir, to: trash)
                Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: trash) }
            }
        } catch {
            states[version] = diskState(of: version)
            throw error
        }
        states[version] = .notDownloaded
    }

    /// A provider for `version`. When the model isn't ready its `transcribe` throws
    /// `ProviderError.notConfigured` with a message that says to download it in Settings.
    public func provider(for version: ParakeetVersion) -> TranscriptionProvider {
        ParakeetProvider(version: version, root: root, engine: engine(for: version))
    }

    private func engine(for version: ParakeetVersion) -> ParakeetEngine {
        if let existing = engines[version] { return existing }
        let engine = ParakeetEngine(
            version: version,
            modelsDirectory: ParakeetStorage.modelsDirectory(version, in: root),
            idleSeconds: idleSeconds,
            loader: loader)
        engines[version] = engine
        if version == pinned {
            let generation = pinGeneration
            Task { await engine.setPinned(true, generation: generation) }
        }
        return engine
    }

    /// Loads a downloaded model in the background and runs a second of silence through it, so the
    /// slow first load (a Neural Engine compile) happens now and not in the first dictation. Does
    /// nothing when the model isn't downloaded or is already loaded or loading. Never throws; a
    /// failure goes to Diagnostics and the next dictation loads the model as usual.
    public func preload(_ version: ParakeetVersion) {
        // The published state only: a hotkey press never reads the disk on the main thread.
        // The engine itself returns at once when it is already loaded or loading.
        guard case .ready = state(of: version) else { return }
        let engine = self.engine(for: version)
        let diagnostics = self.diagnostics
        Task.detached(priority: .utility) {
            do {
                try await engine.preload()
            } catch {
                diagnostics.failure("parakeet", error, context: "preloading \(version.displayName)")
            }
        }
    }

    /// Whether `version`'s engine is pinned right now.
    func isPinned(_ version: ParakeetVersion) async -> Bool {
        guard let engine = engines[version] else { return false }
        return await engine.isPinned
    }

    /// Whether `version`'s models are in memory right now.
    func isLoaded(_ version: ParakeetVersion) async -> Bool {
        guard let engine = engines[version] else { return false }
        return await engine.isLoaded
    }
}
