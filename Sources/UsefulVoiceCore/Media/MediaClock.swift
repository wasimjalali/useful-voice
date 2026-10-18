import Foundation

/// A handle that cancels scheduled work.
public struct MediaClockToken: Sendable {
    private let cancelAction: @Sendable () -> Void

    public init(cancel: @escaping @Sendable () -> Void) { cancelAction = cancel }
    public func cancel() { cancelAction() }
}

/// Every wait, window, tick and delay of `MediaPausePolicy` goes through this, so tests drive the
/// policy with a virtual clock and no media test depends on real time.
public protocol MediaClock: AnyObject, Sendable {
    func now() -> Date
    /// Waits `seconds` on the calling thread (the policy's own queue).
    func sleep(_ seconds: TimeInterval)
    /// Runs `work` on `queue` once, `delay` from now.
    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> MediaClockToken
    /// Runs `work` on `queue` every `interval`, the first time `interval` from now.
    func every(_ interval: TimeInterval, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) -> MediaClockToken
}

/// The real clock.
public final class RealMediaClock: MediaClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    public func schedule(after delay: TimeInterval, on queue: DispatchQueue,
                         _ work: @escaping @Sendable () -> Void) -> MediaClockToken {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return MediaClockToken { item.cancel() }
    }

    public func every(_ interval: TimeInterval, on queue: DispatchQueue,
                      _ work: @escaping @Sendable () -> Void) -> MediaClockToken {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: work)
        timer.resume()
        return MediaClockToken { timer.cancel() }
    }
}
