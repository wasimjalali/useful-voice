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
/// - Resume data comes from URLSession only when a task is cancelled with
///   `cancel(byProducingResumeData:)` (Pause, or `pauseAll` on quit) or fails
///   with a resumable error. That blob is persisted to `*.resume` and is
///   single-use: `start` consumes it, so a stale blob can never trap every
///   retry. A resumed attempt that fails without fresh resume data falls back
///   once to a fresh download. A crash or force-quit produces no resume data,
///   so those bytes are lost; a normal quit does persist it (see `pauseAll`).
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
    /// Per-task flags, keyed by taskIdentifier: the attempt started from saved
    /// resume data, the user deleted the model mid-download, and a failure
    /// found while staging the file (HTTP status, move error).
    private var resumedTasks: Set<Int> = []
    private var discardedTasks: Set<Int> = []
    private var stageFailures: [Int: String] = [:]

    private struct FinishedTask {
        let model: WhisperModel
        let resumed: Bool
        let discarded: Bool
        let stageFailure: String?
    }

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
    /// Saved resume data is consumed here: it is read and deleted before the
    /// attempt begins, so only resume data returned by this attempt can ever be
    /// reused. An already-running download for the same model is a no-op.
    public func start(model: WhisperModel) {
        lock.lock()
        if activeTasks[model.id] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        store.prepare()
        let saved = store.resumeData(for: model)
        store.clearResumeData(for: model)
        launch(model: model, resumeData: saved)
    }

    private func launch(model: WhisperModel, resumeData: Data?) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: URLRequest(url: model.downloadURL))
        }
        lock.lock()
        tasks[task.taskIdentifier] = model
        activeTasks[model.id] = task
        receivedBytes[model.id] = 0
        expectedBytes[model.id] = model.expectedBytes
        if resumeData != nil { resumedTasks.insert(task.taskIdentifier) }
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

    /// Pauses every running download and waits, up to `timeout` seconds, for
    /// the resume data to be written to disk. Called at app quit: without it
    /// the process dies with the bytes already downloaded unrecoverable.
    public func pauseAll(timeout: TimeInterval) {
        lock.lock()
        let running = activeTasks.map { (model: tasks[$0.value.taskIdentifier], task: $0.value) }
        lock.unlock()
        let group = DispatchGroup()
        for (model, task) in running {
            guard let model else { continue }
            group.enter()
            task.cancel(byProducingResumeData: { [weak self] data in
                if let data { _ = self?.persist(data, for: model) }
                group.leave()
            })
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    /// Cancels a running download because the model is being deleted. No resume
    /// data is produced and the late completion is ignored, so nothing is
    /// recreated on disk and the UI never flips to Paused.
    public func discard(model: WhisperModel) {
        lock.lock()
        let task = activeTasks[model.id]
        if let task { discardedTasks.insert(task.taskIdentifier) }
        lock.unlock()
        task?.cancel()
    }

    /// Whether `start` will continue from saved resume data. Matches what
    /// `start` actually does: a leftover `.partial` file is never reused.
    public func canResume(_ model: WhisperModel) -> Bool {
        store.resumeData(for: model) != nil
    }

    /// Saves resume data, reporting a failed write instead of swallowing it.
    private func persist(_ data: Data, for model: WhisperModel) -> Bool {
        do {
            try store.saveResumeData(data, for: model)
            return true
        } catch {
            Diagnostics.shared.error(
                "models", "could not save resume data for \(model.fileName): \(error.localizedDescription)")
            return false
        }
    }

    private func emit(_ state: ModelDownloadState, for model: WhisperModel) {
        events?.modelDownload(self, didUpdate: state, for: model)
    }

    private func taskModel(_ task: URLSessionTask) -> WhisperModel? {
        lock.lock(); defer { lock.unlock() }
        return tasks[task.taskIdentifier]
    }

    private func clear(_ task: URLSessionTask) -> FinishedTask? {
        lock.lock(); defer { lock.unlock() }
        let id = task.taskIdentifier
        guard let model = tasks.removeValue(forKey: id) else { return nil }
        activeTasks.removeValue(forKey: model.id)
        receivedBytes.removeValue(forKey: model.id)
        expectedBytes.removeValue(forKey: model.id)
        return FinishedTask(
            model: model,
            resumed: resumedTasks.remove(id) != nil,
            discarded: discardedTasks.remove(id) != nil,
            stageFailure: stageFailures.removeValue(forKey: id))
    }

    private func isDiscarded(_ task: URLSessionTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return discardedTasks.contains(task.taskIdentifier)
    }

    private func recordStageFailure(_ message: String, for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        stageFailures[task.taskIdentifier] = message
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
        guard let model = taskModel(downloadTask), !isDiscarded(downloadTask) else { return }
        // A 429 or 5xx still "finishes" with an error page as the body. Never
        // stage that: record the failure and let completion report it.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            recordStageFailure(
                "Hugging Face returned HTTP \(http.statusCode). Try again later.",
                for: downloadTask)
            return
        }
        do {
            let staged = store.partialURL(for: model)
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: location, to: staged)
            FileProtection.restrict(staged, isDirectory: false)
        } catch {
            recordStageFailure(
                "could not stage the download: \(error.localizedDescription)",
                for: downloadTask)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let finished = clear(task) else { return }
        let model = finished.model

        // Deleted mid-download: the delete already removed every artifact.
        // Emit nothing so the late completion cannot show Paused or recreate
        // resume data.
        if finished.discarded { return }

        if let error {
            let urlError = error as? URLError
            // cancel(byProducingResumeData:) and resumable failures deliver the
            // blob through the error's userInfo. Only a blob returned by THIS
            // attempt is ever persisted.
            let fresh = urlError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            let saved = fresh.map { persist($0, for: model) } ?? false
            if urlError?.code == .cancelled {
                emit(.paused(resumeAvailable: saved), for: model)
            } else if finished.resumed && !saved {
                // The resumed attempt failed and left nothing to continue from:
                // the saved blob was stale or unusable. Drop it and try once
                // from scratch, rather than failing every retry the same way.
                store.clearDownloadState(for: model)
                launch(model: model, resumeData: nil)
            } else {
                emit(.failed(urlError?.localizedDescription ?? error.localizedDescription),
                     for: model)
            }
            return
        }

        if let failure = finished.stageFailure {
            store.clearDownloadState(for: model)
            emit(.failed(failure), for: model)
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
