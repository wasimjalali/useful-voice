import SwiftUI
import AppKit

extension View {
    /// Keeps the first keyboard focus off a page's search field, which would otherwise
    /// draw its focus ring the moment the page opens (the window gives the first text
    /// field focus). Apply it once, to the page's root view.
    func keepsFirstFieldUnfocused() -> some View {
        modifier(LandingFocus())
    }
}

private struct LandingFocus: ViewModifier {
    @FocusState private var landing: Bool
    /// The landing target is focusable only while it does its job. Once the first
    /// moments are over and focus is anywhere else, it leaves the key-view loop, so
    /// Full Keyboard Access has no Tab stop on nothing. (Removing it while it still
    /// holds focus would hand focus straight back to the search field.)
    @State private var armed = true
    @State private var windowOver = false

    func body(content: Content) -> some View {
        content
            .background {
                Color.clear
                    .frame(width: 1, height: 1)
                    .focusable(armed)
                    .focused($landing)
                    .focusEffectDisabled()
                    .accessibilityHidden(true)
            }
            .defaultFocus($landing, true)
            .onChange(of: landing) { _, focused in
                if !focused && windowOver { armed = false }
            }
            .onAppear {
                // The window hands the first key view focus after `defaultFocus` ran.
                // Take it back, but only until the person clicks or types: from then
                // on the focus is theirs.
                let guardian = LandingFocusGuard()
                for delay in [0.0, 0.05, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if guardian.active { landing = true }
                        if delay >= 0.3 {
                            guardian.stop()
                            windowOver = true
                            if !landing { armed = false }
                        }
                    }
                }
            }
    }
}

/// Watches the first moments of the page for a click or a key press.
private final class LandingFocusGuard {
    private(set) var active = true
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            self?.stop()
            return event
        }
    }

    func stop() {
        active = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
