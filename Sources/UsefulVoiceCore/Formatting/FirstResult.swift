import Foundation

/// Resumes a continuation once, from whichever caller gets there first. Used to bound a
/// wait: one task delivers the answer, another a timeout, and the later one is ignored.
public final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    public init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    public func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension TextBeforeCursor {
    /// The result of `read`, or nil when it takes longer than `seconds`. The wait ends at
    /// the limit even if `read` never returns, so a stuck reader cannot hold up a dictation.
    public static func bounded(seconds: TimeInterval, _ read: Task<String?, Never>) async -> String? {
        await withCheckedContinuation { continuation in
            let first = FirstResult<String?>(continuation)
            Task { first.resume(await read.value) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                first.resume(nil)
            }
        }
    }
}
