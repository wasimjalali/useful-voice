import AppKit
import ApplicationServices
import Carbon.HIToolbox
import UsefulVoiceCore

/// How a paste-mode delivery ended (see `InsertionOutcome` in the core).
typealias DeliveryOutcome = InsertionOutcome

/// Delivers final text: paste at the cursor (or typed, for apps the user chose),
/// AX insert as a fallback, and the clipboard as the never-lose backup. The user's
/// own clipboard is restored across delivery, but ONLY when we can prove the text
/// actually landed.
///
/// Why proof matters (the clipboard-loss bug): the previous version put the text
/// on the clipboard as a lazy promise and treated the promise being read as
/// proof the target consumed the paste. But the pasteboard is shared, so a
/// third-party read looked like a consumed paste, delivery reported success, and
/// the destructive restore wiped the dictation when the paste had never landed.
///
/// Delivery now verifies against the TARGET: it reads the focused element's
/// identity and character count before and after, and only restores the user's
/// clipboard when that same element grew by exactly the payload length. Every
/// uncertain path errs toward keeping the dictation.
///
/// The order of it all (checks, method, proof, fallback, restore) is the core's
/// `InsertionFlow`, tested in `InsertionFlowTests`; this struct supplies the macOS
/// effects.
struct TextInserter {
    private let timing: InsertionTiming

    // Effects, injected so the policy can be exercised without AppKit.
    private let pasteboard: () -> NSPasteboard
    private let isSecureInput: () -> Bool
    /// Posts a synthetic Cmd-V. Returns whether it could be posted at all
    /// (Accessibility trust is required); false means it never went out.
    private let synthesizePaste: () -> Bool
    /// Posts one batch of UTF-16 units as Unicode key events (type-out mode).
    private let postKeys: ([UInt16]) -> Bool
    /// Writes text into the focused element via AX. Returns the raw AX result,
    /// which is not trusted on its own (Terminal reports success but inserts
    /// nothing) - the flow verifies with a character-count check.
    private let axInsert: (String) -> Bool
    /// Identifies the focused element and reports its character count, or nil
    /// when the element is AX-blind (Electron, web views, terminals) or there is
    /// no Accessibility trust.
    private let focusedProbe: () -> FocusProbe?
    /// Restores the user's clipboard after delivery. Returns false when the
    /// clipboard could not be restored (it changed, or the write failed).
    private let restoreClipboard: (_ items: [NSPasteboardItem], _ pb: NSPasteboard,
                                   _ expectedChangeCount: Int) -> Bool
    /// Schedules `work` after `delay`. Real delivery uses the main queue.
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// Called after delivery so the app layer can keep the snapshot available
    /// for the user's undo window.
    private let onDeliverySettled: (() -> Void)?

    init(pasteboard: @escaping () -> NSPasteboard = { .general },
         isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         synthesizePaste: @escaping () -> Bool = TextInserter.postCommandV,
         postKeys: @escaping ([UInt16]) -> Bool = TextInserter.postUnicodeBatch,
         axInsert: @escaping (String) -> Bool = TextInserter.axWriteSelectedText,
         focusedProbe: @escaping () -> FocusProbe? = TextInserter.probeFocusedElement,
         restoreClipboard: @escaping ([NSPasteboardItem], NSPasteboard, Int) -> Bool
            = TextInserter.restoreIfUnchanged,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void
            = TextInserter.mainQueueSchedule,
         onDeliverySettled: (() -> Void)? = nil,
         timing: InsertionTiming = InsertionTiming()) {
        self.pasteboard = pasteboard
        self.isSecureInput = isSecureInput
        self.synthesizePaste = synthesizePaste
        self.postKeys = postKeys
        self.axInsert = axInsert
        self.focusedProbe = focusedProbe
        self.restoreClipboard = restoreClipboard
        self.schedule = schedule
        self.onDeliverySettled = onDeliverySettled
        self.timing = timing
    }

    /// - Parameters:
    ///   - request: the text, the target's app (which picks paste or type-out) and
    ///     the user's clipboard setting.
    ///   - onTarget: checked right before anything is posted. False means the target
    ///     captured at the hotkey press is no longer focused (or shows another page):
    ///     nothing is posted and the dictation stays on the clipboard.
    ///   - stillOnTarget: checked before every typed batch after the first, by
    ///     identity only (no page read). False stops typing.
    func deliver(_ request: InsertionRequest,
                 onTarget: @escaping () -> Bool = { true },
                 stillOnTarget: @escaping () -> Bool = { true },
                 completion: @escaping (DeliveryOutcome) -> Void = { _ in }) {
        let pb = pasteboard()
        // The user's clipboard, copied aside by `saveClipboard`, and the change count
        // of our own write, so a restore never clobbers something copied since.
        final class Saved { var items: [NSPasteboardItem] = []; var changeCount = 0 }
        let saved = Saved()
        let effects = InsertionEffects(
            isSecureInput: isSecureInput,
            saveClipboard: {
                let snapshot = Clipboard.snapshot(pb)
                saved.items = Clipboard.restorableItems(from: snapshot) ?? []
                // A clipboard we could not fully copy must never be "restored": that
                // would replace the user's data with less than it held.
                return !saved.items.isEmpty || snapshot.isEmptiness
            },
            writeClipboard: { text in
                // Concrete (not lazy), marked so a re-entrant snapshot skips our item.
                guard Clipboard.writeString(text, marker: true, to: pb) else { return false }
                saved.changeCount = pb.changeCount
                return true
            },
            recoverClipboard: {
                if !saved.items.isEmpty { Clipboard.restore(saved.items, to: pb) }
            },
            restoreClipboard: { self.restoreClipboard(saved.items, pb, saved.changeCount) },
            onTarget: onTarget,
            stillOnTarget: stillOnTarget,
            postPaste: synthesizePaste,
            postKeys: postKeys,
            axInsert: axInsert,
            probe: focusedProbe,
            schedule: schedule,
            settled: { self.onDeliverySettled?() })
        InsertionFlow.run(request, timing: timing, effects: effects, completion: completion)
    }

    /// Copy mode: puts `text` on the clipboard and nothing else. No snapshot, no
    /// restore (the user asked for this text to be copied, so it must stay), no
    /// paste, no secure-input check (nothing is typed anywhere). Returns false when
    /// the write failed (also logged); the dictation is still in History.
    @discardableResult
    func copy(_ text: String) -> Bool {
        guard Clipboard.writeString(text, marker: false, to: pasteboard()) else {
            Diagnostics.shared.error("delivery", "could not write the dictation to the clipboard")
            return false
        }
        return true
    }

    // MARK: - Real macOS effects

    private static func mainQueueSchedule(_ delay: TimeInterval,
                                          _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Identifies the focused element and reads its character count.
    ///
    /// The identifier lets the post-paste check prove it is comparing the same
    /// element: focus moving between the two reads used to produce a meaningless
    /// "it grew" verdict that triggered the destructive clipboard restore.
    /// Returns nil when there is no Accessibility trust or no focused element.
    private static func probeFocusedElement() -> FocusProbe? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement

        // A cross-process AX call blocks on the target app; without a timeout a
        // busy target stalls this thread for the full default (several seconds).
        AXUIElementSetMessagingTimeout(element, 0.5)

        var countRef: CFTypeRef?
        let count: Int?
        if AXUIElementCopyAttributeValue(
                element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           let value = countRef as? Int {
            count = value
        } else {
            count = nil
        }

        // Prefer the element's own identifier; it is stable for a given control
        // and distinguishes fields in the same window.
        //
        // The element part uses CFHash, which AXUIElement derives from the
        // process and the element it names, so two lookups of the same field
        // hash the same. The previous ObjectIdentifier hashed the wrapper
        // object, and every AX lookup allocates a fresh wrapper: the before
        // and after probes never matched, the paste was never proven, and the
        // AX fallback then inserted the text a second time into every native
        // text view that accepts it (the "double paste").
        var idRef: CFTypeRef?
        let identifier: String
        if AXUIElementCopyAttributeValue(
                element, kAXIdentifierAttribute as CFString, &idRef) == .success,
           let value = idRef as? String, !value.isEmpty {
            identifier = "\(value)#\(CFHash(element))"
        } else {
            // No AX identifier (most native text views): fall back to the
            // element identity plus its role, which is still enough to notice
            // that focus moved to a different control.
            var roleRef: CFTypeRef?
            let role = (AXUIElementCopyAttributeValue(
                element, kAXRoleAttribute as CFString, &roleRef) == .success)
                ? (roleRef as? String ?? "?") : "?"
            identifier = "\(role)#\(CFHash(element))"
        }
        return FocusProbe(identifier: identifier, charCount: count)
    }

    private static func axWriteSelectedText(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusErr == .success, let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.5)

        // Writing kAXSelectedText replaces the selection (or inserts at the
        // caret when there's no selection).
        let setErr = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return setErr == .success
    }

    /// Restores the user's clipboard, unless something else was copied since we
    /// wrote ours; clobbering a newer copy would lose the user's data.
    private static func restoreIfUnchanged(_ items: [NSPasteboardItem],
                                           _ pb: NSPasteboard,
                                           _ expectedChangeCount: Int) -> Bool {
        guard !items.isEmpty else { return false }
        guard pb.changeCount == expectedChangeCount else { return false }
        return Clipboard.restore(items, to: pb)
    }

    /// Posts one batch of UTF-16 units as a synthesised Unicode key press.
    ///
    /// The event carries the characters themselves (`keyboardSetUnicodeString`), so
    /// the result does not depend on the keyboard layout. The batches come from
    /// `TypeOutChunker` (never splitting an emoji); `InsertionFlow` schedules them
    /// one by one and checks for a password field and the target before each.
    private static func postUnicodeBatch(_ units: [UInt16]) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return false }
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        // No modifiers: a key still held from the hotkey must not turn the text
        // into shortcuts.
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Presses the Return key with the chord's modifiers (auto-send, after a dictation
    /// landed). Needs Accessibility trust like a paste; without it nothing is posted.
    static func postSendKey(_ chord: SendKeyChord) {
        guard AXIsProcessTrusted(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
        else { return }
        var flags: CGEventFlags = []
        if chord.shift { flags.insert(.maskShift) }
        if chord.command { flags.insert(.maskCommand) }
        if chord.control { flags.insert(.maskControl) }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postCommandV() -> Bool {
        // Posting a synthetic keystroke needs Accessibility trust; an untrusted
        // process has its events silently dropped. Gate here so deliver() falls
        // back (and the HUD shows the manual-paste hint) instead of waiting on
        // a paste that can never land.
        guard AXIsProcessTrusted() else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: 9, keyDown: true),  // V
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: 9, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

private extension Clipboard.SnapshotResult {
    /// True when the clipboard was genuinely empty, which *is* safe to restore
    /// over (there is nothing to lose).
    var isEmptiness: Bool {
        if case .empty = self { return true }
        return false
    }
}
