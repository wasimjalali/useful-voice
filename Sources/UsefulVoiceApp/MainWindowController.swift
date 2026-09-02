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
            window.setContentSize(NSSize(width: 1040, height: 700))
            window.minSize = NSSize(width: 840, height: 580)
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
}
