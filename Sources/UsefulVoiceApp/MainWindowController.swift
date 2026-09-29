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
        let isFirstShow = window == nil
        if isFirstShow {
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
            // The window manages its own placement (and remembers the user's
            // choice), so AppKit's restorable-state machinery must not fight it.
            window.isRestorable = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        // Centre only on the first show. Re-centring on every open undid the
        // user's move/resize and forced the window back to the main screen, so
        // anyone working on a second display found it jumping back each time.
        if isFirstShow { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Renders the window's content to a PNG without showing a window or taking focus, so
    /// a page can be checked at any width while someone is working in another app. Used by
    /// `UV_SNAPSHOT` (see AppDelegate), not by normal launches.
    func snapshot(viewModel: UsefulVoiceViewModel, settings: AppSettings,
                  size: NSSize, to url: URL, completion: @escaping (Bool) -> Void) {
        let hosting = NSHostingView(rootView: RootView(viewModel: viewModel, settings: settings))
        let offscreen = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        offscreen.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        // Give SwiftUI a moment to run onAppear work and lay the page out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                completion(false)
                return
            }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = rep.representation(using: .png, properties: [:])
            completion((try? png?.write(to: url)) != nil)
        }
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
