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
///
/// ## Threading
///
/// The tap runs on a **dedicated thread with its own run loop**, never the main
/// run loop. A `.defaultTap` sits on the synchronous path of every keystroke in
/// the session: the WindowServer delivers the event and waits for the callback
/// to return. A tap attached to the main run loop therefore inherits every main
/// thread stall — SwiftUI layout, file I/O, and any blocking call — and macOS
/// punishes a slow tap by disabling it (`kCGEventTapDisabledByTimeout`), taking
/// system-wide keyboard handling down with it. Keeping the tap on its own thread
/// makes it immune to main-thread work by construction.
///
/// The callback must still be cheap: it only compares flags, feeds the pure
/// recognizers, and hops to the main queue for work.
final class HotkeyManager: @unchecked Sendable {
    private static let escapeKeycode: Int64 = 53

    // MARK: - Cross-thread state
    //
    // Read from the tap thread, written from the main actor, so everything is
    // guarded rather than assumed.

    private let stateLock = NSLock()
    private var _activationKeycode: Int64 = 54
    private var _languageSwitchKeycode: Int64 = 60
    private var _isRecordingActive = false

    /// The modifier key whose tap toggles dictation. Default Right Command (54).
    /// Updatable live: the tap listens to all flagsChanged and filters here, so
    /// changing this takes effect without restarting the tap.
    var activationKeycode: Int64 {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _activationKeycode }
        set { stateLock.lock(); _activationKeycode = newValue; stateLock.unlock() }
    }

    /// The modifier key whose tap flips the dictation language. Default Right
    /// Shift (60), the Shift key under Return, by explicit user choice.
    var languageSwitchKeycode: Int64 {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _languageSwitchKeycode }
        set { stateLock.lock(); _languageSwitchKeycode = newValue; stateLock.unlock() }
    }

    /// Whether a recording is in flight, so Esc belongs to us.
    var isRecordingActive: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isRecordingActive }
        set { stateLock.lock(); _isRecordingActive = newValue; stateLock.unlock() }
    }

    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Language key tap: flip the dictation language between English and German.
    var onLanguageSwitch: (() -> Void)?
    /// The tap died and the app must re-check trust and re-arm. Without this the
    /// hotkey fails silently while the UI still claims it is active.
    var onTapDisabled: (() -> Void)?

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

    /// Per-key "was down last time we saw it" state, so a modifier tap is read as
    /// a real transition.
    ///
    /// `flagsChanged` says which key changed, but `event.flags` only reports
    /// whether *any* key of that modifier class is down. Holding Left Command and
    /// tapping Right Command would otherwise read as two "down" events and the
    /// tap would never fire. Comparing against the previous observation for that
    /// keycode recovers the transition.
    private var lastDownState: [Int64: Bool] = [:]

    // One tap recognizer per tap-key. The type is a generic modifier-tap
    // detector (its event names are historical, from the original Right Option).
    private var activationRecognizer = RightOptionTapRecognizer()
    private var languageSwitchRecognizer = RightOptionTapRecognizer()

    // MARK: - Tap lifecycle (main thread only for the properties below)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The tap thread's run loop, captured on that thread so `stop()` can wake it.
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private let readySemaphore = DispatchSemaphore(value: 0)
    private var installFailed = false

    enum HotkeyError: Error { case tapCreationFailed }

    /// Event types the tap listens to.
    ///
    /// Mouse events are included so a pending modifier tap is cancelled by a
    /// click, drag or scroll. Without them, `Shift + click` (the default language
    /// key is Right Shift) flips the dictation language and `Cmd + click` starts
    /// or stops a recording — every modifier-plus-click gesture becomes a false
    /// positive. `keyUp` is included so the Esc consumed on key-down is paired
    /// with its key-up instead of leaking an unpaired event to the frontmost app.
    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .flagsChanged,
            .keyDown,
            .keyUp,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseDragged,
            .rightMouseDragged,
            .scrollWheel,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    func start() throws {
        guard tapThread == nil else { return }

        installFailed = false
        let thread = Thread { [weak self] in
            self?.runTapThread()
        }
        thread.name = "ai.karko.usefulvoice.hotkey-tap"
        // Above default, so keystroke delivery is never starved by background work.
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        // Do not report success until the tap is actually enabled on a running
        // loop: a non-nil CFMachPort means it was created, not that it is live.
        if readySemaphore.wait(timeout: .now() + 5) == .timedOut || installFailed {
            tapThread = nil
            throw HotkeyError.tapCreationFailed
        }
    }

    /// Runs on the dedicated tap thread: install, enable, then spin the loop.
    private func runTapThread() {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            installFailed = true
            readySemaphore.signal()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tap = tap
        self.runLoopSource = source
        // This thread's own run loop, NOT CFRunLoopGetMain().
        let loop = CFRunLoopGetCurrent()
        self.tapRunLoop = loop
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        // The tap is live: release start().
        readySemaphore.signal()

        CFRunLoopRun()

        // Reached only after CFRunLoopStop (see stop()).
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        self.tap = nil
        self.runLoopSource = nil
        self.tapRunLoop = nil
    }

    func stop() {
        guard let thread = tapThread else { return }

        if let source = runLoopSource { CFRunLoopSourceInvalidate(source) }
        if let loop = tapRunLoop {
            // Mutating another thread's run loop directly is not allowed, so hop
            // onto it and stop it there.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(loop)
        }

        if thread !== Thread.current {
            // Bounded wait so a wedged tap thread cannot block termination.
            let deadline = Date().addingTimeInterval(1)
            while !thread.isFinished && Date() < deadline {
                usleep(5_000)
            }
        }
        tapThread = nil
        lastDownState.removeAll()
    }

    // MARK: - Event handling (runs on the tap thread)

    private func handle(type: CGEventType,
                        event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that stalls or when the app loses trust. Timeouts
        // are recoverable; user-input disabling usually means the Accessibility
        // grant was revoked, in which case re-enabling is a silent no-op and the
        // app must be told so it can stop claiming the hotkey works.
        if type == .tapDisabledByTimeout {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            let trusted = AXIsProcessTrusted()
            if trusted, let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                onTapDisabled?()
            }
            return Unmanaged.passUnretained(event)
        }

        let activation = activationKeycode
        let languageSwitch = languageSwitchKeycode
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let now = ProcessInfo.processInfo.systemUptime

        switch type {
        case .flagsChanged where keycode == activation || keycode == languageSwitch:
            let isDown = event.flags.contains(Self.flagMask(for: keycode))
            // Ignore repeats: only a real transition counts. This is what makes
            // "other side of the same modifier is held" stop producing phantom
            // down events.
            guard lastDownState[keycode] != isDown else {
                return Unmanaged.passUnretained(event)
            }
            lastDownState[keycode] = isDown

            let isActivation = keycode == activation
            var recognizer = isActivation ? activationRecognizer : languageSwitchRecognizer
            let fired = recognizer.handle(isDown ? .rightOptionDown(at: now)
                                                : .rightOptionUp(at: now))
            if isActivation {
                activationRecognizer = recognizer
            } else {
                languageSwitchRecognizer = recognizer
            }
            if fired {
                DispatchQueue.main.async { [weak self] in
                    if isActivation { self?.onToggle?() } else { self?.onLanguageSwitch?() }
                }
            }

        case .flagsChanged:
            // A different modifier changed: invalidate pending taps on both keys.
            invalidatePendingTaps()

        case .keyDown where keycode == Self.escapeKeycode:
            if isRecordingActive {
                DispatchQueue.main.async { [weak self] in self?.onCancel?() }
                return nil // consume Esc so the frontmost app never sees it
            }

        case .keyDown, .keyUp:
            // Any other key invalidates a pending tap on every tap-key.
            invalidatePendingTaps()

        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .scrollWheel:
            // A click, drag or scroll ends any pending modifier tap. Without
            // this, modifier+click gestures fire the hotkey.
            invalidatePendingTaps()

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func invalidatePendingTaps() {
        _ = activationRecognizer.handle(.otherKeyDown)
        _ = languageSwitchRecognizer.handle(.otherKeyDown)
    }
}
