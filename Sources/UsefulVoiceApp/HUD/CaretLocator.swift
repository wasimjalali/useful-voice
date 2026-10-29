import AppKit
import ApplicationServices

/// Where the text cursor of the app in front is, through Accessibility, so the HUD
/// can sit beside it. Most native apps answer; many browsers and Electron apps do
/// not, and then the HUD keeps its bottom-centre place.
///
/// Every call carries a short messaging timeout and the lookup stops once 0,15 s
/// have gone, so an app that hangs delays the dictation start by at most that.
enum CaretLocator {
    /// Per-call Accessibility timeout, and the budget for the whole lookup, in seconds.
    private static let timeout: Float = 0.05
    private static let budget: TimeInterval = 0.15

    /// Live checks only (`UV_HUD_DEMO_PID`): read this app's focused element instead
    /// of the system's, so a check can point at a window that is not in front.
    static var targetPID: pid_t?

    /// The caret in Cocoa screen coordinates (origin at the bottom-left of the
    /// primary display), or nil when the app in front does not report one we can trust.
    static func locate() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = Date().addingTimeInterval(budget)
        func inTime() -> Bool { Date() < deadline }
        let source = targetPID.map { AXUIElementCreateApplication($0) } ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(source, timeout)
        guard let element = element(source, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        // Our own window copies instead of pasting, and has no caret to point at.
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }
        // A password field is a text field with the secure subrole.
        if string(element, kAXSubroleAttribute) == "AXSecureTextField"
            || string(element, kAXRoleAttribute) == "AXSecureTextField" { return nil }

        guard inTime(), let rangeValue = value(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0 else { return nil }
        let end = range.location + range.length

        // The empty range at the caret first. Many apps answer it with a zero rect,
        // so fall back to the character before the caret and use its trailing edge.
        guard inTime() else { return nil }
        if let rect = bounds(element, CFRange(location: end, length: 0)), isUsable(rect) {
            return cocoa(rect)
        }
        if end > 0, inTime(), let rect = bounds(element, CFRange(location: end - 1, length: 1)), isUsable(rect) {
            return cocoa(CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height))
        }
        return nil
    }

    private static func bounds(_ element: AXUIElement, _ range: CFRange) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &out) == .success,
              let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// A caret-sized rect on a display. Apps that do not really know answer with a
    /// zero rect, the whole field, or a point off every screen.
    private static func isUsable(_ rect: CGRect) -> Bool {
        guard rect.height >= 6, rect.height <= 120, rect.width <= 400,
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.origin != .zero else { return false }
        let probe = cocoa(rect)
        let point = CGPoint(x: probe.minX, y: probe.midY)
        return NSScreen.screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// Accessibility measures from the top-left of the primary display, y down.
    private static func cocoa(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &out) == .success else { return nil }
        return out
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let out = copy(element, attribute), CFGetTypeID(out) == AXUIElementGetTypeID() else { return nil }
        return (out as! AXUIElement)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let out = copy(element, attribute), CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        return (out as! AXValue)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }
}
