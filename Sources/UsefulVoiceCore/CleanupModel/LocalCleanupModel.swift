import Foundation

/// Runs the cleanup model on demand and keeps it in memory only while it is being used.
///
/// - `begin()` is called when a dictation starts: it loads the weights while the person is
///   still talking, counts the dictation as in progress and cancels any pending unload.
/// - `end()` is called when that dictation ends or is cancelled, once per `begin`: when no
///   dictation is left in progress it starts the idle timer.
/// - `clean` loads on demand if `begin` was not called or the weights were unloaded, runs the
///   model, and starts the idle timer only when no dictation is in progress. So a `clean`
///   that finishes after the next dictation's `begin` cannot unload under that dictation.
///   Nothing here ever throws to the caller: a load or run error is logged and `clean`
///   returns nil, so the pipeline keeps the rules text.
/// - After `idleUnloadAfter` (60 s by default) with no dictation in progress and no `clean`,
///   the weights are freed.
///
/// An actor, so a load, a run and an unload never overlap.
public actor LocalCleanupModel: CleanupModel {
    private let generator: any CleanupTextGenerator
    private let modelURL: URL
    private let idleUnloadAfter: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var loaded = false
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

    public var isLoaded: Bool { loaded }

    public func begin() {
        activeDictations += 1
        cancelIdleTimer()
        _ = ensureLoaded()
    }

    public func end() {
        activeDictations = max(0, activeDictations - 1)
        if activeDictations == 0 { armIdleTimer() }
    }

    public func unload() {
        cancelIdleTimer()
        if loaded {
            generator.unload()
            loaded = false
        }
    }

    public func clean(_ text: String, controlLine: String, deadline: ContinuousClock.Instant) async -> String? {
        cancelIdleTimer()
        defer { if activeDictations == 0 { armIdleTimer() } }
        guard ContinuousClock.now < deadline, ensureLoaded() else { return nil }
        do {
            return try generator.generate(
                prompt: S1MiniModel.prompt(controlLine: controlLine, text: text), deadline: deadline)
        } catch {
            Diagnostics.shared.warning("cleanup-model", "run failed: \(error)")
            return nil
        }
    }

    private func ensureLoaded() -> Bool {
        if loaded { return true }
        do {
            try generator.load(modelAt: modelURL)
            loaded = true
        } catch {
            Diagnostics.shared.warning("cleanup-model", "load failed: \(error)")
        }
        return loaded
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
        guard generation == idleGeneration, loaded else { return }
        generator.unload()
        loaded = false
        idleTask = nil
    }
}
