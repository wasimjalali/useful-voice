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

    static func isReady(_ version: ParakeetVersion, in root: URL) -> Bool {
        let dir = versionDirectory(version, in: root)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(markerName).path) else {
            return false
        }
        return AsrModels.modelsExist(
            at: modelsDirectory(version, in: root), version: asrVersion(version))
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
        try Data(version.rawValue.utf8).write(
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

/// Holds one version's loaded models. Loads on first use, keeps them for the next dictation and
/// lets go of them after `idleSeconds` without one (the models take a few hundred MB of memory).
actor ParakeetEngine {
    private let version: ParakeetVersion
    private let modelsDirectory: URL
    private let idleSeconds: Double
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?
    private var idleTask: Task<Void, Never>?
    private var useCount = 0

    init(version: ParakeetVersion, modelsDirectory: URL, idleSeconds: Double) {
        self.version = version
        self.modelsDirectory = modelsDirectory
        self.idleSeconds = idleSeconds
    }

    var isLoaded: Bool { manager != nil }

    func transcribe(samples: [Float], language: String?) async throws -> String {
        idleTask?.cancel()
        useCount += 1
        defer {
            useCount -= 1
            scheduleIdleUnload()
        }
        let asr = try await loadedManager()
        try Task.checkCancellation()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let hint = version == .v3 ? language.flatMap { Language(rawValue: $0) } : nil
        let result = try await asr.transcribe(samples, decoderState: &state, language: hint)
        try Task.checkCancellation()
        return result.text
    }

    func unload() {
        idleTask?.cancel()
        idleTask = nil
        loading?.cancel()
        loading = nil
        if let asr = manager { Task { await asr.cleanup() } }
        manager = nil
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        let task: Task<AsrManager, Error>
        if let loading {
            task = loading
        } else {
            let directory = modelsDirectory
            let asrVersion = ParakeetStorage.asrVersion(version)
            // Unstructured on purpose: one caller giving up must not abort the load another waits on.
            task = Task.detached(priority: .userInitiated) {
                let models = try AsrModels.loadLocal(from: directory, version: asrVersion)
                let asr = AsrManager(config: .default)
                try await asr.loadModels(models)
                return asr
            }
            loading = task
        }
        do {
            let asr = try await task.value
            loading = nil
            manager = asr
            return asr
        } catch {
            loading = nil
            throw error
        }
    }

    private func scheduleIdleUnload() {
        guard useCount == 0, manager != nil else { return }
        idleTask?.cancel()
        let seconds = idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard useCount == 0 else { return }
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

    private let root: URL
    private let downloader: ParakeetDownloader
    private let idleSeconds: Double
    private var tasks: [ParakeetVersion: (token: UUID, task: Task<Void, Never>)] = [:]
    private var engines: [ParakeetVersion: ParakeetEngine] = [:]

    public convenience init() {
        self.init(directory: LocalModelStore.defaultDirectory)
    }

    init(directory: URL,
         downloader: @escaping ParakeetDownloader = fluidAudioDownloader,
         idleSeconds: Double = 300) {
        self.root = directory
        self.downloader = downloader
        self.idleSeconds = idleSeconds
        states = [:]
        for version in ParakeetVersion.allCases { states[version] = diskState(of: version) }
    }

    public func state(of version: ParakeetVersion) -> ParakeetModelState {
        states[version] ?? .notDownloaded
    }

    private func diskState(of version: ParakeetVersion) -> ParakeetModelState {
        ParakeetStorage.isReady(version, in: root)
            ? .ready(sizeBytes: ParakeetStorage.sizeBytes(version, in: root))
            : .notDownloaded
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
        let task = Task { [weak self] in
            do {
                try await downloader(version, root) { fraction in
                    Task { @MainActor in self?.reportProgress(fraction, version: version, token: token) }
                }
                try Task.checkCancellation()
                try ParakeetStorage.markComplete(version, in: root)
                self?.finish(version, token: token, error: nil)
            } catch {
                self?.finish(version, token: token, error: error)
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

    private func finish(_ version: ParakeetVersion, token: UUID, error: Error?) {
        // A cancel or delete already moved on; a stale task must not overwrite it.
        guard tasks[version]?.token == token else { return }
        tasks[version] = nil
        guard let error else {
            states[version] = diskState(of: version)
            if case .notDownloaded = states[version] {
                states[version] = .failed("The download finished but the model files are incomplete. Try again.")
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
        let dir = ParakeetStorage.versionDirectory(version, in: root)
        do {
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
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
        let engine: ParakeetEngine
        if let existing = engines[version] {
            engine = existing
        } else {
            engine = ParakeetEngine(
                version: version,
                modelsDirectory: ParakeetStorage.modelsDirectory(version, in: root),
                idleSeconds: idleSeconds)
            engines[version] = engine
        }
        return ParakeetProvider(version: version, root: root, engine: engine)
    }

    /// Whether `version`'s models are in memory right now.
    func isLoaded(_ version: ParakeetVersion) async -> Bool {
        guard let engine = engines[version] else { return false }
        return await engine.isLoaded
    }
}
