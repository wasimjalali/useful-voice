import Foundation

/// Rules, then (only when the gates allow) the local model with the guard.
/// `windows/src/core/formatting/cleanupPipeline.ts` mirrors this file rule for rule.
///
/// The caller runs this at the cleanup marker, after vocabulary and before the user's own
/// rules. Dictation never waits on the model: it gets at most `deadline` after this call
/// starts, and anything short of a guard-approved answer yields the rules-only text.
///
///   1. `CleanupRules` run on the raw text (English only).
///   2. Rules left nothing or only whitespace (the whole dictation was fillers): the raw text is the result, so
///      History and the clipboard never get an empty entry. The model is not asked.
///   3. `CleanupModelPolicy.decide` (flag, model downloaded, 8 GB class of RAM, English): when it
///      says skip, the rules text is the result.
///   4. The model gets the rules text and the control line, up to the deadline. A timeout,
///      nil (error, nothing returned) or an answer the guard rejects (too many words
///      dropped, content added, a changed number or negation, wrapper text, empty) is
///      replaced by the rules text.
public enum CleanupPipeline {
    public enum Source: Equatable, Sendable {
        /// The raw text: no rules applied, or the rules left nothing.
        case raw
        case rules
        case model
    }

    public enum ModelOutcome: Equatable, Sendable {
        case skipped(CleanupModelPolicy.SkipReason)
        case accepted
        case timedOut
        /// The model returned nil: it could not load, it errored or it had nothing.
        case failed
        case rejected(CleanupGuard.Reason)
    }

    public struct Result: Equatable, Sendable {
        public var text: String
        public var source: Source
        /// Nil when the rules left nothing and the model was never considered.
        public var model: ModelOutcome?
    }

    public struct Gates: Equatable, Sendable {
        public var flagOn: Bool
        public var modelInstalled: Bool
        public var physicalMemoryBytes: UInt64

        public init(flagOn: Bool, modelInstalled: Bool, physicalMemoryBytes: UInt64) {
            self.flagOn = flagOn
            self.modelInstalled = modelInstalled
            self.physicalMemoryBytes = physicalMemoryBytes
        }

        /// The live values: the hidden flag, the pinned weights present and valid in `store`,
        /// and this machine's RAM.
        public static func current(store: LocalModelStore = LocalModelStore()) -> Gates {
            Gates(
                flagOn: CleanupModelFlag.isOn,
                modelInstalled: store.availability(of: S1MiniModel.model) == .usable,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        }
    }

    public static func run(
        raw: String, language: String?, category: String?, style: String?,
        gates: Gates, model: (any CleanupModel)?,
        deadline: Duration = CleanupModelPolicy.defaultDeadline
    ) async -> Result {
        let start = ContinuousClock.now
        let rulesText = CleanupRules.apply(to: raw, language: language)
        if rulesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Result(text: raw, source: .raw, model: nil)
        }
        let rulesSource: Source = rulesText == raw ? .raw : .rules

        let decision = CleanupModelPolicy.decide(
            flagOn: gates.flagOn, modelInstalled: gates.modelInstalled,
            physicalMemoryBytes: gates.physicalMemoryBytes, language: language)
        if case .skip(let reason) = decision {
            return Result(text: rulesText, source: rulesSource, model: .skipped(reason))
        }
        guard let model else {
            return Result(text: rulesText, source: rulesSource, model: .skipped(.noModel))
        }

        let controlLine = CleanupControlLine.line(category: category, style: style)
        let limit = start.advanced(by: deadline)
        let answer = await withDeadline(limit) {
            await model.clean(rulesText, controlLine: controlLine, deadline: limit)
        }
        switch answer {
        case .timedOut:
            return Result(text: rulesText, source: rulesSource, model: .timedOut)
        case .finished(nil):
            return Result(text: rulesText, source: rulesSource, model: .failed)
        case .finished(let output?):
            switch CleanupGuard.evaluate(rulesText: rulesText, modelOutput: output) {
            case .accept(let cleaned):
                return Result(text: cleaned, source: .model, model: .accepted)
            case .reject(let reason):
                return Result(text: rulesText, source: rulesSource, model: .rejected(reason))
            }
        }
    }

    enum Raced<T: Sendable>: Sendable {
        case finished(T)
        case timedOut
    }

    /// Returns the work's value, or `.timedOut` at `limit`, whichever comes first. The work is
    /// not awaited after the limit (a structured task group would wait for it), so a model
    /// that ignores cancellation cannot hold the dictation up. Its late result is dropped.
    static func withDeadline<T: Sendable>(
        _ limit: ContinuousClock.Instant, _ work: @escaping @Sendable () async -> T
    ) async -> Raced<T> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Raced<T>, Never>) in
            let once = Once(continuation)
            let worker = Task {
                let value = await work()
                once.resume(.finished(value))
            }
            let timer = Task {
                do { try await Task.sleep(until: limit, clock: .continuous) } catch { return }
                once.resume(.timedOut)
            }
            once.track(worker, timer)
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Raced<T>, Never>?
        private var tasks: [Task<Void, Never>] = []
        private var finished = false

        init(_ continuation: CheckedContinuation<Raced<T>, Never>) { self.continuation = continuation }

        /// Registers the two racers. If one already finished, the other is cancelled now.
        func track(_ worker: Task<Void, Never>, _ timer: Task<Void, Never>) {
            lock.lock()
            tasks = [worker, timer]
            let done = finished
            lock.unlock()
            if done { worker.cancel(); timer.cancel() }
        }

        /// The first call resumes the caller and cancels both racers; later calls do nothing.
        func resume(_ value: Raced<T>) {
            lock.lock()
            let c = continuation
            continuation = nil
            finished = true
            let racers = tasks
            lock.unlock()
            guard let c else { return }
            c.resume(returning: value)
            racers.forEach { $0.cancel() }
        }
    }
}
