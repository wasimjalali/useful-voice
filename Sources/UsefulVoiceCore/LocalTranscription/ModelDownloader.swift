import Foundation

/// Download state for one model, as reported to the UI.
public enum ModelDownloadState: Equatable, Sendable {
    case idle
    case downloading(received: Int64, total: Int64)
    /// The file is down and the SHA-256 is being verified.
    case validating
    case paused(resumeAvailable: Bool)
    case failed(String)
}

/// Receives download events. Called on an arbitrary queue — the app-layer
/// manager hops to the main actor.
public protocol ModelDownloadEvents: AnyObject, Sendable {
    func modelDownload(_ downloader: ModelDownloader,
                       didUpdate state: ModelDownloadState,
                       for model: WhisperModel)
}

/// Fetches model weights from Hugging Face with progress and resume.
///
/// Design notes:
///
/// - `URLSessionDownloadTask` rather than `dataTask`, because a multi-GB model
///   must stream to disk — buffering it in memory would defeat the point of
///   running on an 8 GB machine.
/// - Resume is two-layered: `cancelByProducingResumeData` gives in-session
///   resume, and the resume blob is also persisted to `*.resume` so a failed or
///   quit-and-relaunched download can continue from the partial file.
/// - The destination filename differs from the partial name (`*.partial`), so
///   a finished-but-unvalidated file is never confused with an installed model.
/// - Validation (size + magic + SHA-256) runs before activation; a failed check
///   discards the file rather than leaving poison on disk.
///
/// @unchecked Sendable: all mutable state lives behind `lock`; the delegate is
/// only read.
public final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public weak var events: (any ModelDownloadEvents)?

    private let store: LocalModelStore
    private let lock = NSLock()
    private var session: URLSession!
    private var tasks: [Int: WhisperModel] = [:]           // taskIdentifier -> model
    private var activeTasks: [String: URLSessionDownloadTask] = [:] // model.id -> task
    /// Progress for a task that is running but has not reported a byte yet.
    private var receivedBytes: [String: Int64] = [:]
    private var expectedBytes: [String: Int64] = [:]

    public init(store: LocalModelStore = LocalModelStore()) {
        self.store = store
        super.init()
        let config = URLSessionConfiguration.default
        // Idle timeout only; a GB-scale download legitimately takes minutes.
        config.timeoutIntervalForResource = 60 * 60
        self.session = URLSession(configuration: config, delegate: self,
                                  delegateQueue: nil)
    }

    /// Whether a download is currently running for the model.
    public func isDownloading(_ model: WhisperModel) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeTasks[model.id] != nil
    }

    /// Starts (or resumes) the download for `model`.
    ///
    /// If persisted resume data exists it is used; otherwise the request starts
    /// fresh. An already-running download for the same model is a no-op.
    public func start(model: WhisperModel) {
        lock.lock()
        if activeTasks[model.id] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        store.prepare()
        let task: URLSessionDownloadTask
        if let resumeData = store.resumeData(for: model), !resumeData.isEmpty {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: URLRequest(url: model.downloadURL))
        }
        lock.lock()
        tasks[task.taskIdentifier] = model
        activeTasks[model.id] = task
        receivedBytes[model.id] = 0
        expectedBytes[model.id] = model.expectedBytes
        lock.unlock()
        emit(.downloading(received: 0, total: model.expectedBytes), for: model)
        task.resume()
    }

    /// Pauses a running download, keeping resume data so `start` continues
    /// where it left off. Safe to call when nothing is running.
    public func pause(model: WhisperModel) {
        lock.lock()
        let task = activeTasks[model.id]
        lock.unlock()
        task?.cancel(byProducingResumeData: { _ in })
    }

    /// Whether the model has state worth resuming (a partial file or saved
    /// resume data).
    public func canResume(_ model: WhisperModel) -> Bool {
        store.partialBytes(for: model) > 0 || store.resumeData(for: model) != nil
    }

    private func emit(_ state: ModelDownloadState, for model: WhisperModel) {
        events?.modelDownload(self, didUpdate: state, for: model)
    }

    private func taskModel(_ task: URLSessionTask) -> WhisperModel? {
        lock.lock(); defer { lock.unlock() }
        return tasks[task.taskIdentifier]
    }

    private func clear(_ task: URLSessionTask) -> WhisperModel? {
        lock.lock(); defer { lock.unlock() }
        guard let model = tasks.removeValue(forKey: task.taskIdentifier) else { return nil }
        activeTasks.removeValue(forKey: model.id)
        receivedBytes.removeValue(forKey: model.id)
        expectedBytes.removeValue(forKey: model.id)
        return model
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard let model = taskModel(downloadTask) else { return }
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : model.expectedBytes
        emit(.downloading(received: totalBytesWritten, total: total), for: model)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this delegate method returns, so the
        // move to the partial path happens synchronously here. Validation and
        // activation run in didCompleteWithError, which follows.
        guard let model = taskModel(downloadTask) else { return }
        do {
            let staged = store.partialURL(for: model)
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: location, to: staged)
            FileProtection.restrict(staged, isDirectory: false)
        } catch {
            emit(.failed("could not stage the download: \(error.localizedDescription)"),
                 for: model)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let model = clear(task) else { return }

        if let error {
            let urlError = error as? URLError
            // A cancelled task leaves resume data behind only if we saved it.
            if urlError?.code == .cancelled {
                // cancel(byProducingResumeData:) delivers the blob through this
                // same error path's userInfo.
                let resumeData = urlError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                if let resumeData { store.saveResumeData(resumeData, for: model) }
                emit(.paused(resumeAvailable: resumeData != nil || store.partialBytes(for: model) > 0),
                     for: model)
            } else {
                // Persist whatever resume data URLSession offers so the next
                // attempt can continue rather than restarting a GB download.
                if let resumeData = urlError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    store.saveResumeData(resumeData, for: model)
                }
                emit(.failed(urlError?.localizedDescription ?? error.localizedDescription),
                     for: model)
            }
            return
        }

        // Success: validate before activating. The checksum runs on a
        // background queue — hashing 1-3 GB takes a second or two.
        emit(.validating, for: model)
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try store.activateDownloadedFile(for: model)
                self?.emit(.idle, for: model)
            } catch let storeError as ModelStoreError {
                store.clearDownloadState(for: model)
                switch storeError {
                case .validationFailed(let reason):
                    self?.emit(.failed("download failed validation: \(reason)"), for: model)
                case .activationFailed(let detail):
                    self?.emit(.failed("could not install the model: \(detail)"), for: model)
                }
            } catch {
                store.clearDownloadState(for: model)
                self?.emit(.failed("could not install the model"), for: model)
            }
        }
    }
}
