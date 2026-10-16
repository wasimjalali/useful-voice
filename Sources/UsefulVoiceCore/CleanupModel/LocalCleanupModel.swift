import Foundation

/// Runs the cleanup model on demand and keeps it in memory only while it is being used.
///
/// - `begin()` is called when a dictation starts: it starts loading the weights in the
///   background while the person is still talking, counts the dictation as in progress and
///   cancels any pending unload.
/// - `end()` is called when that dictation ends or is cancelled, once per `begin`: when no
///   dictation is left in progress it starts the idle timer.
/// - `clean` answers nil at once when the weights are not loaded (never loaded, unloaded
///   after idling, or a load is still running): a dictation never waits for a model that
///   cannot answer in time. A cold `clean` starts the load, so the next dictation finds the
///   model ready. When the weights are loaded it runs the model, and starts the idle timer
///   only when no dictation is in progress, so a `clean` that finishes after the next
///   dictation's `begin` cannot unload under that dictation.
///   Nothing here ever throws to the caller: a load or run error is logged and `clean`
///   returns nil, so the pipeline keeps the rules text.
/// - After `idleUnloadAfter` (60 s by default) with no dictation in progress and no `clean`,
///   the weights are freed.
///
/// An actor with a small state machine: the blocking load runs off the actor, a run and an
/// unload run on it, and the state guarantees the three never overlap.
public actor LocalCleanupModel: CleanupModel {
    private enum State { case unloaded, loading, loaded }

    private let generator: any CleanupTextGenerator
    private let modelURL: URL
    private let idleUnloadAfter: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var state = State.unloaded
    private var loadTask: Task<Void, Never>?
    /// `unload()` arrived while a load was running: free the weights as soon as it ends.
    private var unloadWhenLoaded = false
    private var activeDictations = 0
    private var idleTask: Task<Void, Never>?
    private var idleGeneration = 0

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

    public func begin() {
        activeDictations += 1
        cancelIdleTimer()
        startLoadIfNeeded()
    }

    public func end() {
        activeDictations = max(0, activeDictations - 1)
        if activeDictations == 0 { armIdleTimer() }
    }

    public func unload() {
        cancelIdleTimer()
        switch state {
        case .loaded:
            generator.unload()
            state = .unloaded
        case .loading:
            unloadWhenLoaded = true
        case .unloaded:
            break
        }
    }

    public func clean(_ text: String, controlLine: String, deadline: ContinuousClock.Instant) async -> String? {
        cancelIdleTimer()
        defer { if activeDictations == 0 && state == .loaded { armIdleTimer() } }
        guard state == .loaded else {
            startLoadIfNeeded()
            return nil
        }
        guard ContinuousClock.now < deadline else { return nil }
        do {
            return try generator.generate(
                prompt: S1MiniModel.prompt(controlLine: controlLine, text: text), deadline: deadline)
        } catch {
            Diagnostics.shared.warning("cleanup-model", "run failed: \(error)")
            return nil
        }
    }

    private func startLoadIfNeeded() {
        // A dictation that starts while an unload-after-load is pending wants the weights kept.
        if state == .loading { unloadWhenLoaded = false }
        guard state == .unloaded else { return }
        state = .loading
        unloadWhenLoaded = false
        let generator = self.generator
        let url = modelURL
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            var failure: (any Error)?
            do { try generator.load(modelAt: url) } catch { failure = error }
            await self?.finishLoad(failure)
        }
    }

    private func finishLoad(_ failure: (any Error)?) {
        loadTask = nil
        if let failure {
            Diagnostics.shared.warning("cleanup-model", "load failed: \(failure)")
            state = .unloaded
            return
        }
        if unloadWhenLoaded {
            unloadWhenLoaded = false
            generator.unload()
            state = .unloaded
            return
        }
        state = .loaded
        // A load that nobody is using (started by a cold `clean`) must not stay in memory.
        if activeDictations == 0 { armIdleTimer() }
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
        guard generation == idleGeneration, state == .loaded else { return }
        generator.unload()
        state = .unloaded
        idleTask = nil
    }
}
