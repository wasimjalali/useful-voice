import Foundation

/// When a recording will stop on its own, as absolute dates, so any thread can
/// turn them into a countdown without asking the audio pipeline again.
public struct AutoStopDeadlines: Equatable, Sendable {
    /// When continued silence ends the recording. Nil before the first buffer.
    public var silence: Date?
    /// When the maximum recording length ends it.
    public var max: Date?

    public static let none = AutoStopDeadlines(silence: nil, max: nil)

    public init(silence: Date?, max: Date?) {
        self.silence = silence
        self.max = max
    }

    /// Deadlines for a session that began at `startedAt`. The watchdog's times
    /// are seconds since `startedAt`, the same base the recorder feeds it.
    public init(startedAt: Date, watchdog: SilenceWatchdog, maxDuration: TimeInterval) {
        self.silence = watchdog.silenceDeadline.map { startedAt.addingTimeInterval($0) }
        self.max = startedAt.addingTimeInterval(maxDuration)
    }
}

/// How the dock and HUD turn a deadline into "Stops in 5 s".
public enum AutoStopCountdown {
    /// Only the last `window` seconds are shown.
    public static let window: TimeInterval = 5

    /// Whole seconds left, rounded up, or nil when there is no deadline or more
    /// than `window` seconds remain. Never negative.
    public static func seconds(until deadline: Date?, now: Date) -> Int? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        guard remaining <= window else { return nil }
        return Int(max(0, remaining).rounded(.up))
    }
}
