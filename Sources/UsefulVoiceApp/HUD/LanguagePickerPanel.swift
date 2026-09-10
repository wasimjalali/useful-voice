import AppKit
import SwiftUI
import UsefulVoiceCore

/// An `NSPanel` that is willing to become the key window.
///
/// This subclass is not optional garnish, it is what makes the picker usable.
/// AppKit refuses key status to a window that cannot become key, and a
/// `.borderless` panel cannot by default — `canBecomeKey` returns false because
/// there is no title bar to click. `HUDPanel` gets away with a borderless panel
/// precisely because it never wants focus: it is `.nonactivatingPanel` and must not
/// steal the caret from the app being dictated into. This panel wants the opposite,
/// so it has to say so. Without the override the popup appears and then ignores
/// every keystroke, so its search field is inert — the feature would look present
/// and be unusable.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A focusable floating panel hosting `LanguagePicker`.
///
/// The language hotkey used to cycle English↔German in place, which stopped being
/// usable as soon as the picker offered more than two languages: reaching the tenth
/// entry by tapping a key is worse than not having the shortcut. The hotkey now opens
/// this instead, so the shortcut survives while the choice stays deliberate.
///
/// Deliberately *not* built on `HUDPanel`. That panel is `.nonactivatingPanel` and
/// never takes focus, because a dictation HUD must not steal the caret from the app
/// you are typing into. This one needs the opposite — a search field has to receive
/// keystrokes, so the panel must be able to become key.
///
/// **Taking focus makes restoring it this panel's responsibility.** Every delivery
/// path in the app is focus-dependent: `TextInserter` posts an unaddressed ⌘V to
/// `.cghidEventTap`, which goes to whatever application is frontmost, and its
/// accessibility fallback targets the system-wide focused element. So a panel that
/// takes frontmost and does not give it back silently breaks the *next* dictation —
/// the transcript would be pasted into nothing, or into this app. The old in-place
/// cycle had no such problem because it never activated anything, which is what makes
/// this a regression to avoid rather than a nicety to add.
@MainActor
final class LanguagePickerPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var hosting: NSHostingView<LanguagePicker>?
    private var onSelect: ((LanguagePin) -> Void)?
    /// Called when the panel closes without a selection, so the caller can leave
    /// the previous language untouched rather than guessing.
    private var onDismiss: (() -> Void)?
    private var isShowing = false
    /// Guards the callback so closing the panel does not fire a selection.
    private var didSelect = false
    /// The application that was frontmost when the panel opened.
    ///
    /// Captured so it can be handed focus back on close. See the class comment: the
    /// app's paste path depends on which application is frontmost, so failing to
    /// restore this breaks the next dictation rather than merely being untidy.
    private var previousApplication: NSRunningApplication?

    private let panelWidth: CGFloat = 292
    private let panelHeight: CGFloat = 396

    var isVisible: Bool { isShowing }

    /// Show the picker, calling `onSelect` only if the user picks.
    ///
    /// Takes a closure for the current value rather than the value itself. Passing the
    /// value would freeze the panel at whatever it was when the hotkey was pressed:
    /// the picker keeps holding a `Binding`, and a binding built from a captured value
    /// answers with that stale value for as long as the panel is open. If anything
    /// changed the language in the meantime — the menu bar, another window — the
    /// checkmark would point at the wrong row and re-selecting the shown value would
    /// write it back over the real one.
    func show(
        current: @escaping () -> LanguagePin,
        onSelect: @escaping (LanguagePin) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        // Tapping the hotkey again while it is open is a cancel, not a second
        // panel, which matches how a menu-bar popover behaves.
        if isShowing {
            close()
            return
        }
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        didSelect = false
        // Recorded before the panel takes focus, and only if it is a different
        // application: activating ourselves when we are already frontmost would be a
        // no-op, and storing ourselves would make close() activate the wrong app.
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApplication = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil
            : frontmost

        let binding = Binding<LanguagePin>(
            get: { current() },
            set: { [weak self] chosen in
                guard let self else { return }
                self.didSelect = true
                self.onSelect?(chosen)
                self.close()
            }
        )

        let view = LanguagePicker(selection: binding, title: "Dictation language")
        if let hosting {
            hosting.rootView = view
        } else {
            buildPanel(with: view)
        }
        guard let panel else { return }

        position(panel)
        isShowing = true
        // The panel has to be key for the search field to receive keystrokes. It is
        // `KeyablePanel` (see above) precisely so this call can succeed on a
        // borderless window; a plain NSPanel would refuse.
        panel.makeKeyAndOrderFront(nil)
        // Activating is what lets a background (accessory) app's window accept typed
        // input. Done after ordering front so the window is already on screen when
        // focus moves. This app is `LSUIElement`, so it is not normally frontmost.
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard isShowing else { return }
        // Set before ordering out: the resign-key notification that follows re-enters
        // this method, and the guard above is what stops the recursion.
        isShowing = false
        panel?.orderOut(nil)

        // Hand focus back to whatever had it. Without this the app remains frontmost,
        // and the next dictation would paste into a window that is not the user's
        // editor — the delivery path relies on the frontmost application to know where
        // text goes. `.activateIgnoringOtherApps` is deprecated and ignored on macOS
        // 14+, so the plain call is both current and equivalent.
        if let previous = previousApplication, !previous.isTerminated {
            previous.activate()
        }
        previousApplication = nil

        // Fired after the panel is gone so a caller reacting to dismissal cannot
        // re-open it.
        if !didSelect { onDismiss?() }
        onSelect = nil
        onDismiss = nil
    }

    // MARK: - Panel

    private func buildPanel(with view: LanguagePicker) {
        let hosting = NSHostingView(rootView: view)
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the SwiftUI card draws its own
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // No title bar, but the panel must still accept key input for the search
        // field; a borderless panel refuses key status unless told otherwise.
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        self.hosting = hosting
    }

    /// Centres horizontally on the active screen and sits above centre, where it
    /// does not cover the caret line the user is dictating into on most layouts.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = NSSize(width: panelWidth, height: panelHeight)
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.12
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.setContentSize(size)
    }

    // MARK: - NSWindowDelegate

    /// Losing focus closes the picker, so clicking away behaves like dismissing a
    /// menu instead of leaving a floating card behind.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
