import Foundation

/// What delivery should do once the paste-verification window has closed and a
/// direct AX insert (if any) has been attempted. Two of the four cases restore
/// the user's clipboard; the other two deliberately leave the dictation on it.
///
/// The split exists to fix the clipboard-loss bug: the old code declared a paste
/// "consumed" the moment ANYONE read the pasteboard (Universal Clipboard,
/// Handoff, a clipboard manager), then restored the user's previous clipboard,
/// wiping the dictation when the paste had not actually landed. Delivery now only
/// restores when the *target element itself* is observed to have grown, so a
/// third-party read can never trigger the destructive restore.
public enum DeliveryDecision: Equatable, Sendable {
    /// The focused element grew: the paste landed. Restore the user's clipboard.
    case pastedRestore
    /// A direct AX insert grew the element. Restore the user's clipboard.
    case insertedViaAXRestore
    /// Target is AX-blind (Electron, web views, terminals). These handle Cmd-V
    /// themselves, so a posted paste almost always landed, but we cannot prove
    /// it. Assume success (no nagging hint) yet keep the dictation on the
    /// clipboard instead of restoring, so nothing is ever lost.
    case keepDictationPasted
    /// A genuine miss, or the paste could never be posted. Keep the dictation on
    /// the clipboard and tell the user to paste it.
    case keepDictationManual

    /// Whether this decision restores the user's previous clipboard. The two
    /// keep-dictation cases never do; that is what guarantees the dictation
    /// survives a missed insert.
    public var restoresUserClipboard: Bool {
        switch self {
        case .pastedRestore, .insertedViaAXRestore: return true
        case .keepDictationPasted, .keepDictationManual: return false
        }
    }

    /// Whether the user should be told to paste manually.
    public var needsManualPasteHint: Bool { self == .keepDictationManual }
}

/// The pure decision at the heart of text delivery, kept out of the AppKit/AX
/// layer so it can be exhaustively tested. The effects (reading the focused
/// element's character count, posting Cmd-V, AX-inserting) live in TextInserter;
/// this only decides what to do with their results.
public enum DeliveryPolicy {
    /// Decide the outcome after the paste did NOT grow the focused element (so we
    /// are past the happy path) and a direct AX insert has been attempted where
    /// possible.
    ///
    /// - Parameters:
    ///   - pastePosted: a synthetic Cmd-V was actually posted (Accessibility
    ///     trust is required to post one).
    ///   - axVisible: the focused element exposed a character count, so its
    ///     growth can be measured and a direct AX insert can be verified.
    ///   - axInsertGrew: a direct AX insert was attempted and the element grew.
    ///   - targetChanged: the measured element changed after the paste, but not by
    ///     exactly the payload (its count moved by another amount, or the app
    ///     re-created it). Web composers do this: Claude's and Slack's report a
    ///     count one or two off, so a paste that landed read as a miss.
    ///
    /// "Never ask for a manual paste after a sent keystroke" covers only what can't
    /// be measured: an AX-blind target, a field that stopped answering or changed
    /// by another amount, and a type-out that sent every batch (decided before this
    /// runs). A measurable field whose count did not move after a paste, with an AX
    /// insert that did not grow it either, is measured evidence of a miss: that one
    /// still asks for Cmd-V.
    public static func finalDecision(pastePosted: Bool,
                                     axVisible: Bool,
                                     axInsertGrew: Bool,
                                     targetChanged: Bool = false) -> DeliveryDecision {
        if axVisible {
            // We can measure this element. If a direct AX insert grew it, that
            // landed. If the paste changed it without matching the payload, the
            // paste almost certainly landed: treat it like an AX-blind target. Only
            // an element neither one touched is a real miss to paste by hand.
            if axInsertGrew { return .insertedViaAXRestore }
            return pastePosted && targetChanged ? .keepDictationPasted : .keepDictationManual
        }
        // AX-blind target. If we managed to post the paste, assume it landed
        // (these apps handle Cmd-V) but keep the dictation as a safety net. If we
        // could not even post it, there is nothing on screen: ask for a manual
        // paste.
        return pastePosted ? .keepDictationPasted : .keepDictationManual
    }

    /// Whether the user's previous clipboard may be written back now.
    ///
    /// - Parameters:
    ///   - proven: the text provably landed (the element grew by the payload, or a
    ///     decision that `restoresUserClipboard`).
    ///   - canRestoreSafely: the snapshot was copied in full (or the clipboard was
    ///     empty); a partial copy must never replace the user's data.
    ///   - restorePreviousClipboard: the user's setting. Off leaves the dictation
    ///     on the clipboard even after a proven paste.
    public static func shouldRestoreClipboard(proven: Bool,
                                              canRestoreSafely: Bool,
                                              restorePreviousClipboard: Bool) -> Bool {
        proven && canRestoreSafely && restorePreviousClipboard
    }
}
