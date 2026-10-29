import AppKit
import SwiftUI
import UsefulVoiceCore

/// What the panel's hosting view observes. The panel changes it; the view only reads.
@MainActor
final class HUDModel: ObservableObject {
    @Published var display: HUDDisplay = .delivering
    @Published var placement: HUDPlacement = .bottom
    @Published var palette: HUDPalette = .standard
    @Published var timeline = HUDTimeline.settled
    /// The smoothed mic level (0...1) the aura follows.
    @Published var level: Double = 0
    /// Bumped each time a recording starts, so the waveform starts empty for every recording.
    @Published var recordingID = 0
    /// The bubble's (or the done chip's) frame in the window, top-left origin. The
    /// panel uses it to take clicks over the bubble only and to anchor the picker.
    var bubbleFrame: CGRect = .zero {
        didSet { if bubbleFrame != oldValue { bubbleFrameChanged?() } }
    }
    /// The panel re-checks click-through when the bubble moves under a still pointer.
    var bubbleFrameChanged: (() -> Void)?
}

private struct BubbleFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The root of the panel's hosting view.
struct HUDRoot: View {
    @ObservedObject var model: HUDModel
    let onFix: (DictationFix) -> Void
    let onClose: () -> Void

    var body: some View {
        HUDView(display: model.display, placement: model.placement, palette: model.palette,
                timeline: model.timeline, level: model.level, recordingID: model.recordingID,
                onFix: onFix, onClose: onClose)
            .coordinateSpace(name: HUDView.space)
            .onPreferenceChange(BubbleFrameKey.self) { model.bubbleFrame = $0 }
    }
}

/// The floating pill. It sits beside the text cursor of the app you are dictating
/// into, or at the bottom centre when that app does not report its cursor. Every
/// state is one short line in a 30 pt bubble, so it reads at a glance without
/// covering what you are writing. The view fills the panel's fixed 400 by 160 pt
/// window; the bubble sits at its bottom centre, or vertically centred against its
/// left edge (right edge when flipped), so every morph happens inside it and the
/// window never resizes during a state.
///
/// Every frame is drawn from `timeline` and the clock (`HUDTimeline`), so any
/// moment of the motion can be rendered on its own (`clock`).
struct HUDView: View {
    let display: HUDDisplay
    var placement: HUDPlacement = .bottom
    var palette: HUDPalette = .standard
    /// Nil: a still frame of `display` with nothing in motion.
    var timeline: HUDTimeline? = nil
    /// The smoothed mic level, 0...1.
    var level: Double = 0
    var recordingID = 0
    /// A fixed moment to draw, for snapshot frames. Nil: the live clock.
    var clock: Date? = nil
    var onFix: (DictationFix) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// Snapshot only: a ready-made waveform history for the recording state.
    var waveformFixture: [Double]? = nil

    static let windowSize = CGSize(width: 400, height: 160)
    /// Transparent margin around the bubble, for its shadow, tail and halo.
    static let shadowPad: CGFloat = 20
    static let bubbleHeight: CGFloat = 30
    static let partialWidth: CGFloat = 320
    /// From the text cursor to the bubble's near edge, and to the done chip's.
    static let caretGap: CGFloat = 14
    static let chipGap: CGFloat = 8
    /// Room the recording and transcribing bubble needs beside the cursor before it
    /// flips to the other side. Flipping covers the words before the cursor, so it
    /// happens only when the bubble would otherwise run off the screen.
    static let flipRoom: CGFloat = 170
    /// Room the done chip needs beside the cursor.
    static let chipRoom: CGFloat = 140
    /// The widest one-line bubble (an error with its verb and close).
    static let maxBubbleWidth: CGFloat = 340
    static let space = "hud"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let clock {
                scene(at: clock, still: false, timeline: timeline ?? .settled)
            } else if let timeline, !reduceMotion {
                // Runs at display rate while something moves, and pauses once the
                // HUD has settled on a state with no loop (the panel nudges the view then).
                TimelineView(.animation(minimumInterval: nil,
                                        paused: HUDFrame.isSettled(display, placement, timeline, at: Date()))) { context in
                    scene(at: context.date, still: false, timeline: timeline)
                }
            } else if let timeline {
                // Reduce Motion: the end of every change, at once.
                scene(at: .distantFuture, still: true, timeline: timeline)
            } else {
                scene(at: .distantFuture, still: true, timeline: .settled)
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .accessibilityElement(children: display.isPersistent ? .contain : .ignore)
        .accessibilityLabel(display.accessibilityLabel)
    }

    // MARK: - One frame

    private func scene(at now: Date, still: Bool, timeline: HUDTimeline) -> some View {
        let frame = HUDFrame(display: display, placement: placement, timeline: timeline, now: now, still: still)
        return ZStack(alignment: frame.alignment) {
            if frame.bubbleOpacity > 0.001 { bubble(frame) }
            if frame.chipOpacity > 0.001 { chip(frame) }
        }
        .padding(frame.insets)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height, alignment: frame.alignment)
    }

    private func bubble(_ f: HUDFrame) -> some View {
        let shape = RoundedRectangle(cornerRadius: f.radius, style: .circular)
        return ZStack(alignment: f.rowAlignment) {
            if let previous = f.previous {
                row(previous, f).opacity(f.previousOpacity)
            }
            row(f.content, f).opacity(f.contentOpacity)
        }
        .frame(width: f.size.width, height: f.size.height, alignment: f.rowAlignment)
        .clipShape(shape)
        .background {
            shape.fill(palette.surface)
                .shadow(color: palette.contactShadow, radius: 1, x: 0, y: 0.5)
                .shadow(color: palette.shadow, radius: palette.shadowRadius, x: 0, y: palette.shadowY)
        }
        .overlay { shape.strokeBorder(palette.edge, lineWidth: palette.edgeWidth) }
        .background(alignment: placement.isFlipped ? .trailing : .leading) {
            if placement.isCaret { tail.offset(x: placement.isFlipped ? 4.5 : -4.5) }
        }
        .background { halo(f, shape: f.radius) }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: BubbleFrameKey.self, value: proxy.frame(in: .named(Self.space)))
        })
        .scaleEffect(f.bubbleScale, anchor: f.anchor)
        .offset(x: f.offset.width, y: f.offset.height)
        .opacity(f.bubbleOpacity)
    }

    /// The point on the bubble's near edge, at the cursor.
    private var tail: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .strokeBorder(palette.edge, lineWidth: palette.edgeWidth))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(45))
    }

    /// The two rings that bloom out of the bubble as a recording starts, and the
    /// aura that breathes with the voice while it records.
    @ViewBuilder
    private func halo(_ f: HUDFrame, shape radius: CGFloat) -> some View {
        ZStack {
            ForEach(Array(f.bloom.enumerated()), id: \.offset) { _, ring in
                RoundedRectangle(cornerRadius: radius + ring.outset, style: .circular)
                    .stroke(palette.halo, lineWidth: 1.5)
                    .frame(width: f.size.width + 2 * ring.outset, height: f.size.height + 2 * ring.outset)
                    .opacity(ring.opacity)
            }
            if f.aura > 0.001 {
                // A soft glow, not a ring: it swells and brightens with the voice.
                let lv = level
                let outset = 1 + 3 * lv
                RoundedRectangle(cornerRadius: radius + outset, style: .circular)
                    .fill(palette.halo)
                    .frame(width: f.size.width + 2 * outset, height: f.size.height + 2 * outset)
                    .blur(radius: 5 + 5 * lv)
                    .opacity((0.18 + 0.37 * lv) * f.aura)
            }
        }
        .allowsHitTesting(false)
    }

    /// Beside the new text cursor once the words have landed.
    private func chip(_ f: HUDFrame) -> some View {
        var line = ""
        if case .done(let done) = display { line = done.chipText }
        return HStack(spacing: 5) {
            HUDCheck(progress: f.chipCheck, color: palette.ok, size: 14)
            Text(line)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(palette.ink)
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .frame(height: 22)
        .background {
            Capsule(style: .circular).fill(palette.surface)
                .shadow(color: palette.contactShadow, radius: 1, x: 0, y: 0.5)
                .shadow(color: palette.shadow.opacity(0.8), radius: 6, x: 0, y: 3)
        }
        .overlay { Capsule(style: .circular).strokeBorder(palette.edge, lineWidth: palette.edgeWidth) }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: BubbleFrameKey.self, value: proxy.frame(in: .named(Self.space)))
        })
        .scaleEffect(f.chipScale, anchor: placement.isFlipped ? .trailing : .leading)
        .opacity(f.chipOpacity)
    }

    private func row(_ shown: HUDDisplay, _ f: HUDFrame) -> some View {
        HUDRow(display: shown, placement: placement, palette: palette, time: f.time, animated: !f.still,
               check: f.check, recordingID: recordingID, waveformFixture: waveformFixture,
               onFix: onFix, onClose: onClose)
    }

    /// m:ss, counting up from zero. Tabular digits so the bubble never jitters in
    /// width as the seconds tick over.
    static func timecode(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Every value one frame needs, worked out from the timeline and the clock.
@MainActor
private struct HUDFrame {
    /// Nothing moves any more: no loop (waveform, dots, shimmer) on screen, and the
    /// last change (entrance, state change, chip, exit) is over.
    static func isSettled(_ display: HUDDisplay, _ placement: HUDPlacement, _ tl: HUDTimeline, at now: Date) -> Bool {
        switch display {
        case .recording, .transcribing: return false
        case .delivering where !placement.isCaret: return false
        default: break
        }
        let last = [tl.shownAt, tl.bubbleAt, tl.phaseAt, tl.foldAt, tl.chipAt, tl.exitAt, tl.recordingEndedAt]
            .compactMap { $0 }.filter { $0 != .distantPast }.max() ?? .distantPast
        return now > last.addingTimeInterval(HUDTiming.settle)
    }

    let content: HUDDisplay
    let previous: HUDDisplay?
    let size: CGSize
    let radius: CGFloat
    let previousOpacity: Double
    let contentOpacity: Double
    let bubbleOpacity: Double
    let bubbleScale: CGFloat
    let anchor: UnitPoint
    let offset: CGSize
    let check: Double
    let chipOpacity: Double
    let chipScale: CGFloat
    let chipCheck: Double
    let bloom: [(outset: CGFloat, opacity: Double)]
    let aura: Double
    let alignment: Alignment
    let rowAlignment: Alignment
    let insets: EdgeInsets
    /// Seconds on a steady clock, for the loops (dots, shimmer, breathing dot).
    let time: Double
    let still: Bool

    init(display: HUDDisplay, placement: HUDPlacement, timeline tl: HUDTimeline, now: Date, still: Bool) {
        self.still = still
        time = now.timeIntervalSinceReferenceDate
        func since(_ date: Date?) -> Double { date.map { now.timeIntervalSince($0) } ?? .infinity }
        let caret = placement.isCaret
        let flipped = placement.isFlipped

        // Caret placement folds the bubble into the cursor while the text lands; it
        // keeps showing the row it had.
        let folding = caret && display.foldsIntoCaret
        let fold: Double
        if !folding {
            fold = 0
        } else if still {
            // Without motion the bubble stays until the done chip takes over.
            fold = display.isDone ? 1 : 0
        } else {
            fold = tl.foldAt == nil ? 1 : HUDEase.inOut(HUDEase.progress(since(tl.foldAt), over: HUDTiming.fold))
        }
        content = folding ? (tl.held ?? display) : display

        // State change: out first, then in; the size eases over the whole change.
        let change = since(tl.phaseAt)
        if let old = tl.previous, !folding, change < HUDTiming.morph {
            previous = old
            previousOpacity = 1 - HUDEase.in(HUDEase.progress(change, over: HUDTiming.morphOut))
            contentOpacity = HUDEase.out(HUDEase.progress(change - HUDTiming.morphOut,
                                                          over: HUDTiming.morph - HUDTiming.morphOut))
            let p = HUDEase.out(HUDEase.progress(change, over: HUDTiming.morph))
            let from = HUDLayout.size(of: old, placement: placement)
            let to = HUDLayout.size(of: content, placement: placement)
            size = CGSize(width: from.width + (to.width - from.width) * p,
                          height: from.height + (to.height - from.height) * p)
        } else {
            previous = nil
            previousOpacity = 0
            contentOpacity = 1
            size = HUDLayout.size(of: content, placement: placement)
        }
        radius = content.isBubble ? 12 : min(size.height / 2, HUDView.bubbleHeight / 2)

        // Enter, from the cursor or rising from below; exit, ease-in.
        let enter = HUDEase.out(HUDEase.progress(since(tl.bubbleAt), over: HUDTiming.enter))
        let exit = tl.exitAt == nil ? 0 : HUDEase.in(HUDEase.progress(since(tl.exitAt), over: HUDTiming.exit))
        let tailX: CGFloat = 6.4 / max(size.width, 1)
        if caret {
            anchor = UnitPoint(x: flipped ? 1 + tailX : -tailX, y: 0.5)
            bubbleScale = (0.3 + 0.7 * enter) * (1 - 0.8 * fold) * (1 - 0.1 * exit)
            offset = CGSize(width: (flipped ? 4 : -4) * (1 - enter), height: 0)
        } else {
            anchor = .center
            bubbleScale = (0.6 + 0.4 * enter) * (1 - 0.04 * exit)
            offset = CGSize(width: 0, height: 6 * (1 - enter) + 6 * exit)
        }
        bubbleOpacity = enter * (1 - fold) * (1 - exit)

        // The check in the bottom placement's done row draws after the row arrives.
        check = still ? 1 : HUDEase.out(HUDEase.progress(change - HUDTiming.bottomCheckDelay, over: 0.3))

        // The done chip beside the new cursor.
        if caret, case .done = display, let chipAt = tl.chipAt {
            let c = HUDEase.out(HUDEase.progress(since(chipAt), over: HUDTiming.chipIn))
            chipOpacity = c * (1 - exit)
            chipScale = 0.7 + 0.3 * c
            chipCheck = still ? 1 : HUDEase.out(HUDEase.progress(since(chipAt) - HUDTiming.chipCheckDelay,
                                                                   over: HUDTiming.checkDraw))
        } else {
            chipOpacity = 0
            chipScale = 1
            chipCheck = 0
        }

        // Halo: two rings bloom out as the recording starts; the aura follows the voice.
        var rings: [(outset: CGFloat, opacity: Double)] = []
        if !still, let bloomAt = tl.bloomAt {
            for i in 0..<2 {
                let t = since(bloomAt) - Double(i) * HUDTiming.bloomGap
                guard t >= 0, t <= HUDTiming.bloomRing else { continue }
                let e = HUDEase.out(t / HUDTiming.bloomRing)
                rings.append((outset: 1 + 11 * CGFloat(e), opacity: 0.55 * (1 - e)))
            }
        }
        bloom = rings
        if still {
            aura = 0
        } else if display.isRecording {
            aura = enter
        } else {
            aura = 1 - HUDEase.progress(since(tl.recordingEndedAt), over: HUDTiming.auraFade)
        }

        let pad = HUDView.shadowPad
        if caret {
            alignment = flipped ? .trailing : .leading
            rowAlignment = flipped ? .trailing : .leading
            insets = EdgeInsets(top: 0, leading: flipped ? 0 : pad, bottom: 0, trailing: flipped ? pad : 0)
        } else {
            alignment = .bottom
            rowAlignment = .center
            insets = EdgeInsets(top: 0, leading: 0, bottom: pad, trailing: 0)
        }
    }
}

/// Natural sizes of each state's row, measured once per layout and cached, so a
/// state change can ease between two known sizes on any frame.
@MainActor
enum HUDLayout {
    private static var cache: [String: CGSize] = [:]

    static func size(of display: HUDDisplay, placement: HUDPlacement) -> CGSize {
        if case .transcribing(let partial?, true) = display {
            return CGSize(width: HUDView.partialWidth,
                          height: 10 + HUDPartial.lineHeight * CGFloat(self.partial(partial).lines) + 6 + 16 + 10)
        }
        let key = "\(placement.isCaret)|\(layoutKey(display))"
        if let known = cache[key] { return known }
        let row = HUDRow(display: display, placement: placement, palette: .standard, time: 0, animated: false,
                         check: 1, recordingID: 0, waveformFixture: [0], onFix: { _ in }, onClose: {})
        let hosting = NSHostingView(rootView: row)
        let measured = hosting.fittingSize
        let size = CGSize(width: ceil(measured.width), height: max(HUDView.bubbleHeight, ceil(measured.height)))
        if cache.count > 64 { cache.removeAll() }
        cache[key] = size
        return size
    }

    static let textWidth = HUDView.partialWidth - 24

    private static var lastPartial: (input: String, text: String, lines: Int)?

    /// The live words' visible ending and its line count, worked out once per new
    /// partial rather than on every frame.
    static func partial(_ input: String) -> (text: String, lines: Int) {
        if let last = lastPartial, last.input == input { return (last.text, last.lines) }
        let text = HUDPartial.tail(input, width: textWidth - 8, lines: 2)
        let lines = min(HUDPartial.lineCount(text, width: textWidth - 8), 2)
        lastPartial = (input, text, lines)
        return (text, lines)
    }

    /// Measures the rows every dictation shows, ahead of the first one.
    static func warm() {
        let rows: [HUDDisplay] = [.recording(seconds: 0, level: 0, stopsIn: nil),
                                  .transcribing(partial: nil, local: false), .delivering,
                                  .done(.inserted(words: 10))]
        for placement in [HUDPlacement.bottom, .caret(flipped: false)] {
            for row in rows { _ = size(of: row, placement: placement) }
        }
    }

    /// What decides a row's size: the recording's timer only by its digit count.
    private static func layoutKey(_ display: HUDDisplay) -> String {
        switch display {
        case .recording(let seconds, _, let stopsIn):
            return "rec|\(HUDView.timecode(seconds).count)|\(stopsIn.map { "\($0)" } ?? "")"
        default:
            return String(describing: display)
        }
    }
}

/// One state's line inside the bubble.
struct HUDRow: View {
    let display: HUDDisplay
    let placement: HUDPlacement
    let palette: HUDPalette
    let time: Double
    let animated: Bool
    /// How far the done check has drawn.
    let check: Double
    let recordingID: Int
    let waveformFixture: [Double]?
    let onFix: (DictationFix) -> Void
    let onClose: () -> Void

    var body: some View {
        switch display {
        case .recording(let seconds, let level, let stopsIn):
            line {
                HUDRecordDot(time: time, color: palette.rec, animated: animated)
                HUDWaveform(level: level, color: palette.mark, fixture: waveformFixture).id(recordingID)
                Text(HUDView.timecode(seconds)).monospacedDigit()
                if let stopsIn { Text("Stops in \(stopsIn) s").foregroundStyle(palette.dim) }
                if !placement.isCaret { keycap("esc") }
            }
        case .transcribing(let partial, let local):
            if let partial, local {
                partialBubble(partial)
            } else {
                line {
                    HUDDotsMark(time: time, color: palette.dots, animated: animated)
                    HUDShimmerLabel(text: local ? "Transcribing locally" : "Transcribing", ink: palette.ink,
                                    time: time, animated: animated)
                }
            }
        case .delivering:
            line {
                HUDDotsMark(time: time, color: palette.dots, animated: animated)
                Text("Inserting")
            }
        case .done(let done):
            line {
                HUDCheck(progress: check, color: palette.ok, size: 14)
                HStack(spacing: 0) {
                    Text(done.label)
                    if let words = done.wordsText {
                        Text(" \u{00B7} \(words)").foregroundStyle(palette.dim).fontWeight(.regular)
                    }
                }
            }
        case .copiedNotPasted(let fix):
            line(trailing: 6) {
                symbol("doc.on.clipboard")
                Text("Copied. Press \u{2318}V to paste")
                if let fix { fixButton(fix) }
                closeButton
            }
        case .cancelled:
            line {
                symbol("xmark")
                Text("Cancelled")
            }
        case .error(let error):
            line(trailing: 6) {
                symbol(error.symbol)
                Text(error.message)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.messageWidth(for: error.fix), alignment: .leading)
                if let fix = error.fix { fixButton(fix) }
                closeButton
            }
        case .language(let pin):
            line {
                symbol("globe")
                Text(pin.hudName)
            }
        }
    }

    /// One bubble line: 30 pt tall, 12 pt in on the leading side, 8 pt between items.
    private func line<Items: View>(trailing: CGFloat = 12, @ViewBuilder _ items: () -> Items) -> some View {
        HStack(spacing: 8) { items() }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 12)
            .padding(.trailing, trailing)
            .frame(height: HUDView.bubbleHeight)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.ink)
            .frame(width: 14)
            .accessibilityHidden(true)
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.chip))
    }

    private func fixButton(_ fix: DictationFix) -> some View {
        Button { onFix(fix) } label: {
            Text(fix.hudTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule(style: .continuous).fill(palette.chip))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .clickableCursor()
        .accessibilityLabel(fix.hudTitle)
    }

    /// 20 pt target inside the 30 pt bubble.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(palette.ink)
                .frame(width: 20, height: 20)
                .background(Circle().fill(palette.chip))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .clickableCursor()
        .accessibilityLabel("Dismiss")
    }

    /// The local engine's live words above a working line. The newest words sit at
    /// the end, the head is clipped, and a right-to-left script is clipped at its
    /// logical start.
    private func partialBubble(_ partial: String) -> some View {
        let rtl = HUDPartial.isRightToLeft(partial)
        let width = HUDLayout.textWidth
        let (text, lines) = HUDLayout.partial(partial)
        return VStack(alignment: .leading, spacing: 6) {
            PartialLabel(text: text, rtl: rtl, width: width, color: NSColor(palette.ink).withAlphaComponent(0.72))
                .frame(width: width, height: HUDPartial.lineHeight * CGFloat(lines),
                       alignment: rtl ? .trailing : .leading)
            HStack(spacing: 8) {
                HUDDotsMark(time: time, color: palette.dots, animated: animated)
                HUDShimmerLabel(text: "Transcribing locally", ink: palette.ink, time: time, animated: animated)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(height: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: HUDView.partialWidth, alignment: .leading)
    }

    /// The room an error message has: the bubble's widest line less the icon, the
    /// verb pill, the close and the gaps and padding around them.
    static func messageWidth(for fix: DictationFix?) -> CGFloat {
        let fixed: CGFloat = 12 + 14 + 8 + 8 + 20 + 6
        guard let fix else { return HUDView.maxBubbleWidth - fixed }
        let label = NSAttributedString(string: fix.hudTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)])
        let pill = ceil(label.size().width) + 18
        return HUDView.maxBubbleWidth - fixed - 8 - pill
    }
}

/// The local engine's live words. An AppKit label rather than a SwiftUI `Text`,
/// because `Text` ignores the paragraph direction: a Persian line would be laid out
/// left to right, with the ellipsis at the wrong end. The label is told the base
/// direction, so the logical start is on the right and the newest words stay in view.
private struct PartialLabel: NSViewRepresentable {
    let text: String
    let rtl: Bool
    let width: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.maximumNumberOfLines = 2
        field.isSelectable = false
        field.drawsBackground = false
        field.preferredMaxLayoutWidth = width
        // Wrap to the width SwiftUI gives it; do not ask for the width of the
        // unwrapped line.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityElement(false)
        return field
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: width, height: HUDPartial.lineHeight * CGFloat(
            min(HUDPartial.lineCount(text, width: width - 8), 2)))
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        style.alignment = rtl ? .right : .left
        style.minimumLineHeight = HUDPartial.lineHeight
        style.maximumLineHeight = HUDPartial.lineHeight
        style.lineBreakMode = .byWordWrapping
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: HUDPartial.font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }
}
