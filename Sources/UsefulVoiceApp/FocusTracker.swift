import AppKit
import ApplicationServices
import UsefulVoiceCore

/// Reads what has focus (app, window, element, browser URL) and brings a captured
/// target back to the front. The decisions live in `TargetLock` (core); this is
/// only the macOS observing and acting.
///
/// Accessibility is the only permission used, and it is already required for
/// pasting. Without it the capture still returns the app and its process (from
/// NSWorkspace), just no window, element or URL, and those are then not compared.
/// An app the user can pick by name, keyed by bundle id.
struct AppChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class FocusTracker {
    static let shared = FocusTracker()

    /// The AX elements behind the identities of recent captures, so a
    /// reactivation can raise the right window and focus the right element.
    /// Bounded: only the last few captures can still be reactivated.
    private var windows: [String: AXUIElement] = [:]
    private var elements: [String: AXUIElement] = [:]
    private var order: [String] = []
    private static let rememberedElements = 16

    /// Apps dictated into this session, newest first, for the Settings list of
    /// apps that can be switched to typing. In memory only.
    private(set) var recentApps: [AppChoice] = []

    /// What has focus now. Nil only when no app is frontmost.
    ///
    /// `includePage` false skips the window title and the page address (the
    /// address walks up the AX tree): enough for an identity check.
    func snapshot(includePage: Bool = true) -> DeliveryTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        var windowID: String?
        var windowTitle: String?
        var elementID: String?
        var url: String?
        if AXIsProcessTrusted() {
            // Every element read below goes through `element` and `string`, which set
            // the short timeout on each element first.
            let axApp = AXUIElementCreateApplication(pid)
            if let window = Self.element(axApp, kAXFocusedWindowAttribute) {
                let id = "win#\(CFHash(window))"
                windowID = id
                if includePage { windowTitle = Self.string(window, kAXTitleAttribute) }
                remember(window, id: id, in: \.windows)
            }
            if let focused = Self.element(axApp, kAXFocusedUIElementAttribute) {
                let role = Self.string(focused, kAXRoleAttribute) ?? "?"
                let id = "\(role)#\(CFHash(focused))"
                elementID = id
                remember(focused, id: id, in: \.elements)
                if includePage, KnownBrowsers.isBrowser(bundleID: bundleID) {
                    url = Self.browserURL(from: focused, window: windowID.flatMap { windows[$0] })
                }
            }
        }
        return DeliveryTarget(appID: bundleID, appName: app.localizedName, processID: pid,
                              windowID: windowID, windowTitle: windowTitle,
                              elementID: elementID, browserURL: url)
    }

    /// Remembers the app of a target captured at a hotkey press, for Settings.
    func noteRecent(_ target: DeliveryTarget) {
        guard let id = target.appID, id != Bundle.main.bundleIdentifier else { return }
        recentApps.removeAll { $0.id == id }
        recentApps.insert(AppChoice(id: id, name: target.appName ?? id), at: 0)
        if recentApps.count > 8 { recentApps.removeLast() }
    }

    func isRunning(_ target: DeliveryTarget) -> Bool {
        if let pid = target.processID {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
            return !app.isTerminated
        }
        guard let id = target.appID else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    /// Brings the target app forward, raises its window and focuses its element.
    /// Returns whether the app came to the front within a short wait; the caller
    /// checks the window and element itself before inserting anything.
    func reactivate(_ target: DeliveryTarget) async -> Bool {
        guard let pid = target.processID,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
        else { return false }
        // macOS 14 activation is cooperative: the active app (often Useful Voice,
        // when the dictation was stopped from its window) hands activation over.
        if NSApp.isActive { NSApp.yieldActivation(to: app) }
        _ = app.activate()
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, Self.messagingTimeout)
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if let id = target.windowID, let window = windows[id] {
                AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
        }
        var front = false
        for _ in 0..<16 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { front = true; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard front else { return false }
        if AXIsProcessTrusted(), let id = target.elementID, let element = elements[id] {
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        // Let the app settle its focus before the caller looks again.
        try? await Task.sleep(for: .milliseconds(80))
        return true
    }

    // MARK: - AX helpers

    private func remember(_ element: AXUIElement, id: String,
                          in table: ReferenceWritableKeyPath<FocusTracker, [String: AXUIElement]>) {
        self[keyPath: table][id] = element
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.rememberedElements {
            let old = order.removeFirst()
            windows[old] = nil
            elements[old] = nil
        }
    }

    /// A cross-process AX call blocks on the target app until it answers. Each element
    /// gets this timeout before it is read, so a busy app (or a deep walk up a web
    /// page) can't stall the hotkey press or a delivery check for the default 6 s.
    private static let messagingTimeout: Float = 0.3

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(parent, messagingTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let child = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(child, messagingTimeout)
        return child
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success
        else { return nil }
        return ref as? String
    }

    /// The page address: the `AXURL` of the web area that holds the focused element
    /// (Safari, Chrome, Arc, Edge, Brave, Firefox expose one), else the window's
    /// `AXDocument`. Nil when neither is readable; nothing else is tried.
    private static func browserURL(from focused: AXUIElement, window: AXUIElement?) -> String? {
        var current: AXUIElement? = focused
        for _ in 0..<40 {
            guard let node = current else { break }
            if string(node, kAXRoleAttribute) == "AXWebArea" {
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, kAXURLAttribute as CFString, &ref) == .success,
                   let ref {
                    if CFGetTypeID(ref) == CFURLGetTypeID() { return (ref as! URL).absoluteString }
                    if let text = ref as? String, !text.isEmpty { return text }
                }
                break
            }
            current = element(node, kAXParentAttribute)
        }
        if let window, let document = string(window, kAXDocumentAttribute), !document.isEmpty {
            return document
        }
        return nil
    }
}
