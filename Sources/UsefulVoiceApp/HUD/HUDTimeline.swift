import Foundation

/// Where the HUD sits for one appearance.
enum HUDPlacement: Equatable {
    /// Bottom centre of the display, as before, or where the person dragged it.
    case bottom
    /// Beside the text cursor of the app in front. `flipped` puts the bubble on the
    /// cursor's left, for a cursor near the right edge of the screen.
    case caret(flipped: Bool)

    var isCaret: Bool {
        if case .caret = self { return true }
        return false
    }

    var isFlipped: Bool {
        if case .caret(let flipped) = self { return flipped }
        return false
    }
}

/// Durations of the HUD's motion, in seconds. One easing for entrances and
/// changes (`HUDEase.out`), its ease-in half for exits and the fold.
enum HUDTiming {
    static let enter = 0.24
    static let morph = 0.22
    /// The outgoing half of a state change; the new row fades in after it.
    static let morphOut = 0.09
    /// The bubble folding into the text cursor once the text is on its way.
    static let fold = 0.22
    static let chipIn = 0.24
    static let chipCheckDelay = 0.12
    static let checkDraw = 0.28
    static let bottomCheckDelay = 0.11
    static let exit = 0.18
    static let bloomRing = 0.7
    static let bloomGap = 0.16
    static let auraFade = 0.2
    /// One turn of the working dots, and one sweep of the label's shimmer.
    static let dotsPeriod = 1.15
    static let shimmerPeriod = 1.5
}

/// `cubic-bezier(0.22, 1, 0.36, 1)` and `cubic-bezier(0.4, 0, 1, 1)`, evaluated for a
/// progress in 0...1, so a frame can be drawn for any moment.
enum HUDEase {
    static func out(_ x: Double) -> Double { bezier(x, 0.22, 1, 0.36, 1) }
    static func `in`(_ x: Double) -> Double { bezier(x, 0.4, 0, 1, 1) }
    static func inOut(_ x: Double) -> Double { bezier(x, 0.65, 0, 0.35, 1) }

    static func progress(_ elapsed: Double, over duration: Double) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(elapsed / duration, 0), 1)
    }

    private static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var low = 0.0, high = 1.0, u = x
        for _ in 0..<18 {
            u = (low + high) / 2
            let cx = 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u
            if cx < x { low = u } else { high = u }
        }
        return 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u
    }
}

/// When each part of the HUD's motion began. The view draws every frame from these
/// and the clock, so a frame for any moment can be rendered (and checked) on its own.
struct HUDTimeline: Equatable {
    /// The HUD came on screen.
    var shownAt: Date
    /// The bubble last entered: on show, or again after it folded into the cursor.
    var bubbleAt: Date
    /// The current state's row started fading in.
    var phaseAt: Date
    /// The row being replaced, while the state change runs.
    var previous: HUDDisplay?
    /// Caret placement: the bubble began folding into the cursor.
    var foldAt: Date?
    /// What the bubble keeps showing while it folds.
    var held: HUDDisplay?
    /// Caret placement: the done chip's spot is known and it may enter.
    var chipAt: Date?
    var recordingEndedAt: Date?
    /// The two halo rings start here (recording entries only).
    var bloomAt: Date?
    var exitAt: Date?

    static func entering(_ display: HUDDisplay, at now: Date) -> HUDTimeline {
        HUDTimeline(shownAt: now, bubbleAt: now, phaseAt: now, previous: nil, foldAt: nil, held: nil, chipAt: nil,
                    recordingEndedAt: nil, bloomAt: display.isRecording ? now : nil, exitAt: nil)
    }

    /// Before the first frame is on screen: everything waits at its starting point.
    static func waiting(_ display: HUDDisplay) -> HUDTimeline { entering(display, at: .distantFuture) }

    /// The entrance starts now, once the window is up, unless a change already moved on.
    mutating func start(at now: Date) {
        guard shownAt == .distantFuture else { return }
        shownAt = now
        bubbleAt = now
        if phaseAt == .distantFuture { phaseAt = now }
        if bloomAt != nil { bloomAt = now }
    }

    /// A frame with nothing in motion: snapshots of a still state, Reduce Motion.
    static let settled = HUDTimeline(shownAt: .distantPast, bubbleAt: .distantPast, phaseAt: .distantPast,
                                     previous: nil, foldAt: nil, held: nil, chipAt: .distantPast,
                                     recordingEndedAt: nil, bloomAt: nil, exitAt: nil)

    /// `old` was replaced by `new` at `now` within the same appearance.
    mutating func advance(from old: HUDDisplay, to new: HUDDisplay, placement: HUDPlacement, at now: Date) {
        if old.isRecording, !new.isRecording, recordingEndedAt == nil { recordingEndedAt = now }
        guard old.phase != new.phase else { return }
        if placement.isCaret, new.foldsIntoCaret {
            if foldAt == nil {
                foldAt = now
                held = old
            }
            return
        }
        if foldAt != nil {
            // A state that needs the bubble again (copied, an error): it comes back
            // out of the cursor the way it first entered.
            foldAt = nil
            held = nil
            chipAt = nil
            bubbleAt = now
            phaseAt = now
            previous = nil
            return
        }
        previous = old
        phaseAt = now
    }
}

extension HUDDisplay {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// In caret placement these states fold the bubble into the cursor: the text is
    /// on its way to it, and the done chip follows beside the new cursor position.
    var foldsIntoCaret: Bool {
        switch self {
        case .delivering, .done: return true
        default: return false
        }
    }
}
