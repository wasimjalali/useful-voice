import AppKit
import QuartzCore
import SwiftUI

/// Borderless, non-activating floating panel near the bottom-center of the
/// active screen. Never steals focus from the app being dictated into.
///
/// Visibility is the whole job here, so the panel is defensive about it: it
/// recomputes its frame on the *active* screen every time it shows, clamps any
/// position the user dragged it to back inside the visible area, and floors its
/// size so a child whose layout hasn't resolved yet can never collapse the pill
/// to nothing. It fades in and out instead of snapping.
@MainActor
final class HUDPanel: NSObject {
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDView>?
    private var hideTimer: Timer?
    /// Whether the pill is currently meant to be on screen. Drives whether a
    /// show() fades in fresh or just updates an already-visible pill.
    private var isShowing = false
    /// A position the user dragged the pill to, if any. Preserved across shows
    /// but always clamped to the active screen so it can never strand the pill
    /// off-screen. Nil means "center it".
    private var userOrigin: CGPoint?
    /// Set around programmatic frame changes so windowDidMove can tell a real
    /// user drag apart from our own repositioning.
    private var isProgrammaticMove = false

    /// Smallest the pill is ever allowed to be. A hard floor so a TimelineView
    /// child that reports a zero fitting size for a frame can't make the pill
    /// invisible: the panel still has real, on-screen pixels.
    private let minSize = CGSize(width: 96, height: 40)

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func show(_ display: HUDDisplay) {
        hideTimer?.invalidate()
        hideTimer = nil

        let view = HUDView(display: display)
        if let hosting {
            hosting.rootView = view
        } else {
            buildPanel(with: view)
        }
        guard let panel, let hosting else { return }

        hosting.layout()
        let size = pillSize(hosting.fittingSize)
        if panel.frame.size != size {
            isProgrammaticMove = true
            panel.setContentSize(size)
            isProgrammaticMove = false
        }
        reposition(panel, size: size)

        let wasShowing = isShowing
        isShowing = true
        if wasShowing {
            // Already visible (e.g. a level update mid-recording, or a state
            // change): make sure a half-finished fade-out doesn't leave it dim.
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.20
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        }
    }

    /// Errors linger so they can be read; success states vanish quickly.
    func hide(after delay: TimeInterval = 0) {
        hideTimer?.invalidate()
        hideTimer = nil
        guard delay > 0 else { fadeOut(); return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
    }

    // MARK: - Building

    private func buildPanel(with view: HUDView) {
        // Single sizing authority: we drive the panel from hosting.fittingSize in
        // show(), with a floor in pillSize() for the frames where the live
        // waveform's TimelineView hasn't resolved its layout yet. We deliberately
        // do NOT also set sizingOptions = .intrinsicContentSize, which would have
        // the hosting view fight us for control of the size.
        let hosting = NSHostingView(rootView: view)

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: minSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above normal windows and the status bar so it's visible over whatever
        // app you're dictating into, including most full-screen apps.
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // the SwiftUI pill draws its own soft shadow
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Draggable: accept mouse and let the user move it by its body.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .ignoresCycle]
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        self.hosting = hosting
    }

    // MARK: - Sizing and positioning

    /// Floors a fitting size so the pill is never smaller than minSize, which is
    /// what makes a zero/under-reported fitting size harmless.
    private func pillSize(_ fitting: CGSize) -> CGSize {
        CGSize(width: max(fitting.width, minSize.width),
               height: max(fitting.height, minSize.height))
    }

    /// The screen the user is currently working on. NSScreen.main follows the
    /// active window's screen, which is where a dictation target lives.
    private var activeScreen: NSScreen {
        NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
    }

    /// Places the panel on the active screen: at a dragged spot if the user set
    /// one (clamped so it stays fully visible), otherwise bottom-center.
    private func reposition(_ panel: NSPanel, size: CGSize) {
        let visible = activeScreen.visibleFrame
        let origin: CGPoint
        if let dragged = userOrigin {
            origin = clamp(dragged, size: size, within: visible)
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + 96)
        }
        if panel.frame.origin != origin {
            isProgrammaticMove = true
            panel.setFrameOrigin(origin)
            isProgrammaticMove = false
        }
    }

    /// Keeps an origin so the whole pill stays inside `bounds`.
    private func clamp(_ origin: CGPoint, size: CGSize, within bounds: NSRect) -> CGPoint {
        let maxX = bounds.maxX - size.width
        let maxY = bounds.maxY - size.height
        return CGPoint(x: min(max(origin.x, bounds.minX), max(bounds.minX, maxX)),
                       y: min(max(origin.y, bounds.minY), max(bounds.minY, maxY)))
    }

    // MARK: - Fade out

    private func fadeOut() {
        guard let panel else { return }
        guard isShowing else { panel.orderOut(nil); return }
        isShowing = false
        guard !reduceMotion else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A show() during the fade re-activates us: don't hide then.
                guard !self.isShowing else { return }
                self.panel?.orderOut(nil)
            }
        })
    }
}

extension HUDPanel: NSWindowDelegate {
    /// Remember where the user drags the pill so it stays there, but only for
    /// real drags, not our own repositioning.
    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticMove, let panel else { return }
        userOrigin = panel.frame.origin
    }
}
