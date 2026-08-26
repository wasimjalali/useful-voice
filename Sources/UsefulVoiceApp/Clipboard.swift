import AppKit

/// Save and restore the user's clipboard around a synthetic paste or copy.
///
/// Dictation temporarily puts its text on the clipboard to drive Cmd-V.
/// Good dictation tools never leave the user's
/// clipboard clobbered, so we snapshot it first and put it back once the paste
/// has landed. Promised/lazy types (file promises and the like) can't be copied
/// out and are dropped on restore; the common types (text, RTF, images, URLs)
/// round-trip fine.
enum Clipboard {
    /// Marks pasteboard items Useful Voice itself wrote during delivery. snapshot()
    /// skips them: deep-copying one would force its lazy PasteSentinel promise
    /// (faking a consumed paste) and capture our own dictation as "the user's
    /// clipboard".
    static let deliveryMarker = NSPasteboard.PasteboardType("ai.karko.sadaa.delivery")

    /// Deep-copy the current items so they survive a `clearContents()`.
    static func snapshot(_ pasteboard: NSPasteboard = .general) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.compactMap { item in
            guard !item.types.contains(deliveryMarker) else { return nil }
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Put a snapshot back. A no-op for an empty snapshot, which leaves whatever
    /// is currently on the clipboard in place (used as the never-lose backup).
    static func restore(_ items: [NSPasteboardItem],
                        to pasteboard: NSPasteboard = .general) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
