import Foundation

/// How text goes into the target. Exactly one per delivery: a delivery that types
/// never posts Cmd-V, and one that pastes never types, so the text cannot land
/// twice.
public enum InsertionMethod: Equatable, Sendable {
    /// Synthetic Cmd-V (Ctrl+V on Windows) of the dictation on the clipboard.
    case paste
    /// Synthesised Unicode keystrokes, for terminals and apps that block paste.
    /// Not layout dependent: each event carries the characters themselves.
    case typeOut
    /// Neither: the text only goes on the clipboard. For an app that types, when the
    /// text has a line break.
    case copyOnly

    /// The method for an app, from the per-app "type it out" list. Paste unless the
    /// user turned typing on for this app. An unknown app always pastes.
    ///
    /// Text with a line break is never typed: a typed line break is an Enter key,
    /// which sends the message in a chat app or runs the line in a terminal. Nor is it
    /// pasted into an app the user marked for typing (paste doesn't work there), so
    /// it is copied only.
    public static func method(forAppID appID: String?, typeOutApps: [String], text: String) -> InsertionMethod {
        guard let appID, !appID.isEmpty else { return .paste }
        let key = appID.lowercased()
        guard typeOutApps.contains(where: { $0.lowercased() == key }) else { return .paste }
        return text.contains(where: \.isNewline) ? .copyOnly : .typeOut
    }
}

/// Splits text into keystroke-sized chunks for type-out.
///
/// A synthesised Unicode key event carries a short string (macOS reads up to 20
/// UTF-16 units from `keyboardSetUnicodeString`). A chunk boundary never falls
/// inside a surrogate pair (an emoji) or between a CR and its LF, which would
/// send half a character.
public enum TypeOutChunker {
    public static let maxUnitsPerEvent = 20

    public static func chunks(of text: String, maxUnits: Int = maxUnitsPerEvent) -> [[UInt16]] {
        let limit = max(2, maxUnits)
        let units = Array(text.utf16)
        var result: [[UInt16]] = []
        var start = 0
        while start < units.count {
            var end = min(start + limit, units.count)
            if end < units.count {
                let last = units[end - 1]
                // A high surrogate at the end belongs with the low one after it.
                let splitsPair = UTF16.isLeadSurrogate(last)
                let splitsCRLF = last == 0x0D && units[end] == 0x0A
                if splitsPair || splitsCRLF { end -= 1 }
            }
            result.append(Array(units[start..<end]))
            start = end
        }
        return result
    }
}

/// Browsers whose page address delivery may read with Accessibility at the hotkey
/// press: every browser the category registry knows, so a browser the registry lists
/// never formats as Other just because its address was not read. Anything else never
/// has a URL read.
public enum KnownBrowsers {
    public static func isBrowser(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return AppCategoryRegistry.isBrowser(bundleID)
    }
}
