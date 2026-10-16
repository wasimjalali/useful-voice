import Foundation

/// Runs the cleanup model on demand and keeps it in memory only while it is being used.
///
/// - `begin()` is called when a dictation starts: it starts loading the weights in the
///   background while the person is still talking, counts the dictation as in progress and
///   cancels any pending unload.
/// - `end()` is called when that dictation ends or is cancelled, once per `begin`: when no
///   dictation is left in progress it starts the idle timer.
/// - `clean` answers nil at once when the weights are not loaded (never loaded, unloaded
///   after idling, or a load is still running) or another run is in progress: a dictation
///   never waits for a model that cannot answer in time. A cold `clean` starts the load, so
///   the next dictation finds the model ready. When the weights are loaded it runs the model,
///   and starts the idle timer only when no dictation is in progress, so a `clean` that
///   finishes after the next dictation's `begin` cannot unload under that dictation.
///   Nothing here ever throws to the caller: a load or run error is logged and `clean`
///   returns nil, so the pipeline keeps the rules text.
/// - After `idleUnloadAfter` (60 s by default) with no dictation in progress and no `clean`,
///   the weights are freed. An unload asked for during a load or a run waits for it to end.
/// - A load that fails is remembered for that file (path, size, modification time): the next
///   presses do not retry it until the file changes or the app relaunches.
///
/// - `shutDown(timeout:)` is for quit: no new load or run starts, a running one is asked to
///   stop, and the call waits a bounded time for the dispatch threads to leave the runtime, so
///   the process does not exit under a live thread inside llama.cpp.
///
/// An actor with a small state machine. The blocking load and run happen on dispatch threads,
/// never on the actor and never on Swift's small cooperative pool; the state guarantees a
/// load, a run and an unload never overlap.
public actor LocalCleanupModel: CleanupModel {
    private enum State { case unloaded, loading, loaded }

    /// Counts the dispatch threads that are inside the generator, and refuses new ones once
    /// `close` has been called. Lock protected, so quit can use it from outside the actor.
    private final class ThreadGate: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = false
        private let group = DispatchGroup()

        /// False once closed. A true answer must be paired with `leave`.
        func enter() -> Bool {
            lock.withLock {
                if closed { return false }
                group.enter()
                return true
            }
        }

        func leave() { group.leave() }
        func close() { lock.withLock { closed = true } }
        /// True when every thread left within the timeout.
        func wait(timeout: TimeInterval) -> Bool { group.wait(timeout: .now() + timeout) == .success }
    }

    private let generator: any CleanupTextGenerator
    private let modelURL: URL
    private let idleUnloadAfter: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let gate = ThreadGate()
    private var state = State.unloaded
    private var loadTask: Task<Void, Never>?
    private var running = false
    /// `unload()` arrived while a load or a run was in flight: free the weights when it ends.
    private var unloadWhenIdle = false
    private var activeDictations = 0
    private var idleTask: Task<Void, Never>?
    private var idleGeneration = 0
    /// The file signature of a load that failed; the load is not retried while it is unchanged.
    private var failedSignature: String?

    public init(
        modelURL: URL, generator: any CleanupTextGenerator,
        idleUnloadAfter: Duration = CleanupModelPolicy.defaultIdleUnload,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.modelURL = modelURL
        self.generator = generator
        self.idleUnloadAfter = idleUnloadAfter
        self.sleep = sleep
    }

    public var isLoaded: Bool { state == .loaded }

    /// Returns when a load that is running has finished (tests, and the real-weights check).
    public func waitForLoad() async {
        await loadTask?.value
    }

    /// At quit: stops new loads and runs, asks the one in flight to stop and waits up to
    /// `timeout` seconds for its thread to leave the generator. Returns whether it did.
    /// Callable from any thread, and does not touch the actor's state.
    @discardableResult
    public nonisolated func shutDown(timeout: TimeInterval) -> Bool {
        gate.close()
        generator.requestStop()
        return gate.wait(timeout: timeout)
    }

    public func begin() {
        activeDictations += 1
        unloadWhenIdle = false
        cancelIdleTimer()
        startLoadIfNeeded()
    }

    public func end() {
        activeDictations = max(0, activeDictations - 1)
        if activeDictations == 0 { armIdleTimer() }
    }

    public func unload() {
        cancelIdleTimer()
        if state == .loading || running {
            unloadWhenIdle = true
        } else if state == .loaded {
            unloadWeights()
        }
    }

    public func clean(_ text: String, controlLine: String, deadline: ContinuousClock.Instant) async -> String? {
        cancelIdleTimer()
        defer { if activeDictations == 0 && state == .loaded && !running { armIdleTimer() } }
        guard state == .loaded else {
            startLoadIfNeeded()
            return nil
        }
        guard !running, ContinuousClock.now < deadline, gate.enter() else { return nil }
        running = true
        let generator = self.generator
        let gate = self.gate
        let prompt = S1MiniModel.promptSegments(controlLine: controlLine, text: text)
        let outcome: Result<String, any Error> = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try generator.generate(prompt: prompt, deadline: deadline) }
                gate.leave()
                continuation.resume(returning: result)
            }
        }
        running = false
        if unloadWhenIdle {
            unloadWhenIdle = false
            unloadWeights()
        }
        switch outcome {
        case .success(let output): return output
        case .failure(let error):
            Diagnostics.shared.warning("cleanup-model", "run failed: \(error)")
            return nil
        }
    }

    private func startLoadIfNeeded() {
        guard state == .unloaded else { return }
        let signature = fileSignature()
        if signature == failedSignature { return }
        guard gate.enter() else { return }
        state = .loading
        unloadWhenIdle = false
        let generator = self.generator
        let gate = self.gate
        let url = modelURL
        // The load blocks (disk, weights, a GPU library), so it runs on a dispatch thread and
        // never on Swift's cooperative pool, which a blocked load would starve.
        loadTask = Task { [weak self] in
            let failure: (any Error)? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try generator.load(modelAt: url)
                        gate.leave()
                        continuation.resume(returning: nil)
                    } catch {
                        gate.leave()
                        continuation.resume(returning: error)
                    }
                }
            }
            await self?.finishLoad(failure, signature: signature)
        }
    }

    private func finishLoad(_ failure: (any Error)?, signature: String) {
        loadTask = nil
        if let failure {
            Diagnostics.shared.warning(
                "cleanup-model", "load failed: \(failure); not retrying until the model file changes")
            failedSignature = signature
            unloadWhenIdle = false
            state = .unloaded
            return
        }
        if unloadWhenIdle {
            unloadWhenIdle = false
            unloadWeights()
            return
        }
        state = .loaded
        // A load that nobody is using (started by a cold `clean`) must not stay in memory.
        if activeDictations == 0 { armIdleTimer() }
    }

    /// Path, size and modification time of the weights; "missing" when the file is not there.
    private func fileSignature() -> String {
        let path = modelURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "\(path)|missing" }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(path)|\(size)|\(modified)"
    }

    private func cancelIdleTimer() {
        idleTask?.cancel()
        idleTask = nil
        idleGeneration += 1
    }

    private func armIdleTimer() {
        idleTask?.cancel()
        idleGeneration += 1
        let generation = idleGeneration
        let delay = idleUnloadAfter
        let sleep = self.sleep
        idleTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            await self?.unloadIfIdle(generation: generation)
        }
    }

    private func unloadIfIdle(generation: Int) {
        guard generation == idleGeneration, state == .loaded, !running else { return }
        unloadWeights()
        idleTask = nil
    }

    /// Frees the weights inside the thread gate, so `shutDown` waits for it like for a load or
    /// a run. Once the gate is closed (quit) nothing is freed and the state stays as it was:
    /// the process is exiting.
    private func unloadWeights() {
        guard gate.enter() else { return }
        generator.unload()
        gate.leave()
        state = .unloaded
    }
}
