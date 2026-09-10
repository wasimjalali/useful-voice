import AppKit
import SwiftUI
import UsefulVoiceCore

/// A focusable floating panel hosting `LanguagePicker`.
///
/// The language hotkey used to cycle English↔German in place, which stopped being
/// usable as soon as the picker offered more than two languages: cycling through
/// ten entries by tapping a key is worse than not having the shortcut. The hotkey
/// now opens this instead, so the shortcut still exists but the choice is made
/// deliberately.
///
/// Deliberately *not* built on `HUDPanel`. That panel is `.nonactivatingPanel` and
/// never takes focus, because a dictation HUD must not steal the caret from the app
/// you are typing into. This one needs the opposite: a search field has to receive
/// keystrokes, so the panel must be able to become key while still appearing over
/// whatever app has focus.
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

    private let panelWidth: CGFloat = 292
    private let panelHeight: CGFloat = 396

    var isVisible: Bool { isShowing }

    /// Show the picker for `selection`, calling `onSelect` only if the user picks.
    func show(
        selection: LanguagePin,
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

        let binding = Binding<LanguagePin>(
            get: { selection },
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
        // `.accessory`-style activation so the panel can take keystrokes for the
        // search field without the app coming to the front as a whole.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard isShowing else { return }
        isShowing = false
        panel?.orderOut(nil)
        // Fired after the panel is gone so a caller reacting to dismissal cannot
        // re-open it.
        if !didSelect { onDismiss?() }
        onSelect = nil
        onDismiss = nil
    }

    // MARK: - Panel

    private func buildPanel(with view: LanguagePicker) {
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
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
