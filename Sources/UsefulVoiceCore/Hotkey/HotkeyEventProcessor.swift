import Foundation

/// The decision logic of the global hotkey tap, kept free of CGEvent so it can be
/// unit tested. `HotkeyManager` turns each CGEvent into an `Input`, calls
/// `process`, and acts on the `Outcome`.
///
/// What it decides:
/// - which modifier transitions are real (per-side, from the device-dependent
///   flag bits, so holding Left Command while tapping Right Command still works);
/// - which events cancel a pending tap (a key press, a click or drag, a scroll
///   that is not trackpad momentum; never a key release);
/// - the Esc pair: the key-down consumed while recording and its key-up.
public struct HotkeyEventProcessor {
    public enum Input: Equatable {
        case flagsChanged(keycode: Int64, rawFlags: UInt64)
        case keyDown(keycode: Int64)
        case keyUp(keycode: Int64)
        /// A mouse button went down, or the pointer was dragged with one held.
        case pointerDown
        /// `momentumPhase` is `CGEventField.scrollWheelEventMomentumPhase`: zero for
        /// the fingers' own motion and for a mouse wheel, non-zero while the
        /// trackpad coasts after the fingers lift.
        case scroll(momentumPhase: Int64)
    }

    public enum Fire: Equatable {
        case toggle
        case languageSwitch
        case cancel
    }

    public struct Outcome: Equatable {
        public var fire: Fire?
        /// True when the event must not reach the frontmost app.
        public var consume: Bool
        public static let passThrough = Outcome(fire: nil, consume: false)
    }

    public static let escapeKeycode: Int64 = 53

    /// Device-dependent bits of `CGEventFlags.rawValue` (IOKit NX_DEVICE*KEYMASK).
    private static let deviceBit: [Int64: UInt64] = [
        61: 0x40,    // right option
        58: 0x20,    // left option
        54: 0x10,    // right command
        55: 0x08,    // left command
        62: 0x2000,  // right control
        59: 0x01,    // left control
        60: 0x04,    // right shift
        56: 0x02,    // left shift
    ]

    /// Both device bits of the modifier class a keycode belongs to, and the class flag.
    private static let classInfo: [Int64: (flag: UInt64, deviceBits: UInt64)] = [
        61: (0x80000, 0x40 | 0x20), 58: (0x80000, 0x40 | 0x20),     // option
        54: (0x100000, 0x10 | 0x08), 55: (0x100000, 0x10 | 0x08),   // command
        62: (0x40000, 0x2000 | 0x01), 59: (0x40000, 0x2000 | 0x01), // control
        60: (0x20000, 0x04 | 0x02), 56: (0x20000, 0x04 | 0x02),     // shift
        63: (0x800000, 0),                                          // fn / globe
    ]

    /// Whether the modifier key `keycode` is down according to `rawFlags`.
    ///
    /// The class flag (Command, Shift, ...) says only that some key of the class is
    /// down. The device bits say which side. When the event carries device bits for
    /// the class they decide; when it carries none (a synthetic event, Fn) the class
    /// flag is all there is.
    public static func isDown(keycode: Int64, rawFlags: UInt64) -> Bool {
        let info = classInfo[keycode] ?? classInfo[61]!
        guard rawFlags & info.flag != 0 else { return false }
        guard let own = deviceBit[keycode], rawFlags & info.deviceBits != 0 else { return true }
        return rawFlags & own != 0
    }

    /// Per-key "was down last time we saw it", so a modifier is read as a real transition.
    private var lastDownState: [Int64: Bool] = [:]
    // One generic modifier-tap detector per tap-key (its event names are historical).
    private var activationRecognizer = RightOptionTapRecognizer()
    private var languageSwitchRecognizer = RightOptionTapRecognizer()
    /// An Esc key-down was consumed and its key-up (or auto-repeats) has not come yet.
    private var escapeDownConsumed = false

    public init() {}

    /// Forget everything in flight. Call when the event tap is re-enabled after
    /// macOS disabled it: events were lost, so a remembered "down" would eat the
    /// next real press and a pending tap could complete from a stale down.
    public mutating func reset() {
        lastDownState.removeAll()
        activationRecognizer = RightOptionTapRecognizer()
        languageSwitchRecognizer = RightOptionTapRecognizer()
        escapeDownConsumed = false
    }

    public mutating func process(_ input: Input,
                                 activationKeycode: Int64,
                                 languageSwitchKeycode: Int64,
                                 isRecording: Bool,
                                 now: TimeInterval) -> Outcome {
        switch input {
        case .flagsChanged(let keycode, let rawFlags):
            guard keycode == activationKeycode || keycode == languageSwitchKeycode else {
                // A different modifier changed: it ends any pending tap.
                invalidatePendingTaps()
                return .passThrough
            }
            let isDown = Self.isDown(keycode: keycode, rawFlags: rawFlags)
            // Ignore repeats: only a real transition counts.
            guard lastDownState[keycode] != isDown else { return .passThrough }
            lastDownState[keycode] = isDown

            let isActivation = keycode == activationKeycode
            var recognizer = isActivation ? activationRecognizer : languageSwitchRecognizer
            let fired = recognizer.handle(isDown ? .rightOptionDown(at: now)
                                                : .rightOptionUp(at: now))
            if isActivation { activationRecognizer = recognizer } else { languageSwitchRecognizer = recognizer }
            guard fired else { return .passThrough }
            return Outcome(fire: isActivation ? .toggle : .languageSwitch, consume: false)

        case .keyDown(let keycode):
            if keycode == Self.escapeKeycode {
                if isRecording {
                    escapeDownConsumed = true
                    return Outcome(fire: .cancel, consume: true)
                }
                if escapeDownConsumed {
                    // Auto-repeat of the Esc we already took, after the recording ended.
                    return Outcome(fire: nil, consume: true)
                }
            }
            invalidatePendingTaps()
            return .passThrough

        case .keyUp(let keycode):
            // A release says nothing about a tap in progress. Only the Esc whose
            // key-down we consumed is taken, so the app never sees an unpaired key-up.
            if keycode == Self.escapeKeycode, escapeDownConsumed {
                escapeDownConsumed = false
                return Outcome(fire: nil, consume: true)
            }
            return .passThrough

        case .pointerDown:
            invalidatePendingTaps()
            return .passThrough

        case .scroll(let momentumPhase):
            // Trackpad momentum keeps arriving after the fingers lift, often during
            // the next tap. Only real scrolling ends a pending tap.
            if momentumPhase == 0 { invalidatePendingTaps() }
            return .passThrough
        }
    }

    private mutating func invalidatePendingTaps() {
        _ = activationRecognizer.handle(.otherKeyDown)
        _ = languageSwitchRecognizer.handle(.otherKeyDown)
    }
}
