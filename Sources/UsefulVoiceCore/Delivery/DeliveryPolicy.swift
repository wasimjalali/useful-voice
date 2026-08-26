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
    public static func finalDecision(pastePosted: Bool,
                                     axVisible: Bool,
                                     axInsertGrew: Bool) -> DeliveryDecision {
        if axVisible {
            // We can measure this element. If a direct AX insert grew it, that
            // landed; otherwise neither paste nor AX insert put anything in, so
            // it is a real miss and the user must paste by hand.
            return axInsertGrew ? .insertedViaAXRestore : .keepDictationManual
        }
        // AX-blind target. If we managed to post the paste, assume it landed
        // (these apps handle Cmd-V) but keep the dictation as a safety net. If we
        // could not even post it, there is nothing on screen: ask for a manual
        // paste.
        return pastePosted ? .keepDictationPasted : .keepDictationManual
    }
}
