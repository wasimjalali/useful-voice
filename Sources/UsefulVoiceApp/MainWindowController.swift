import AppKit
import SwiftUI
import UsefulVoiceCore

/// Owns the single main app window. While the window is open the app is a
/// regular Dock app; when it closes, the app drops back to a menu-bar-only
/// accessory (the hotkey and status item keep working). The app does not quit.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(viewModel: UsefulVoiceViewModel, settings: AppSettings) {
        if window == nil {
            let hosting = NSHostingController(
                rootView: RootView(viewModel: viewModel, settings: settings))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Useful Voice"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = Theme.canvasNSColor
            window.isMovableByWindowBackground = true
            window.setContentSize(Self.defaultContentSize(on: NSScreen.main))
            window.minSize = NSSize(width: 960, height: 640)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only. Window is kept (isReleasedWhenClosed=false) for reopen.
        NSApp.setActivationPolicy(.accessory)
    }

    /// A standard document-sized window, clamped to the visible screen.
    private static func defaultContentSize(on screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1280, max(1080, visible.width * 0.62))
        let height = min(860, max(720, visible.height * 0.76))
        return NSSize(width: width.rounded(), height: height.rounded())
    }
}
