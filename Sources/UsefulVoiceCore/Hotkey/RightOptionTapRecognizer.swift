import Foundation

/// Detects a clean tap of the Right Option key from a raw event stream.
/// Pure logic so it's unit-testable; HotkeyManager feeds it CGEvents.
public struct RightOptionTapRecognizer {
    public enum Event {
        case rightOptionDown(at: TimeInterval)
        case rightOptionUp(at: TimeInterval)
        case otherKeyDown
    }

    /// Max seconds between down and up to count as a tap.
    public let maxTapDuration: TimeInterval
    private var downAt: TimeInterval?
    private var invalidated = false

    public init(maxTapDuration: TimeInterval = 0.6) {
        self.maxTapDuration = maxTapDuration
    }

    /// Returns true when a complete tap is recognized.
    public mutating func handle(_ event: Event) -> Bool {
        switch event {
        case .rightOptionDown(let time):
            downAt = time
            invalidated = false
            return false
        case .otherKeyDown:
            invalidated = true
            return false
        case .rightOptionUp(let time):
            defer { downAt = nil }
            guard let down = downAt, !invalidated else { return false }
            return time - down <= maxTapDuration
        }
    }
}
