import Foundation

/// Download state for one model, as reported to the UI.
public enum ModelDownloadState: Equatable, Sendable {
    case idle
    case downloading(received: Int64, total: Int64)
    /// The file is down and the SHA-256 is being verified.
    case validating
    case paused(resumeAvailable: Bool)
    case failed(String, ModelDownloadFailureKind)
}

/// Why a download failed, so the UI can say something specific without
/// parsing the message.
public enum ModelDownloadFailureKind: Equatable, Sendable {
    /// The disk is full.
    case disk
    /// The connection dropped or never came up.
    case network
    /// Hugging Face answered with a non-success status.
    case http
    /// The downloaded file failed its size, magic or checksum check.
    case validation
    /// The file could not be staged or moved into place.
    case install

    /// Maps a system error to a kind: out of space is the only one worth its own copy.
    static func classify(_ error: Error) -> ModelDownloadFailureKind {
        if error is URLError { return .network }
        let ns = error as NSError
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) { return .disk }
        return .install
    }
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
    /// Identity of the live attempt per model, from `start` through staging,
    /// resume persistence and validation. `delete` removes it under `lock`;
    /// every filesystem write and emitted event checks it under that same lock,
    /// so a stale attempt writes and reports nothing.
    private var attempts: [String: UUID] = [:]
    private var taskTokens: [Int: UUID] = [:]
    /// Per-task flags, keyed by taskIdentifier: the attempt started from saved
    /// resume data, and a failure found while staging the file (HTTP status,
    /// move error).
    private var resumedTasks: Set<Int> = []
    private var stageFailures: [Int: (message: String, kind: ModelDownloadFailureKind)] = [:]

    private struct FinishedTask {
        let model: WhisperModel
        let token: UUID?
        let resumed: Bool
        let stageFailure: (message: String, kind: ModelDownloadFailureKind)?
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

    /// Whether a download or its validation is currently running for the model.
    public func isDownloading(_ model: WhisperModel) -> Bool {
        lock.withLock { attempts[model.id] != nil }
    }

    /// Starts (or resumes) the download for `model`.
    ///
    /// Saved resume data is consumed here: it is read and deleted before the
    /// attempt begins, so only resume data returned by this attempt can ever be
    /// reused. An already-running download for the same model is a no-op.
    public func start(model: WhisperModel) {
        let token = UUID()
        let saved: Data? = lock.withLock {
            guard attempts[model.id] == nil else { return nil }
            attempts[model.id] = token
            store.prepare()
            let data = store.resumeData(for: model)
            store.clearResumeData(for: model)
            return data
        }
        guard lock.withLock({ attempts[model.id] == token }) else { return }
        launch(model: model, resumeData: saved, token: token)
    }

    /// Validates and activates a complete `.partial` left behind when the app
    /// quit during the verify step. No-op unless the file is exactly the
    /// expected size and nothing is running for the model.
    public func recoverCompletePartial(for model: WhisperModel) {
        let token = UUID()
        let claimed = lock.withLock { () -> Bool in
            guard attempts[model.id] == nil,
                  store.partialBytes(for: model) == model.expectedBytes else { return false }
            attempts[model.id] = token
            emit(.validating, for: model)
            return true
        }
        if claimed { validateAndActivate(model: model, token: token) }
    }

    private func launch(model: WhisperModel, resumeData: Data?, token: UUID) {
        let started: URLSessionDownloadTask? = lock.withLock {
            guard attempts[model.id] == token else { return nil }
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: URLRequest(url: model.downloadURL))
            }
            tasks[task.taskIdentifier] = model
            taskTokens[task.taskIdentifier] = token
            activeTasks[model.id] = task
            if resumeData != nil { resumedTasks.insert(task.taskIdentifier) }
            emit(.downloading(received: 0, total: model.expectedBytes), for: model)
            return task
        }
        started?.resume()
    }

    /// Pauses a running download, keeping resume data so `start` continues
    /// where it left off. Safe to call when nothing is running.
    public func pause(model: WhisperModel) {
        let task = lock.withLock { activeTasks[model.id] }
        task?.cancel(byProducingResumeData: { _ in })
    }

    /// Pauses every running download and waits, up to `timeout` seconds, for
    /// the resume data to be written to disk. Called at app quit: without it
    /// the process dies with the bytes already downloaded unrecoverable.
    public func pauseAll(timeout: TimeInterval) {
        let running = lock.withLock {
            activeTasks.compactMap { entry -> (model: WhisperModel, token: UUID, task: URLSessionDownloadTask)? in
                guard let model = tasks[entry.value.taskIdentifier],
                      let token = taskTokens[entry.value.taskIdentifier] else { return nil }
                return (model, token, entry.value)
            }
        }
        let group = DispatchGroup()
        for (model, token, task) in running {
            group.enter()
            task.cancel(byProducingResumeData: { [weak self] data in
                if let data, let self {
                    self.lock.withLock {
                        if self.attempts[model.id] == token { _ = self.persist(data, for: model) }
                    }
                }
                group.leave()
            })
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    /// Deletes the model's files because the user asked. Invalidates the live
    /// attempt and removes the files under the same lock every attempt write
    /// takes, so a late delegate callback can neither recreate the partial nor
    /// report Paused, Failed or a finished install.
    public func delete(model: WhisperModel) throws {
        let task: URLSessionDownloadTask? = lock.withLock {
            attempts.removeValue(forKey: model.id)
            return activeTasks[model.id]
        }
        task?.cancel()
        try lock.withLock { try store.delete(model) }
    }

    /// Whether `start` will continue from saved resume data. Matches what
    /// `start` actually does: a leftover `.partial` file is never reused.
    public func canResume(_ model: WhisperModel) -> Bool {
        store.resumeData(for: model) != nil
    }

    /// Saves resume data, reporting a failed write instead of swallowing it.
    /// Caller holds `lock` and has checked the attempt is current.
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

    /// Caller holds `lock` and has checked the attempt is current. The events
    /// receiver only hops to another actor, so emitting under the lock is safe.
    private func emit(_ state: ModelDownloadState, for model: WhisperModel) {
        events?.modelDownload(self, didUpdate: state, for: model)
    }

    private func taskModel(_ task: URLSessionTask) -> WhisperModel? {
        lock.withLock { tasks[task.taskIdentifier] }
    }

    /// Drops the per-task bookkeeping. The attempt itself stays live: it ends
    /// only when validation, a failure or a pause finishes it.
    private func clear(_ task: URLSessionTask) -> FinishedTask? {
        lock.withLock {
            let id = task.taskIdentifier
            guard let model = tasks.removeValue(forKey: id) else { return nil }
            if activeTasks[model.id] === task { activeTasks.removeValue(forKey: model.id) }
            return FinishedTask(
                model: model,
                token: taskTokens.removeValue(forKey: id),
                resumed: resumedTasks.remove(id) != nil,
                stageFailure: stageFailures.removeValue(forKey: id))
        }
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        lock.withLock {
            guard let model = tasks[downloadTask.taskIdentifier],
                  let token = taskTokens[downloadTask.taskIdentifier],
                  attempts[model.id] == token else { return }
            let total = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite
                : model.expectedBytes
            emit(.downloading(received: totalBytesWritten, total: total), for: model)
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this delegate method returns, so the
        // move to the partial path happens synchronously here, under the lock
        // and only while the attempt is still current. Validation and
        // activation run in didCompleteWithError, which follows.
        lock.withLock {
            let id = downloadTask.taskIdentifier
            guard let model = tasks[id], let token = taskTokens[id],
                  attempts[model.id] == token else { return }
            // A 429 or 5xx still "finishes" with an error page as the body. Never
            // stage that: record the failure and let completion report it.
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                stageFailures[id] =
                    ("Hugging Face returned HTTP \(http.statusCode). Try again later.", .http)
                return
            }
            do {
                let staged = store.partialURL(for: model)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.moveItem(at: location, to: staged)
                FileProtection.restrict(staged, isDirectory: false)
            } catch {
                stageFailures[id] =
                    ("could not stage the download: \(error.localizedDescription)",
                     ModelDownloadFailureKind.classify(error))
            }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let finished = clear(task) else { return }
        let model = finished.model
        guard let token = finished.token else { return }

        enum Next { case nothing, relaunch, validate }
        let next: Next = lock.withLock {
            // Deleted mid-download (the attempt was invalidated): the delete
            // already removed every artifact. Write and emit nothing.
            guard attempts[model.id] == token else { return .nothing }

            if let error {
                let urlError = error as? URLError
                // cancel(byProducingResumeData:) and resumable failures deliver
                // the blob through the error's userInfo. Only a blob returned by
                // THIS attempt is ever persisted.
                let fresh = urlError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                let saved = fresh.map { persist($0, for: model) } ?? false
                if urlError?.code == .cancelled {
                    attempts.removeValue(forKey: model.id)
                    emit(.paused(resumeAvailable: saved), for: model)
                } else if finished.resumed && !saved {
                    // The resumed attempt failed and left nothing to continue
                    // from: the saved blob was stale or unusable. Drop it and try
                    // once from scratch, rather than failing every retry the
                    // same way.
                    store.clearDownloadState(for: model)
                    return .relaunch
                } else {
                    attempts.removeValue(forKey: model.id)
                    emit(.failed(urlError?.localizedDescription ?? error.localizedDescription,
                                 .classify(error)),
                         for: model)
                }
                return .nothing
            }

            if let failure = finished.stageFailure {
                store.clearDownloadState(for: model)
                attempts.removeValue(forKey: model.id)
                emit(.failed(failure.message, failure.kind), for: model)
                return .nothing
            }

            emit(.validating, for: model)
            return .validate
        }

        switch next {
        case .nothing: break
        case .relaunch: launch(model: model, resumeData: nil, token: token)
        case .validate: validateAndActivate(model: model, token: token)
        }
    }

    /// Validates the staged file, then installs it. The checksum runs on a
    /// background queue (hashing 1-3 GB takes a second or two) without the
    /// lock; the commit and every event after it re-check the attempt under the
    /// lock, so a delete during validation suppresses all of it.
    private func validateAndActivate(model: WhisperModel, token: UUID) {
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let failure: (message: String, kind: ModelDownloadFailureKind)?
            do {
                try store.validateDownloadedFile(for: model)
                failure = nil
            } catch let storeError as ModelStoreError {
                switch storeError {
                case .validationFailed(let reason):
                    failure = ("download failed validation: \(reason)", .validation)
                case .activationFailed(let detail):
                    failure = ("could not install the model: \(detail)", .install)
                }
            } catch {
                failure = ("could not install the model", .install)
            }
            self.lock.withLock {
                guard self.attempts[model.id] == token else { return }
                var message = failure
                if message == nil {
                    do {
                        try store.commitDownloadedFile(for: model)
                    } catch let storeError as ModelStoreError {
                        if case .activationFailed(let detail) = storeError {
                            message = ("could not install the model: \(detail)", .install)
                        } else {
                            message = ("could not install the model", .install)
                        }
                    } catch {
                        message = ("could not install the model", .install)
                    }
                }
                self.attempts.removeValue(forKey: model.id)
                if let message {
                    store.clearDownloadState(for: model)
                    self.emit(.failed(message.message, message.kind), for: model)
                } else {
                    self.emit(.idle, for: model)
                }
            }
        }
    }
}
