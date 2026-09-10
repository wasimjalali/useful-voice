import AppKit
import ApplicationServices
import Carbon.HIToolbox
import UsefulVoiceCore

enum DeliveryOutcome {
    case insertedViaAX   // typed into the focused element
    case pasted          // synthetic Cmd-V landed (or a Cmd-V app where we can't prove it)
    case clipboardOnly   // nothing landed; the user pastes manually
}

/// Proof that a paste actually landed, gathered from the *target* element.
///
/// Pasting is verified against the focused element, never against the shared
/// pasteboard: Universal Clipboard, Handoff and clipboard managers all read the
/// pasteboard too, and their read used to be mistaken for a consumed paste.
struct PasteProof: Equatable {
    /// Identity of the element that was focused before the paste. A different
    /// element afterwards means the character counts are not comparable.
    let elementIdentifier: String
    /// Character count of that element before the paste, when readable.
    let beforeCount: Int?
    /// Character count now, when readable.
    let afterCount: Int?
    /// Length of the text we were trying to insert.
    let payloadLength: Int

    var growth: Int? {
        guard let beforeCount, let afterCount else { return nil }
        return afterCount - beforeCount
    }

    /// Whether the growth is consistent with our payload landing.
    ///
    /// A bare `after > before` accepted a growth of one character as proof that
    /// a 400-character dictation had landed, and accepted growth caused by the
    /// user typing something unrelated. Requiring the growth to account for the
    /// payload makes "landed" mean what it says; anything less falls through to
    /// the safe branch that keeps the dictation on the clipboard.
    var isConsistentWithPayload: Bool {
        guard growth == payloadLength else { return false }
        return true
    }
}

/// Delivers final text: paste at the cursor, AX insert as a fallback, and the
/// clipboard as the never-lose backup. The user's own clipboard is restored
/// across delivery, but ONLY when we can prove the text actually landed.
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
struct TextInserter {
    /// First consumption check. A synthetic Cmd-V is usually consumed within
    /// tens of ms; this is a comfortable margin.
    private let firstCheck: TimeInterval
    /// Last-chance check for slow consumers (Electron apps under load).
    private let finalCheck: TimeInterval

    // Effects, injected so the policy can be exercised in tests without AppKit.
    private let pasteboard: () -> NSPasteboard
    private let isSecureInput: () -> Bool
    /// Posts a synthetic Cmd-V. Returns whether it could be posted at all
    /// (Accessibility trust is required); false means it never went out.
    private let synthesizePaste: () -> Bool
    /// Writes text into the focused element via AX. Returns the raw AX result,
    /// which is not trusted on its own (Terminal reports success but inserts
    /// nothing) - the caller verifies with a character-count check.
    private let axInsert: (String) -> Bool
    /// Identifies the focused element and reports its character count, or nil
    /// when the element is AX-blind (Electron, web views, terminals) or there is
    /// no Accessibility trust.
    private let focusedProbe: () -> (identifier: String, charCount: Int?)?
    /// Restores the user's clipboard after delivery. Returns false when the
    /// clipboard could not be restored (it changed, or the write failed).
    private let restoreClipboard: (_ items: [NSPasteboardItem], _ pb: NSPasteboard,
                                   _ expectedChangeCount: Int) -> Bool
    /// Schedules `work` after `delay`. Real delivery uses the main queue; tests
    /// run it inline.
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// Called after delivery so the app layer can keep the snapshot available
    /// for the user's undo window.
    private let onDeliverySettled: (() -> Void)?

    init(pasteboard: @escaping () -> NSPasteboard = { .general },
         isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         synthesizePaste: @escaping () -> Bool = TextInserter.postCommandV,
         axInsert: @escaping (String) -> Bool = TextInserter.axWriteSelectedText,
         focusedProbe: @escaping () -> (identifier: String, charCount: Int?)?
            = TextInserter.probeFocusedElement,
         restoreClipboard: @escaping ([NSPasteboardItem], NSPasteboard, Int) -> Bool
            = TextInserter.restoreIfUnchanged,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void
            = TextInserter.mainQueueSchedule,
         onDeliverySettled: (() -> Void)? = nil,
         firstCheck: TimeInterval = 0.25,
         finalCheck: TimeInterval = 0.6) {
        self.pasteboard = pasteboard
        self.isSecureInput = isSecureInput
        self.synthesizePaste = synthesizePaste
        self.axInsert = axInsert
        self.focusedProbe = focusedProbe
        self.restoreClipboard = restoreClipboard
        self.schedule = schedule
        self.onDeliverySettled = onDeliverySettled
        self.firstCheck = firstCheck
        self.finalCheck = finalCheck
    }

    func deliver(_ text: String,
                 completion: @escaping (DeliveryOutcome) -> Void = { _ in }) {
        let pb = pasteboard()

        // A secure field is active: never type or paste into a password box.
        // Leave the text on the clipboard so the user can paste it somewhere
        // safe themselves. Nothing is snapshotted: a password manager's
        // clipboard entry must not be copied into our process. Spec section 5.
        if isSecureInput() {
            Clipboard.writeString(text, marker: true, to: pb)
            completion(.clipboardOnly)
            return
        }

        // Snapshot the user's clipboard for a possible restore, and the focused
        // element so we can later tell whether it actually grew by our payload.
        let snapshot = Clipboard.snapshot(pb)
        let saved = Clipboard.restorableItems(from: snapshot) ?? []
        // A clipboard we could not fully copy must never be "restored": that
        // would replace the user's data with less than it held. In that case we
        // keep the dictation on the clipboard and tell the user (the HUD shows
        // the manual-paste hint), which loses nothing.
        let canRestoreSafely = !saved.isEmpty || snapshot.isEmptiness
        let probeBefore = focusedProbe()

        // Concrete (not lazy) so a missed insert always leaves something to
        // paste, marked so a re-entrant snapshot skips our own item.
        guard Clipboard.writeString(text, marker: true, to: pb) else {
            // The clipboard could not be written at all. Nothing was posted, so
            // the dictation survives in History; report the manual path.
            completion(.clipboardOnly)
            onDeliverySettled?()
            return
        }
        let ourChangeCount = pb.changeCount

        let posted = synthesizePaste()

        let restore = { (proof: Bool) -> Bool in
            guard proof, canRestoreSafely else { return false }
            return self.restoreClipboard(saved, pb, ourChangeCount)
        }

        // Run when the paste was not confirmed: try a direct AX insert where we
        // can verify it, then decide. Reaching here with an AX-visible target
        // means the paste did NOT grow the element, so AX insert can't
        // double-insert.
        let runFallback = {
            var axInsertGrew = false
            if probeBefore != nil, !self.isSecureInput(),
               self.axInsert(text),
               let after = self.focusedProbe(),
               after.identifier == probeBefore?.identifier,
               let beforeCount = probeBefore?.charCount,
               let afterCount = after.charCount,
               afterCount - beforeCount == text.count {
                axInsertGrew = true
            }
            let decision = DeliveryPolicy.finalDecision(
                pastePosted: posted, axVisible: probeBefore?.charCount != nil,
                axInsertGrew: axInsertGrew)
            self.apply(decision, restore: restore, completion: completion)
        }

        guard posted else { runFallback(); return }

        // Checks are scheduled, never blocking, so the target stays responsive
        // while it reads the clipboard and grows.
        schedule(firstCheck) {
            if self.landed(since: probeBefore, payloadLength: text.count) {
                _ = restore(true)
                completion(.pasted)
                self.onDeliverySettled?()
                return
            }
            self.schedule(self.finalCheck - self.firstCheck) {
                if self.landed(since: probeBefore, payloadLength: text.count) {
                    _ = restore(true)
                    completion(.pasted)
                    self.onDeliverySettled?()
                } else {
                    runFallback()
                }
            }
        }
    }

    /// Whether the paste provably landed: the SAME element is still focused and
    /// it grew by exactly the payload length. An unverifiable target never
    /// counts as proof, and neither does growth of the wrong size or growth in a
    /// different element.
    private func landed(since probeBefore: (identifier: String, charCount: Int?)?,
                        payloadLength: Int) -> Bool {
        guard let probeBefore else { return false }
        guard let after = focusedProbe() else { return false }
        guard after.identifier == probeBefore.identifier else { return false }
        return PasteProof(elementIdentifier: after.identifier,
                           beforeCount: probeBefore.charCount,
                           afterCount: after.charCount,
                           payloadLength: payloadLength)
            .isConsistentWithPayload
    }

    private func apply(_ decision: DeliveryDecision,
                       restore: (Bool) -> Bool,
                       completion: (DeliveryOutcome) -> Void) {
        if decision.restoresUserClipboard {
            _ = restore(true)
        }
        switch decision {
        case .insertedViaAXRestore:
            completion(.insertedViaAX)
        case .pastedRestore, .keepDictationPasted:
            completion(.pasted)
        case .keepDictationManual:
            // The dictation is already concrete on the clipboard; the HUD hint
            // tells the user to paste it.
            completion(.clipboardOnly)
        }
        onDeliverySettled?()
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
    private static func probeFocusedElement() -> (identifier: String, charCount: Int?)? {
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
        var idRef: CFTypeRef?
        let identifier: String
        if AXUIElementCopyAttributeValue(
                element, kAXIdentifierAttribute as CFString, &idRef) == .success,
           let value = idRef as? String, !value.isEmpty {
            identifier = "\(value)#\(ObjectIdentifier(element).hashValue)"
        } else {
            // No AX identifier (most native text views): fall back to the
            // element identity plus its role, which is still enough to notice
            // that focus moved to a different control.
            var roleRef: CFTypeRef?
            let role = (AXUIElementCopyAttributeValue(
                element, kAXRoleAttribute as CFString, &roleRef) == .success)
                ? (roleRef as? String ?? "?") : "?"
            identifier = "\(role)#\(ObjectIdentifier(element).hashValue)"
        }
        return (identifier, count)
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
