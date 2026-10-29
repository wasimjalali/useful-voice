import AppKit
import SwiftUI
import UsefulVoiceCore

/// A hosting view that takes the click that lands on it while its window is not
/// key. The panel is non-activating, so every click on the pill or its close
/// button is a first click and must not be swallowed.
private final class HUDHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, non-activating floating panel beside the text cursor of the app in
/// front, or at the bottom centre of the display under the pointer when that app
/// does not report its cursor. Never steals focus from the app being dictated
/// into; its buttons still take a click.
///
/// The window is a fixed 400 by 160 pt: the bubble and a transparent margin for its
/// shadow, tail and halo. Every morph runs inside it, so the window never resizes
/// and a state change never moves the bubble. Clicks pass through the transparent
/// margin: a pointer monitor flips `ignoresMouseEvents`, so the window takes events
/// only while the pointer is over the bubble.
///
/// Where it sits is decided once per appearance (`HUDPlacement`): a dictation looks
/// for the cursor as it starts, and once the words have landed the done chip moves
/// beside the cursor's new position. Anything else (an error at launch, a language
/// switch) sits at the bottom centre.
///
/// Timing lives here, not in the callers: `show` arms the state's own lifetime
/// (`HUDDisplay.lifetime`), and a new `show` always replaces what is on screen,
/// so a persistent error ends when the next dictation starts.
@MainActor
final class HUDPanel: NSObject {
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDRoot>?
    private let model = HUDModel()
    private let settings = AppSettings()
    private var hideTimer: Timer?
    /// Whether the HUD is meant to be on screen. False once the exit has begun.
    private var isShowing = false
    /// Bumped on every exit, so a late `orderOut` from an earlier exit cannot hide
    /// a HUD that has since come back.
    private var generation = 0
    /// The last thing announced, so the per-tick recording updates and a growing
    /// partial are not announced again.
    private var lastAnnouncementKey: String?
    /// Where the user dragged the bottom pill to, if anywhere. Preserved across shows
    /// and clamped to the active screen so it can never strand the HUD off-screen.
    private var userOrigin: CGPoint?
    /// Set around programmatic frame changes so windowDidMove can tell a real
    /// user drag apart from our own repositioning.
    private var isProgrammaticMove = false
    /// Pointer monitors, installed while the HUD is on screen.
    private var pointerMonitors: [Any] = []
    /// The text cursor the bubble points at in caret placement.
    private var caret: CGRect?
    /// Smooths the mic level for the aura.
    private var levelSmoother = MicLevel.Smoother()
    private var styleObserver: NSObjectProtocol?

    /// The pill's button: the fix verb. Wired by the app to `viewModel.perform`.
    var onFix: ((DictationFix) -> Void)?

    private var reduceMotion: Bool { BrandMotion.reduceMotion }

    override init() {
        super.init()
        // Built at launch and its common rows measured, so the first dictation's
        // entrance is as smooth as every later one.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel == nil else { return }
            self.buildPanel()
            HUDLayout.warm()
        }
        styleObserver = NotificationCenter.default.addObserver(forName: .uvHUDStyleDidChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.palette = HUDPalette.current(self.settings)
            }
        }
    }

    // MARK: - Showing

    /// Shows `display`, or updates the HUD if it is already up. A state with a
    /// lifetime hides itself when it runs out.
    func show(_ display: HUDDisplay) {
        hideTimer?.invalidate()
        hideTimer = nil
        if panel == nil { buildPanel() }
        guard let panel else { return }
        let now = Date()
        let old = model.display

        // A new dictation over an outcome still on screen starts over too: it looks
        // for the cursor again and blooms.
        let startsOver = !isShowing || (display.isRecording && !old.isRecording)
        if startsOver {
            let placement = decidePlacement(for: display)
            model.placement = placement
            model.palette = HUDPalette.current(settings)
            _ = HUDLayout.size(of: display, placement: placement)
            model.display = display
            // The clock starts once the window's first frame is on screen, so the
            // entrance is never half over before anyone sees it.
            model.timeline = .waiting(display)
            if display.isRecording {
                model.recordingID &+= 1
                levelSmoother = MicLevel.Smoother()
            }
            enter(panel)
        } else if old != display {
            _ = HUDLayout.size(of: display, placement: model.placement)
            model.timeline.advance(from: old, to: display, placement: model.placement, at: now)
            model.display = display
            if case .done = display, old.phase != display.phase, model.placement.isCaret { placeChip() }
        }
        if case .recording(_, let level, _) = display {
            model.level = levelSmoother.step(rms: level, at: now.timeIntervalSinceReferenceDate)
        }
        announce(display)

        if let lifetime = display.lifetime { scheduleHide(after: lifetime) }
    }

    /// Hides the HUD, now or after `delay`.
    func hide(after delay: TimeInterval = 0) {
        hideTimer?.invalidate()
        hideTimer = nil
        guard delay > 0 else { beginExit(); return }
        scheduleHide(after: delay)
    }

    /// Hides the HUD only if it is still showing the dictation itself, so a state
    /// returning to idle can never leave a stale "Recording" up. The outcome
    /// states (done, copied, cancelled) are left to their own timers.
    func hideIfProgress() {
        if isShowing, model.display.isProgress { hide() }
    }

    /// Removes the panel from screen immediately, with no animation. Used on
    /// termination, where an animation would never complete.
    func hideImmediately() {
        hideTimer?.invalidate()
        hideTimer = nil
        generation &+= 1
        isShowing = false
        lastAnnouncementKey = nil
        stopPointerTracking()
        panel?.orderOut(nil)
    }

    /// The top centre of the bubble where it sits (or would sit), in screen
    /// coordinates, for anchoring the language picker above it.
    func capsuleAnchor() -> NSPoint {
        if let panel, panel.isVisible, model.bubbleFrame != .zero {
            let frame = screenRect(of: model.bubbleFrame, in: panel)
            return NSPoint(x: frame.midX, y: frame.maxY)
        }
        let origin = bottomOrigin(on: activeScreen)
        return NSPoint(x: origin.x + HUDView.windowSize.width / 2,
                       y: origin.y + HUDView.shadowPad + HUDView.bubbleHeight)
    }

    /// Live checks only: the cursor and the bubble on screen, for comparing the two.
    func geometry() -> String {
        guard let panel else { return "no panel" }
        let bubble = model.bubbleFrame == .zero ? NSRect.zero : screenRect(of: model.bubbleFrame, in: panel)
        return "placement=\(model.placement) caret=\(caret.map { NSStringFromRect($0) } ?? "nil") "
            + "bubble=\(NSStringFromRect(bubble)) window=\(NSStringFromRect(panel.frame))"
    }

    // MARK: - Timing

    private func scheduleHide(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginExit() }
        }
        hideTimer = timer
        // .common so the dismissal still fires while a menu is open or a window
        // is being dragged, instead of lingering past its intended lifetime.
        RunLoop.main.add(timer, forMode: .common)
    }

    private func enter(_ panel: NSPanel) {
        isShowing = true
        generation &+= 1
        position(panel, at: windowOrigin())
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        startPointerTracking(panel)
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, self.generation == token, self.isShowing else { return }
            self.model.timeline.start(at: Date())
        }
    }

    private func beginExit() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard isShowing, let panel else { return }
        isShowing = false
        lastAnnouncementKey = nil
        generation &+= 1
        model.timeline.exitAt = Date()
        let token = generation
        let delay = reduceMotion ? 0.0 : HUDTiming.exit + 0.04
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // A show() during the exit sets isShowing again: do not hide then.
            guard let self, self.generation == token, !self.isShowing else { return }
            self.stopPointerTracking()
            panel.orderOut(nil)
        }
    }

    // MARK: - Placement

    /// Caret placement when a dictation starts and the app in front reports its
    /// cursor; the bottom centre otherwise.
    private func decidePlacement(for display: HUDDisplay) -> HUDPlacement {
        caret = nil
        guard display.isRecording, let found = CaretLocator.locate(), let screen = screen(containing: found) else {
            return .bottom
        }
        caret = found
        let flipped = found.maxX + HUDView.caretGap + HUDView.flipRoom > screen.visibleFrame.maxX
        return .caret(flipped: flipped)
    }

    /// Once the words have landed, the done chip goes beside the cursor's new
    /// position. The app in front gets a moment to move its cursor first; if it
    /// no longer answers, the chip stays at the old spot.
    private func placeChip() {
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.generation == token, self.isShowing, let panel = self.panel,
                  case .done = self.model.display else { return }
            if let moved = CaretLocator.locate() {
                self.caret = moved
                self.position(panel, at: self.caretOrigin(for: moved, gap: HUDView.chipGap))
            }
            self.model.timeline.chipAt = Date()
        }
    }

    private func windowOrigin() -> CGPoint {
        if model.placement.isCaret, let caret { return caretOrigin(for: caret, gap: HUDView.caretGap) }
        return bottomOrigin(on: activeScreen)
    }

    /// The window that puts the bubble's near edge `gap` from the cursor, vertically
    /// centred on it, kept on the cursor's screen.
    private func caretOrigin(for caret: CGRect, gap: CGFloat) -> CGPoint {
        let size = HUDView.windowSize
        let pad = HUDView.shadowPad
        let flipped = model.placement.isFlipped
        var x = flipped ? caret.minX - gap - (size.width - pad) : caret.maxX + gap - pad
        var y = caret.midY - size.height / 2
        if let visible = screen(containing: caret)?.visibleFrame {
            // Keep a bubble of the flip room on screen without sliding it over the cursor.
            x = min(max(x, visible.minX - pad), visible.maxX - pad - HUDView.flipRoom)
            let half = (size.height - HUDView.bubbleHeight) / 2
            y = min(max(y, visible.minY - half + 4), visible.maxY - size.height + half - 4)
        }
        return CGPoint(x: x, y: y)
    }

    /// Bottom centre, 32 pt above the Dock (the visible frame already excludes
    /// it), or where the user dragged it, kept on the screen.
    private func bottomOrigin(on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let size = HUDView.windowSize
        let pad = HUDView.shadowPad
        if let dragged = userOrigin {
            // The transparent margin may hang over the edge; the bubble may not.
            let bounds = visible.insetBy(dx: -pad, dy: -pad)
            return CGPoint(x: min(max(dragged.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
                           y: min(max(dragged.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)))
        }
        return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 32 - pad)
    }

    private func position(_ panel: NSPanel, at origin: CGPoint) {
        isProgrammaticMove = true
        panel.setFrame(NSRect(origin: origin, size: HUDView.windowSize), display: false)
        isProgrammaticMove = false
    }

    /// The display under the pointer, which is where the person is working.
    private var activeScreen: NSScreen {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func screen(containing rect: CGRect) -> NSScreen? {
        let point = CGPoint(x: rect.minX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    // MARK: - Click-through

    /// A frame in the hosting view (top-left origin) in screen coordinates.
    private func screenRect(of frame: CGRect, in panel: NSPanel) -> NSRect {
        let window = panel.frame
        return NSRect(x: window.minX + frame.minX, y: window.maxY - frame.maxY,
                      width: frame.width, height: frame.height)
    }

    /// Takes mouse events only while the pointer is over the bubble, with a few
    /// points of slack so the edge is easy to hit.
    private func updateMouseEvents() {
        guard let panel else { return }
        let frame = model.bubbleFrame
        let inside = frame.width > 0
            && screenRect(of: frame, in: panel).insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    }

    private func startPointerTracking(_ panel: NSPanel) {
        updateMouseEvents()
        guard pointerMonitors.isEmpty else { return }
        // Global: moves over other apps' windows, which is where the pointer is
        // while the window ignores it. Local: moves over this window while it takes
        // events, which is how it learns the pointer left the bubble.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMouseEvents() }
        }) { pointerMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateMouseEvents() }
            return event
        }) { pointerMonitors.append(local) }
    }

    private func stopPointerTracking() {
        for monitor in pointerMonitors { NSEvent.removeMonitor(monitor) }
        pointerMonitors = []
    }

    // MARK: - Announcements

    private func announce(_ display: HUDDisplay) {
        let key: String
        switch display {
        case .recording: key = "recording"
        case .transcribing: key = "transcribing"
        case .delivering: key = "delivering"
        default: key = "\(display.phase)|\(display.accessibilityLabel)"
        }
        guard key != lastAnnouncementKey else { return }
        lastAnnouncementKey = key
        if let message = Announcer.message(for: display) { Announcer.post(message) }
    }

    // MARK: - Building

    private func buildPanel() {
        let root = HUDRoot(
            model: model,
            onFix: { [weak self] fix in
                // The pill's verb ends the HUD: the fix takes over from here.
                self?.hide()
                self?.onFix?(fix)
            },
            onClose: { [weak self] in
                // Closing hides the HUD only. The same fix stays in the window's
                // status surface and the menu.
                self?.hide()
            })
        let hosting = HUDHostingView(rootView: root)
        // Single sizing authority: the window is a fixed size, so the hosting view
        // must not try to resize it.
        hosting.sizingOptions = []

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: HUDView.windowSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above normal windows and the status bar so it is visible over whatever
        // app you are dictating into, including most full-screen apps.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the view draws its own shadow
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Draggable by its body; the buttons still take their own clicks. Ignores
        // the mouse until the pointer is over the bubble (see updateMouseEvents).
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        self.hosting = hosting
    }
}

extension HUDPanel: NSWindowDelegate {
    /// Remember where the user drags the bottom pill so it stays there, but only for
    /// real drags, not our own repositioning, and never a bubble beside the cursor.
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, let panel, model.placement == .bottom else { return }
        userOrigin = panel.frame.origin
    }
}
