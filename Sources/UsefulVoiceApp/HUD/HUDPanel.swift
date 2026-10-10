import AppKit
import SwiftUI
import UsefulVoiceCore

/// A hosting view that takes the click that lands on it while its window is not
/// key. The panel is non-activating, so every click on the pill or its close
/// button is a first click and must not be swallowed.
private final class HUDHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless, non-activating floating panel at the bottom centre of the display
/// under the pointer. Never steals focus from the app being dictated into; its
/// buttons still take a click.
///
/// The window is a fixed 400 by 160 pt: 360 by 120 of content and 20 pt of
/// transparent margin for the shadow. Every morph runs inside it, so the window
/// never resizes and a state change never moves the pill. Clicks pass through the
/// transparent margin (the window is non-opaque, so the window server skips fully
/// transparent pixels).
///
/// Timing lives here, not in the callers: `show` arms the state's own lifetime
/// (`HUDDisplay.lifetime`), and a new `show` always replaces what is on screen,
/// so a persistent error ends when the next dictation starts.
@MainActor
final class HUDPanel: NSObject {
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDRoot>?
    private let model = HUDModel()
    private var hideTimer: Timer?
    /// Whether the HUD is meant to be on screen. False once the exit has begun.
    private var isShowing = false
    /// Bumped on every exit, so a late `orderOut` from an earlier exit cannot hide
    /// a HUD that has since come back.
    private var generation = 0
    /// The last thing announced, so the per-tick recording updates and a growing
    /// partial are not announced again.
    private var lastAnnouncementKey: String?
    /// Where the user dragged the window to, if anywhere. Preserved across shows
    /// and clamped to the active screen so it can never strand the HUD off-screen.
    private var userOrigin: CGPoint?
    /// Set around programmatic frame changes so windowDidMove can tell a real
    /// user drag apart from our own repositioning.
    private var isProgrammaticMove = false

    /// The pill's button: the fix verb. Wired by the app to `viewModel.perform`.
    var onFix: ((DictationFix) -> Void)?

    private var reduceMotion: Bool { BrandMotion.reduceMotion }

    // MARK: - Showing

    /// Shows `display`, or updates the HUD if it is already up. A state with a
    /// lifetime hides itself when it runs out.
    func show(_ display: HUDDisplay) {
        hideTimer?.invalidate()
        hideTimer = nil

        if model.display != display { model.display = display }
        announce(display)

        if panel == nil { buildPanel() }
        guard let panel else { return }

        if isShowing {
            // Already up (a level tick, a state change): nothing to enter.
        } else if panel.isVisible && model.presentation == .exiting {
            // Mid-exit: come back from where it is instead of restarting.
            isShowing = true
            model.presentation = .shown
        } else {
            enter(panel)
        }

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
        panel?.orderOut(nil)
    }

    /// The top centre of the pill where it sits (or would sit), in screen
    /// coordinates, for anchoring the language picker above it.
    func capsuleAnchor() -> NSPoint {
        let origin: CGPoint
        if let panel, panel.isVisible {
            origin = panel.frame.origin
        } else {
            origin = windowOrigin(on: activeScreen)
        }
        return NSPoint(x: origin.x + HUDView.windowSize.width / 2,
                       y: origin.y + HUDView.shadowPad + HUDView.capsuleHeight)
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
        model.presentation = .entering
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        // One run loop turn later, so the hidden first frame is on screen and the
        // change to "shown" animates instead of being the first thing drawn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShowing, self.model.presentation == .entering else { return }
            self.model.presentation = .shown
        }
    }

    private func beginExit() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard isShowing, let panel else { return }
        isShowing = false
        lastAnnouncementKey = nil
        generation &+= 1
        model.presentation = .exiting
        let token = generation
        let delay = reduceMotion ? 0.0 : BrandMotion.hudExitDuration + 0.04
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // A show() during the exit sets isShowing again: do not hide then.
            guard let self, self.generation == token, !self.isShowing else { return }
            panel.orderOut(nil)
        }
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
        // Draggable by its body; the buttons still take their own clicks.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        self.hosting = hosting
    }

    // MARK: - Positioning

    /// The display under the pointer, which is where the person is working.
    private var activeScreen: NSScreen {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Bottom centre, 32 pt above the Dock (the visible frame already excludes
    /// it), or where the user dragged it, kept on the screen.
    private func windowOrigin(on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let size = HUDView.windowSize
        let pad = HUDView.shadowPad
        if let dragged = userOrigin {
            // The transparent margin may hang over the edge; the capsule may not.
            let bounds = visible.insetBy(dx: -pad, dy: -pad)
            return CGPoint(x: min(max(dragged.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
                           y: min(max(dragged.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)))
        }
        return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 32 - pad)
    }

    private func position(_ panel: NSPanel) {
        let origin = windowOrigin(on: activeScreen)
        isProgrammaticMove = true
        panel.setFrame(NSRect(origin: origin, size: HUDView.windowSize), display: false)
        isProgrammaticMove = false
    }
}

extension HUDPanel: NSWindowDelegate {
    /// Remember where the user drags the HUD so it stays there, but only for real
    /// drags, not our own repositioning.
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, let panel else { return }
        userOrigin = panel.frame.origin
    }
}
