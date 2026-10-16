import Foundation

/// How one paste-mode delivery ended.
public enum InsertionOutcome: Equatable, Sendable {
    /// Typed into the focused element with Accessibility, and verified.
    case insertedViaAX
    /// The paste (or the typed text) landed, or went to an app where it can't be proven.
    case pasted
    /// Nothing provably landed; the dictation is on the clipboard to paste by hand.
    case clipboardOnly
    /// A password field had focus: left on the clipboard, nothing typed or pasted.
    case secureFieldCopied
    /// The captured target lost focus before anything was posted: left on the clipboard.
    case targetLost
    /// Typing stopped part way (a password field, focus moved, a key could not be
    /// posted, or it ran out of time). Some of the text went in; all of it is on the
    /// clipboard.
    case partlyTyped
    /// The clipboard write itself failed: the text is nowhere but History.
    case failed
}

/// What Accessibility reports about the focused element: who it is, and how long
/// its text is (in UTF-16 units), when it says.
public struct FocusProbe: Equatable, Sendable {
    public let identifier: String
    public let charCount: Int?

    public init(identifier: String, charCount: Int?) {
        self.identifier = identifier
        self.charCount = charCount
    }
}

/// Proof that a paste actually landed, gathered from the *target* element.
///
/// Pasting is verified against the focused element, never against the shared
/// pasteboard: Universal Clipboard, Handoff and clipboard managers all read the
/// pasteboard too, and their read used to be mistaken for a consumed paste.
public struct PasteProof: Equatable, Sendable {
    /// Identity of the element that was focused before the paste. A different
    /// element afterwards means the character counts are not comparable.
    public let elementIdentifier: String
    /// Character count of that element before the paste, when readable.
    public let beforeCount: Int?
    /// Character count now, when readable.
    public let afterCount: Int?
    /// Length of the text we were trying to insert, in UTF-16 units (what AX
    /// counts), never grapheme clusters.
    public let payloadLength: Int

    public init(elementIdentifier: String, beforeCount: Int?, afterCount: Int?, payloadLength: Int) {
        self.elementIdentifier = elementIdentifier
        self.beforeCount = beforeCount
        self.afterCount = afterCount
        self.payloadLength = payloadLength
    }

    public var growth: Int? {
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
    public var isConsistentWithPayload: Bool { growth == payloadLength }

    /// Whether `after` proves the payload landed in the element probed `before`.
    public static func landed(before: FocusProbe?, after: FocusProbe?, payloadLength: Int) -> Bool {
        guard let before, let after, after.identifier == before.identifier else { return false }
        return PasteProof(elementIdentifier: after.identifier, beforeCount: before.charCount,
                          afterCount: after.charCount, payloadLength: payloadLength)
            .isConsistentWithPayload
    }
}

/// The platform effects one delivery uses. The macOS ones live in the app's
/// `TextInserter`; tests pass fakes and record every call.
public struct InsertionEffects {
    /// Secure Event Input is on (a password field has focus somewhere).
    public var isSecureInput: () -> Bool
    /// Copies the user's clipboard aside. Returns whether it can be put back safely
    /// (a clipboard that could not be copied completely never is).
    public var saveClipboard: () -> Bool
    /// Puts the dictation on the clipboard. False when the write failed.
    public var writeClipboard: (String) -> Bool
    /// After a failed write: puts the saved clipboard back, if it was saved safely.
    public var recoverClipboard: () -> Void
    /// Puts the saved clipboard back, unless something else was copied since.
    public var restoreClipboard: () -> Bool
    /// The captured target still has focus.
    public var onTarget: () -> Bool
    /// Posts Cmd-V. False when it could not be posted at all.
    public var postPaste: () -> Bool
    /// Posts one batch of UTF-16 units as Unicode key events. False when it could not.
    public var postKeys: ([UInt16]) -> Bool
    /// Writes the text into the focused element with Accessibility. Not trusted on its own.
    public var axInsert: (String) -> Bool
    /// Reads the focused element, nil when it can't be read.
    public var probe: () -> FocusProbe?
    /// Runs `work` after a delay, without blocking (the main queue in the app).
    public var schedule: (TimeInterval, @escaping () -> Void) -> Void
    public var now: () -> Date
    /// Called once the delivery has settled, after the completion.
    public var settled: () -> Void

    public init(isSecureInput: @escaping () -> Bool,
                saveClipboard: @escaping () -> Bool,
                writeClipboard: @escaping (String) -> Bool,
                recoverClipboard: @escaping () -> Void,
                restoreClipboard: @escaping () -> Bool,
                onTarget: @escaping () -> Bool,
                postPaste: @escaping () -> Bool,
                postKeys: @escaping ([UInt16]) -> Bool,
                axInsert: @escaping (String) -> Bool,
                probe: @escaping () -> FocusProbe?,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
                now: @escaping () -> Date = { Date() },
                settled: @escaping () -> Void = {}) {
        self.isSecureInput = isSecureInput
        self.saveClipboard = saveClipboard
        self.writeClipboard = writeClipboard
        self.recoverClipboard = recoverClipboard
        self.restoreClipboard = restoreClipboard
        self.onTarget = onTarget
        self.postPaste = postPaste
        self.postKeys = postKeys
        self.axInsert = axInsert
        self.probe = probe
        self.schedule = schedule
        self.now = now
        self.settled = settled
    }
}

/// One paste-mode delivery into the target the controller has already locked on.
public struct InsertionRequest: Equatable, Sendable {
    public let text: String
    /// The target's app id, which picks the method.
    public let appID: String?
    /// The apps the user switched to typing.
    public let typeOutApps: [String]
    /// The user's "restore clipboard after paste" setting.
    public let restorePreviousClipboard: Bool

    public init(text: String, appID: String?, typeOutApps: [String], restorePreviousClipboard: Bool) {
        self.text = text
        self.appID = appID
        self.typeOutApps = typeOutApps
        self.restorePreviousClipboard = restorePreviousClipboard
    }

    /// Paste or type: exactly one, chosen from the per-app list and the text.
    public var method: InsertionMethod {
        InsertionMethod.method(forAppID: appID, typeOutApps: typeOutApps, text: text)
    }
}

public struct InsertionTiming: Equatable, Sendable {
    /// First consumption check. A synthetic Cmd-V is usually consumed within tens of ms.
    public var firstCheck: TimeInterval
    /// Last-chance check for slow consumers (Electron apps under load).
    public var finalCheck: TimeInterval
    /// The gap between two typed batches, so slow targets (terminals over ssh) keep up.
    public var keyGap: TimeInterval
    /// How long typing may take. Past it, typing stops and the rest is on the clipboard.
    public var typingBudget: TimeInterval

    public init(firstCheck: TimeInterval = 0.25, finalCheck: TimeInterval = 0.6,
                keyGap: TimeInterval = 0.002, typingBudget: TimeInterval = 8) {
        self.firstCheck = firstCheck
        self.finalCheck = finalCheck
        self.keyGap = keyGap
        self.typingBudget = typingBudget
    }
}

/// The order of one delivery: the secure-field check, the clipboard safety net, the
/// last look at the target, exactly one way in, the proof, the AX fallback (paste
/// only) and the restore. Mirrors `windows/src/core/delivery/deliveryFlow.ts`.
///
/// The rules every branch serves: nothing is posted into a window that is not the
/// target or into a password field; a typed delivery never pastes and never runs the
/// AX insert (keystrokes still queued would land on top of it); the user's clipboard
/// is put back only after proof, and only when they want it back; whenever the text
/// is not proven in, it is on the clipboard.
public enum InsertionFlow {
    public static func run(_ request: InsertionRequest,
                           timing: InsertionTiming = InsertionTiming(),
                           effects fx: InsertionEffects,
                           completion: @escaping (InsertionOutcome) -> Void) {
        let text = request.text

        // A secure field is active: never type or paste into a password box. Leave
        // the text on the clipboard. Nothing is saved aside: a password manager's
        // clipboard entry must not be copied into our process.
        if fx.isSecureInput() {
            completion(fx.writeClipboard(text) ? .secureFieldCopied : .failed)
            return
        }

        let canRestoreSafely = fx.saveClipboard()
        let probeBefore = fx.probe()

        // Concrete, so a missed insert always leaves something to paste.
        guard fx.writeClipboard(text) else {
            // Nothing was posted, so the dictation survives only in History. The
            // failed write may have cleared the clipboard: put the user's back.
            if canRestoreSafely { fx.recoverClipboard() }
            completion(.failed)
            fx.settled()
            return
        }

        // The last look before anything is posted. The dictation is already on the
        // clipboard, so a lost target loses nothing; it is never pasted elsewhere.
        guard fx.onTarget() else {
            completion(.targetLost)
            fx.settled()
            return
        }

        let method = request.method
        let payloadLength = text.utf16.count
        let restore = { (proven: Bool) -> Void in
            guard DeliveryPolicy.shouldRestoreClipboard(
                proven: proven, canRestoreSafely: canRestoreSafely,
                restorePreviousClipboard: request.restorePreviousClipboard) else { return }
            _ = fx.restoreClipboard()
        }
        let finish = { (outcome: InsertionOutcome) in
            completion(outcome)
            fx.settled()
        }

        // Run when the insert was not confirmed, with the last probe taken after it.
        let runFallback = { (posted: Bool, afterPost: FocusProbe?) in
            // Did the post change the target without matching the payload? Then it
            // landed somewhere we can't measure exactly, and an AX insert on top would
            // put the text in twice. A field that stopped answering counts as changed.
            let targetChanged: Bool = {
                guard posted, let before = probeBefore, before.charCount != nil else { return false }
                guard let after = afterPost else { return true }
                return after.identifier != before.identifier || after.charCount != before.charCount
            }()
            // Only into a field that reports its length and did not change, and never
            // after type-out.
            var axInsertGrew = false
            if method == .paste,
               let before = probeBefore, let beforeCount = before.charCount,
               !targetChanged, !fx.isSecureInput(),
               fx.axInsert(text),
               let after = fx.probe(),
               after.identifier == before.identifier,
               let afterCount = after.charCount,
               afterCount - beforeCount == payloadLength {
                axInsertGrew = true
            }
            let decision = DeliveryPolicy.finalDecision(
                pastePosted: posted, axVisible: probeBefore?.charCount != nil,
                axInsertGrew: axInsertGrew, targetChanged: targetChanged)
            if decision.restoresUserClipboard { restore(true) }
            switch decision {
            case .insertedViaAXRestore: finish(.insertedViaAX)
            case .pastedRestore, .keepDictationPasted: finish(.pasted)
            case .keepDictationManual: finish(.clipboardOnly)
            }
        }

        // After everything was posted: the scheduled proof checks, never blocking.
        let verify = {
            // Typed text arrives one event at a time, so a long dictation needs longer
            // before the field has grown by all of it (capped).
            let allowance = method == .typeOut ? min(1.5, Double(payloadLength) / 1000) : 0
            let first = timing.firstCheck + allowance
            let final = timing.finalCheck + allowance
            fx.schedule(first) {
                if PasteProof.landed(before: probeBefore, after: fx.probe(), payloadLength: payloadLength) {
                    restore(true)
                    finish(.pasted)
                    return
                }
                fx.schedule(final - first) {
                    let after = fx.probe()
                    if PasteProof.landed(before: probeBefore, after: after, payloadLength: payloadLength) {
                        restore(true)
                        finish(.pasted)
                    } else {
                        runFallback(true, after)
                    }
                }
            }
        }

        switch method {
        case .paste:
            if fx.postPaste() { verify() } else { runFallback(false, nil) }
        case .typeOut:
            let batches = TypeOutChunker.chunks(of: text)
            let deadline = fx.now().addingTimeInterval(timing.typingBudget)
            // Stopped before the end: nothing typed is the old outcome, some typed is
            // "partly typed". Either way the whole text is on the clipboard, kept.
            let stop = { (typedAny: Bool, nothingTyped: InsertionOutcome) in
                finish(typedAny ? .partlyTyped : nothingTyped)
            }
            // One batch per step, scheduled on the queue rather than slept on, so the
            // main thread stays free; the password field and the target are checked
            // before every batch.
            func step(_ index: Int) {
                let typedAny = index > 0
                guard fx.now() < deadline else { return stop(typedAny, .clipboardOnly) }
                guard !fx.isSecureInput() else { return stop(typedAny, .secureFieldCopied) }
                if index > 0, !fx.onTarget() { return stop(typedAny, .targetLost) }
                guard fx.postKeys(batches[index]) else {
                    // Nothing went out: the fallback decides (it never AX-inserts after
                    // type-out). Something went out: partly typed.
                    if typedAny { return stop(true, .clipboardOnly) }
                    return runFallback(false, nil)
                }
                if index + 1 < batches.count {
                    fx.schedule(timing.keyGap) { step(index + 1) }
                } else {
                    verify()
                }
            }
            if batches.isEmpty { verify() } else { step(0) }
        }
    }
}
