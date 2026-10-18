import AppKit
import UsefulVoiceCore

/// Save and restore the user's clipboard around a synthetic paste or copy.
///
/// Dictation temporarily puts its text on the clipboard to drive Cmd-V, so we
/// snapshot the clipboard first and put it back once the paste has landed.
///
/// The restore is not lossless. Only the types in `eagerTypes` (plain text, RTF,
/// RTFD, HTML, tab-separated text, URLs and file URLs, TIFF, PNG and PDF) are copied
/// and put back. Any other type on an item (an app's private type, a web archive, a
/// spreadsheet's own format, a file promise) is not restored: a rich copy comes back
/// with its text, RTF, HTML and image representations only. Paste-once and password
/// manager items are never touched at all (`sensitiveTypes`).
enum Clipboard {
    /// Marks pasteboard items Useful Voice itself wrote during delivery. snapshot()
    /// skips them: deep-copying one would force its lazy PasteSentinel promise
    /// (faking a consumed paste) and capture our own dictation as "the user's
    /// clipboard".
    static let deliveryMarker = NSPasteboard.PasteboardType(DeliveryMarker.current)

    /// Types we copy out eagerly. Reading an arbitrary pasteboard type can be a
    /// blocking IPC round trip to the app that owns the data (a promised file
    /// from Finder, a lazily-rendered image), and a slow or busy owner stalls
    /// whoever is reading. The whitelist keeps delivery responsive: anything not
    /// listed is treated as "cannot be copied", which takes the safe branch
    /// (keep the dictation on the clipboard) instead of hanging the app.
    static let eagerTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .rtf, .rtfd, .html, .tabularText, .URL, .fileURL,
        .tiff, .png, .pdf,
    ]

    /// Types password managers and other apps put on an item they do not want kept
    /// (nspasteboard.org): a secret, or a value meant to be pasted once. Such an item
    /// is never copied into our process, and the clipboard is never restored over it.
    static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    ]

    /// The outcome of a snapshot, so callers can tell "the clipboard was empty"
    /// apart from "the clipboard holds data we could not copy".
    enum SnapshotResult {
        /// Everything the clipboard held was copied and can be restored.
        case complete([NSPasteboardItem])
        /// The clipboard was empty; there is nothing to restore.
        case empty
        /// Some item or representation could not be copied. Restoring a partial
        /// snapshot would replace the user's clipboard with less than it held,
        /// so delivery must keep the dictation instead.
        case incomplete(reason: String)
    }

    /// Deep-copy the current items so they survive a `clearContents()`.
    static func snapshot(_ pasteboard: NSPasteboard = .general) -> SnapshotResult {
        guard let items = pasteboard.pasteboardItems else { return .empty }
        // Looked at by type name only, before any data is read: a password manager's
        // entry must not be copied into this process, and putting it back later
        // would turn a transient copy into a lasting one.
        if items.contains(where: { $0.types.contains { sensitiveTypes.contains($0.rawValue) } }) {
            return .incomplete(reason: "the clipboard holds a concealed or transient item")
        }
        // Both identities' markers: a paste the old build left is still ours.
        let userItems = items.filter { !DeliveryMarker.marks(types: $0.types.map(\.rawValue)) }
        guard !userItems.isEmpty else { return .empty }

        var copies: [NSPasteboardItem] = []
        for item in userItems {
            let copy = NSPasteboardItem()
            for type in item.types where eagerTypes.contains(type) {
                // A listed type whose data cannot be read (a failed file promise, an
                // owner that went away) would be silently missing from the restore.
                guard let data = item.data(forType: type) else {
                    return .incomplete(reason: "\(type.rawValue) on the clipboard could not be read")
                }
                copy.setData(data, forType: type)
            }
            // An item with no representations means nothing readable was
            // available. Restoring it would clear the clipboard and put back
            // nothing, so fail the snapshot instead.
            guard !copy.types.isEmpty else {
                return .incomplete(reason: "an item on the clipboard could not be copied")
            }
            copies.append(copy)
        }
        return .complete(copies)
    }

    /// The restorable item list, or nil when restoring would lose data.
    static func restorableItems(from result: SnapshotResult) -> [NSPasteboardItem]? {
        switch result {
        case .complete(let items): return items
        case .empty, .incomplete: return nil
        }
    }

    /// Put a snapshot back, verifying the write actually took effect.
    ///
    /// `clearContents()` invalidates the previous pasteboard owner immediately
    /// and is not atomic with the write that follows, so an unchecked
    /// `writeObjects` could leave the clipboard *empty* — losing both the user's
    /// data and, if it happened on the delivery write, the dictation itself.
    /// Returns false when the clipboard does not hold what we tried to write.
    @discardableResult
    static func restore(_ items: [NSPasteboardItem],
                        to pasteboard: NSPasteboard = .general) -> Bool {
        guard !items.isEmpty else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { return false }
        // Read back: a "successful" write of items with no usable
        // representations still leaves an empty clipboard.
        return pasteboard.pasteboardItems?.isEmpty == false
    }

    /// Write a single plain string to the clipboard and confirm it landed.
    ///
    /// Falls back to `setString` when the item-based write does not verify,
    /// because leaving the user with an empty clipboard is the worst outcome.
    @discardableResult
    static func writeString(_ text: String,
                            marker: Bool,
                            to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if marker {
            item.setString("1", forType: deliveryMarker)
        }
        let wrote = pasteboard.writeObjects([item])
        if wrote, pasteboard.string(forType: .string) == text { return true }

        // Last resort: the simple API, which either works or reports failure.
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        if marker, let written = pasteboard.pasteboardItems?.first {
            written.setString("1", forType: deliveryMarker)
        }
        return pasteboard.string(forType: .string) == text
    }
}
