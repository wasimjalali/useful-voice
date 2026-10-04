import Foundation
import UsefulVoiceCore

/// Bridges the core model store/downloader into observable state for the
/// Settings UI. All reads and writes funnel through here so the page always
/// reflects the directory on disk plus any in-flight download.
@MainActor
final class LocalModelManager: ObservableObject {
    /// Per-model download state, keyed by model id. Absent = idle.
    @Published private(set) var downloadStates: [String: ModelDownloadState] = [:]
    /// Per-model on-disk availability, keyed by model id.
    @Published private(set) var availability: [String: LocalModelAvailability] = [:]
    /// The model the local engine will use.
    @Published private(set) var activeModelID: String

    /// What changed, so the app layer can unload engine memory only when the
    /// loaded model is actually affected.
    enum Change {
        case downloaded(WhisperModel)
        case downloadFailed(WhisperModel)
        case deleted(WhisperModel)
        case activated(WhisperModel)
    }

    /// Set when the last delete could not remove every file, so the UI can say
    /// the model is still on disk. Cleared by the next delete, download or
    /// activation, and once the file is gone.
    @Published private(set) var deleteError: String?
    private var deleteErrorModelID: String?

    /// Called after anything that could change provider usability: a download
    /// finished, a model was deleted, the active model switched. The app layer
    /// refreshes its status line and unloads stale engine memory here.
    var onModelsChanged: ((Change) -> Void)?

    /// Called when the user switches engine in Settings, so leaving local frees
    /// the whisper context.
    var onEngineChanged: ((TranscriptionEngineChoice) -> Void)?

    private let settings: AppSettings
    private let store: LocalModelStore
    private let downloader: ModelDownloader

    init(settings: AppSettings,
         store: LocalModelStore = LocalModelStore(),
         downloader: ModelDownloader? = nil) {
        self.settings = settings
        self.store = store
        self.downloader = downloader ?? ModelDownloader(store: store)
        self.activeModelID = settings.localModelID
        self.downloader.events = self
        store.prepare()
        refreshAvailability()
        // A quit during the verify step leaves a complete .partial behind:
        // finish installing it instead of making the user download again.
        for model in WhisperModelCatalog.all where availability[model.id] != .usable {
            self.downloader.recoverCompletePartial(for: model)
        }
    }

    var models: [WhisperModel] { WhisperModelCatalog.all }

    var activeModel: WhisperModel {
        WhisperModelCatalog.model(forID: activeModelID) ?? WhisperModelCatalog.default
    }

    func state(for model: WhisperModel) -> ModelDownloadState {
        downloadStates[model.id] ?? .idle
    }

    func availability(of model: WhisperModel) -> LocalModelAvailability {
        availability[model.id] ?? store.availability(of: model)
    }

    func isActive(_ model: WhisperModel) -> Bool { model.id == activeModelID }

    /// Re-reads the directory. Cheap (size + 4-byte magic per model), safe to
    /// call on every Settings appearance.
    func refreshAvailability() {
        var next: [String: LocalModelAvailability] = [:]
        for model in models {
            next[model.id] = store.availability(of: model)
        }
        availability = next
        if let id = deleteErrorModelID, next[id] == .missing {
            deleteError = nil
        }
    }

    func installedBytes(for model: WhisperModel) -> Int64? {
        store.installedBytes(for: model)
    }

    /// Bytes a partial download has already fetched.
    func partialBytes(for model: WhisperModel) -> Int64 {
        store.partialBytes(for: model)
    }

    func totalBytesOnDisk() -> Int64 {
        store.totalBytesOnDisk()
    }

    // MARK: - Actions

    func download(_ model: WhisperModel) {
        deleteError = nil
        downloadStates[model.id] = .downloading(received: 0, total: model.expectedBytes)
        downloader.start(model: model)
    }

    func pause(_ model: WhisperModel) {
        downloader.pause(model: model)
    }

    func canResume(_ model: WhisperModel) -> Bool {
        downloader.canResume(model)
    }

    /// Makes the model the one local transcription uses. Takes effect on the
    /// next dictation; the engine lazily swaps contexts.
    /// `allowUnusable` is for the first-run flow, which commits a model that is
    /// still downloading and restores the earlier one if setup is abandoned.
    func activate(_ model: WhisperModel, allowUnusable: Bool = false) {
        guard allowUnusable || availability(of: model) == .usable else { return }
        guard model.id != activeModelID else { return }
        deleteError = nil
        activeModelID = model.id
        settings.localModelID = model.id
        onModelsChanged?(.activated(model))
    }

    func engineChanged(to engine: TranscriptionEngineChoice) {
        onEngineChanged?(engine)
    }

    /// Pauses every running download and waits briefly for resume data to be
    /// written. Called at app quit.
    func pauseAllDownloads() {
        downloader.pauseAll(timeout: 3)
    }

    func delete(_ model: WhisperModel) {
        deleteError = nil
        var failure: String?
        do {
            try downloader.delete(model: model)
        } catch {
            failure = "Could not delete \(model.displayName): \(error.localizedDescription) Close other apps using it and try again."
            Diagnostics.shared.error(
                "models", "could not delete \(model.fileName): \(error.localizedDescription)")
        }
        downloadStates[model.id] = .idle
        refreshAvailability()
        deleteError = failure
        deleteErrorModelID = failure == nil ? nil : model.id
        onModelsChanged?(.deleted(model))
    }

    /// A one-line summary for the status area, e.g. "2 models · 4.7 GB used".
    var diskSummary: String {
        let installed = models.filter { availability(of: $0) == .usable }.count
        let bytes = ByteCountFormatter.string(fromByteCount: totalBytesOnDisk(),
                                              countStyle: .file)
        return "\(installed) of \(models.count) models downloaded · \(bytes) on disk"
    }
}

extension LocalModelManager: ModelDownloadEvents {
    nonisolated func modelDownload(_ downloader: ModelDownloader,
                                   didUpdate state: ModelDownloadState,
                                   for model: WhisperModel) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.downloadStates[model.id] = state
            if state == .idle {
                // Terminal success state: the file was validated and activated.
                self.refreshAvailability()
                self.onModelsChanged?(.downloaded(model))
            } else if case .failed = state {
                self.refreshAvailability()
                self.onModelsChanged?(.downloadFailed(model))
            }
        }
    }
}
