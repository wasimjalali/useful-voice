import Foundation

/// Pure state machine: returns true when audio has been below the RMS
/// threshold for longer than the timeout. Spec section 8: default 60s.
/// A quiet first sample seeds the clock; it must not fire immediately.
public struct SilenceWatchdog {
    private let threshold: Float
    private let timeout: TimeInterval
    private var lastLoudAt: TimeInterval?

    public init(threshold: Float = 0.01, timeout: TimeInterval) {
        self.threshold = threshold
        self.timeout = timeout
    }

    /// Feed an RMS level with a monotonic timestamp. True means "stop now".
    public mutating func observe(rms: Float, at time: TimeInterval) -> Bool {
        if rms >= threshold || lastLoudAt == nil {
            lastLoudAt = time
            return false
        }
        return time - lastLoudAt! > timeout
    }
}
