import AppKit
import UsefulVoiceCore

/// The activation keys a user can pick for toggling dictation. All are modifier
/// keys that produce a clean tap without typing a character.
struct HotkeyOption: Identifiable, Hashable {
    let label: String
    let keycode: Int
    var id: Int { keycode }

    static let all: [HotkeyOption] = [
        .init(label: "Right Option", keycode: 61),
        .init(label: "Left Option", keycode: 58),
        .init(label: "Right Command", keycode: 54),
        .init(label: "Right Control", keycode: 62),
        .init(label: "Right Shift", keycode: 60),
        .init(label: "Fn / Globe", keycode: 63),
    ]

    static func label(for keycode: Int) -> String {
        all.first { $0.keycode == keycode }?.label ?? "Right Option"
    }
}

/// System-wide key listener via CGEventTap.
/// - Right Command tap -> onToggle (dictation)
/// - Right Shift tap -> onLanguageSwitch
/// - Esc while recording -> onCancel (the Esc event is consumed)
/// Requires Accessibility trust. Spec sections 4 and 8.
final class HotkeyManager {
    private static let escapeKeycode: Int64 = 53

    /// The modifier key whose tap toggles dictation. Default Right Command (54).
    /// Updatable live: the tap listens to all flagsChanged and filters here, so
    /// changing this takes effect without restarting the tap.
    var activationKeycode: Int64 = 54
    /// The modifier key whose tap flips the dictation language. Default Right
    /// Shift (60), the Shift key under Return, by explicit user choice. The
    /// Settings layer keeps it distinct from the dictation key.
    var languageSwitchKeycode: Int64 = 60

    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Language key tap: flip the dictation language between English and German.
    var onLanguageSwitch: (() -> Void)?

    /// The flag a given modifier keycode sets while held, used to read down/up.
    static func flagMask(for keycode: Int64) -> CGEventFlags {
        switch keycode {
        case 61, 58: return .maskAlternate     // right / left option
        case 54, 55: return .maskCommand        // right / left command
        case 62, 59: return .maskControl        // right / left control
        case 60: return .maskShift              // right shift
        case 63: return .maskSecondaryFn        // fn / globe
        default: return .maskAlternate
        }
    }
    /// The app layer tells us whether a recording is active so we know
    /// when Esc belongs to us.
    var isRecordingActive: (() -> Bool) = { false }

    // One tap recognizer per tap-key. The type is a generic modifier-tap
    // detector (its event names are historical, from the original Right Option).
    private var activationRecognizer = RightOptionTapRecognizer()
    private var languageSwitchRecognizer = RightOptionTapRecognizer()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    enum HotkeyError: Error { case tapCreationFailed }

    func start() throws {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(refcon!).takeUnretainedValue()
                return manager.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { throw HotkeyError.tapCreationFailed }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    deinit {
        // The CGEventTap holds an unretained pointer back to self. If this
        // object is freed without stop(), the live tap would call back into
        // freed memory (use-after-free). stop() is idempotent.
        stop()
    }

    private func handle(type: CGEventType,
                        event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables taps that stall; re-enable and move on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .flagsChanged where keycode == activationKeycode:
            // The mask is set when EITHER side of the modifier is down. We have
            // already filtered to the specific keycode, so this is our key.
            // Edge case (unchanged): holding the other side of the same modifier
            // keeps the mask set, so the up event won't register. Acceptable.
            let isDown = event.flags.contains(Self.flagMask(for: keycode))
            if activationRecognizer.handle(isDown ? .rightOptionDown(at: now)
                                                  : .rightOptionUp(at: now)) {
                DispatchQueue.main.async { [weak self] in self?.onToggle?() }
            }
        case .flagsChanged where keycode == languageSwitchKeycode:
            let isDown = event.flags.contains(Self.flagMask(for: keycode))
            if languageSwitchRecognizer.handle(isDown ? .rightOptionDown(at: now)
                                                      : .rightOptionUp(at: now)) {
                DispatchQueue.main.async { [weak self] in self?.onLanguageSwitch?() }
            }
        case .keyDown where keycode == Self.escapeKeycode:
            if isRecordingActive() {
                DispatchQueue.main.async { [weak self] in self?.onCancel?() }
                return nil // consume Esc so the frontmost app never sees it
            }
        case .keyDown:
            // Any other key invalidates a pending tap on every tap-key.
            _ = activationRecognizer.handle(.otherKeyDown)
            _ = languageSwitchRecognizer.handle(.otherKeyDown)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
