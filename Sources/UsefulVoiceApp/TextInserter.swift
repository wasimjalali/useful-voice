import AppKit
import ApplicationServices
import Carbon.HIToolbox
import UsefulVoiceCore

enum DeliveryOutcome {
    case insertedViaAX   // typed into the focused element
    case pasted          // synthetic Cmd-V landed (or a Cmd-V app where we can't prove it)
    case clipboardOnly   // nothing landed; the user pastes manually
}

/// Delivers final text: paste at the cursor, AX insert as a fallback, and the
/// clipboard as the never-lose backup. The user's own clipboard is restored
/// across delivery, but ONLY when we can prove the text actually landed.
///
/// Why proof matters (the clipboard-loss bug): the previous version put the text
/// on the clipboard as a lazy promise and treated the promise being read as
/// proof the target consumed the paste. But the pasteboard is shared: Universal
/// Clipboard, Handoff and clipboard managers all read it too. Their read looked
/// like a consumed paste, so delivery reported success and restored the user's
/// previous clipboard, wiping the dictation when the paste had never landed.
/// Cmd-V then pasted nothing and the text survived only in History.
///
/// Delivery now verifies against the TARGET, not the shared pasteboard: it reads
/// the focused element's character count before and after, and only restores the
/// user's clipboard when that element actually grew. A third-party read can no
/// longer trigger the destructive restore. The dictation is written to the
/// clipboard as a concrete string up front, so a missed insert always leaves
/// something to paste. Every uncertain path errs toward keeping the dictation.
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
    /// The focused element's character count, or nil when the element is AX-blind
    /// (Electron, web views, terminals) or there is no Accessibility trust.
    private let focusedCharCount: () -> Int?
    /// Schedules `work` after `delay`. Real delivery uses the main queue; tests
    /// run it inline.
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(pasteboard: @escaping () -> NSPasteboard = { .general },
         isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
         synthesizePaste: @escaping () -> Bool = TextInserter.postCommandV,
         axInsert: @escaping (String) -> Bool = TextInserter.axWriteSelectedText,
         focusedCharCount: @escaping () -> Int? = TextInserter.readFocusedCharCount,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = TextInserter.mainQueueSchedule,
         firstCheck: TimeInterval = 0.25,
         finalCheck: TimeInterval = 0.6) {
        self.pasteboard = pasteboard
        self.isSecureInput = isSecureInput
        self.synthesizePaste = synthesizePaste
        self.axInsert = axInsert
        self.focusedCharCount = focusedCharCount
        self.schedule = schedule
        self.firstCheck = firstCheck
        self.finalCheck = finalCheck
    }

    func deliver(_ text: String,
                 completion: @escaping (DeliveryOutcome) -> Void = { _ in }) {
        let pb = pasteboard()

        // A secure field is active: never type or paste into a password box.
        // Leave the text on the clipboard so the user can paste it somewhere
        // safe themselves. Spec section 5.
        if isSecureInput() {
            writeDelivery(text, to: pb)
            completion(.clipboardOnly)
            return
        }

        // Snapshot the user's clipboard for a possible restore, and the focused
        // element's size so we can later tell whether it actually grew.
        let saved = Clipboard.snapshot(pb)
        let before = focusedCharCount()
        // Concrete (not lazy) so a missed insert always leaves something to
        // paste, marked so a re-entrant snapshot skips our own item.
        writeDelivery(text, to: pb)
        let ourChangeCount = pb.changeCount

        let posted = synthesizePaste()

        // Run when the paste was not confirmed: try a direct AX insert where we
        // can verify it, then decide. Reaching here with an AX-visible target
        // means the paste did NOT grow the element, so AX insert can't
        // double-insert.
        let runFallback = {
            var axInsertGrew = false
            if before != nil, !self.isSecureInput(),
               self.axInsert(text), let after = self.focusedCharCount(),
               let b = before, after > b {
                axInsertGrew = true
            }
            let decision = DeliveryPolicy.finalDecision(
                pastePosted: posted, axVisible: before != nil,
                axInsertGrew: axInsertGrew)
            self.apply(decision, saved: saved, to: pb,
                       expectedChangeCount: ourChangeCount, completion: completion)
        }

        guard posted else { runFallback(); return }

        // Checks are scheduled, never blocking, so the target stays responsive
        // while it reads the clipboard and grows.
        schedule(firstCheck) {
            if self.grew(from: before) {
                self.restoreIfUnchanged(saved, to: pb, expectedChangeCount: ourChangeCount)
                completion(.pasted)
                return
            }
            self.schedule(self.finalCheck - self.firstCheck) {
                if self.grew(from: before) {
                    self.restoreIfUnchanged(saved, to: pb, expectedChangeCount: ourChangeCount)
                    completion(.pasted)
                } else {
                    runFallback()
                }
            }
        }
    }

    /// Whether the focused element grew since `before`. False when either count
    /// is unreadable (AX-blind) - an unverifiable target never counts as proof.
    private func grew(from before: Int?) -> Bool {
        guard let before, let after = focusedCharCount() else { return false }
        return after > before
    }

    private func apply(_ decision: DeliveryDecision,
                       saved: [NSPasteboardItem], to pb: NSPasteboard,
                       expectedChangeCount: Int,
                       completion: (DeliveryOutcome) -> Void) {
        if decision.restoresUserClipboard {
            restoreIfUnchanged(saved, to: pb, expectedChangeCount: expectedChangeCount)
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
    }

    /// Writes the dictation as a concrete string plus a marker so Clipboard
    /// snapshots never mistake our own delivery for the user's clipboard.
    private func writeDelivery(_ text: String, to pb: NSPasteboard) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("1", forType: Clipboard.deliveryMarker)
        pb.writeObjects([item])
    }

    /// Restores the user's clipboard, unless something else was copied since we
    /// wrote ours; clobbering a newer copy would lose the user's data.
    private func restoreIfUnchanged(_ items: [NSPasteboardItem],
                                    to pb: NSPasteboard,
                                    expectedChangeCount: Int) {
        guard !items.isEmpty else { return }
        guard pb.changeCount == expectedChangeCount else { return }
        Clipboard.restore(items, to: pb)
    }

    // MARK: - Real macOS effects

    private static func mainQueueSchedule(_ delay: TimeInterval,
                                          _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The focused element's character count via the system-wide AX element, or
    /// nil when it can't be read (no trust, or an AX-blind target).
    private static func readFocusedCharCount() -> Int? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return nil }
        let element = focusedRef as! AXUIElement
        var countRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              let count = countRef as? Int else { return nil }
        return count
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

        // Writing kAXSelectedText replaces the selection (or inserts at the
        // caret when there's no selection).
        let setErr = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return setErr == .success
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
