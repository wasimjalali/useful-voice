import AppKit
import ApplicationServices
import Carbon.HIToolbox
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

    /// Chromium browsers (Chrome, Arc, Dia, Edge, Brave, Vivaldi and others) build their
    /// web accessibility tree only once an assistive app asks for it, so until then their
    /// page address cannot be read and a Gmail tab formats as Other. Chromium's switch for
    /// that is the `AXManualAccessibility` attribute; Safari and Firefox reject it, which is
    /// fine. It is set once per browser process, when the browser comes to the front, so the
    /// tree is ready by the hotkey press. Measured on Dia: the address is readable about
    /// 80 to 95 ms after the switch.
    private var browserAccessibilityOn: Set<pid_t> = []
    private var browserObservers: [NSObjectProtocol] = []

    /// Starts switching browsers on as they come to the front. Not for snapshot renders,
    /// which must not touch other apps.
    func startBrowserAccessibility() {
        guard browserObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        browserObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let pid else { return }
                FocusTracker.shared.enableBrowserAccessibility(pid: pid, bundleID: bundleID)
            }
        })
        browserObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            MainActor.assumeIsolated {
                guard let pid else { return }
                FocusTracker.shared.browserAccessibilityOn.remove(pid)
            }
        })
        if let app = NSWorkspace.shared.frontmostApplication {
            enableBrowserAccessibility(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
        }
    }

    private func enableBrowserAccessibility(pid: pid_t, bundleID: String?) {
        guard AXIsProcessTrusted(), KnownBrowsers.isBrowser(bundleID: bundleID),
              !browserAccessibilityOn.contains(pid) else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, Self.messagingTimeout)
        let result = AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // A busy browser (timeout) is asked again next time; a definite answer is final.
        if result == .success || result == .attributeUnsupported || result == .actionUnsupported {
            browserAccessibilityOn.insert(pid)
        }
    }

    /// What has focus now. Nil only when no app is frontmost.
    ///
    /// `includePage` false skips the window title and the page address (the
    /// address walks up the AX tree): enough for an identity check.
    func snapshot(includePage: Bool = true) -> DeliveryTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier
        // A browser already in front when the app started has not been switched on yet.
        // This press may still miss its address (the tree takes about 90 ms); later ones won't.
        if includePage { enableBrowserAccessibility(pid: pid, bundleID: bundleID) }
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

    // MARK: - Text before the caret

    /// The longest the read may take. The answer is needed only when the transcript is
    /// ready, so this never delays the press; it only bounds how long the work runs.
    nonisolated static let cursorReadBudget: TimeInterval = 0.15

    /// Up to `TextBeforeCursor.limit` characters before the caret in the target's focused
    /// field, or nil. Nil for a password field, an app that exposes no text, a field that
    /// answers too slowly or any AX error. The text is returned to the caller and kept
    /// nowhere else: it is not logged and not stored.
    ///
    /// Only the element captured at the press is read (never whatever has focus now), and
    /// the AX calls run off the main thread, so a busy app cannot stall the main run loop.
    func textBeforeCursor(of target: DeliveryTarget) async -> String? {
        guard AXIsProcessTrusted(), let id = target.elementID, let element = elements[id] else { return nil }
        let box = ElementBox(element)
        return await withCheckedContinuation { continuation in
            let once = FirstResult<String?>(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                once.resume(Self.readTextBeforeCursor(box.element))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.cursorReadBudget) {
                once.resume(nil)
            }
        }
    }

    /// Hands an AX element to a background queue. An `AXUIElement` is a thread-safe
    /// Core Foundation reference; the type just isn't marked `Sendable`.
    private final class ElementBox: @unchecked Sendable {
        let element: AXUIElement
        init(_ element: AXUIElement) { self.element = element }
    }

    private nonisolated static func readTextBeforeCursor(_ element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, Float(cursorReadBudget))
        // A password field is never read, whatever else it reports.
        if IsSecureEventInputEnabled() { return nil }
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == "AXSecureTextField" { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range) else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else { return nil }
        return TextBeforeCursor.extract(value: value, caretUTF16: range.location)
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
