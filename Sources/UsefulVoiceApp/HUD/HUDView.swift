import AppKit
import SwiftUI
import UsefulVoiceCore

/// Where the HUD is in its enter and exit. Enter rises 8 pt and fades in over
/// 220 ms; exit sinks 6 pt and fades out over 160 ms.
enum HUDPresentation {
    case entering
    case shown
    case exiting
}

/// What the panel's hosting view observes. The panel changes it; the view only reads.
@MainActor
final class HUDModel: ObservableObject {
    @Published var display: HUDDisplay = .delivering
    @Published var presentation: HUDPresentation = .entering
    /// The capsule's current size, reported by the view. The panel uses it to take
    /// clicks over the capsule only.
    var capsuleSize: CGSize = .zero
}

private struct CapsuleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// The root of the panel's hosting view.
struct HUDRoot: View {
    @ObservedObject var model: HUDModel
    let onFix: (DictationFix) -> Void
    let onClose: () -> Void

    var body: some View {
        HUDView(display: model.display, presentation: model.presentation,
                onFix: onFix, onClose: onClose)
            .onPreferenceChange(CapsuleSizeKey.self) { model.capsuleSize = $0 }
    }
}

/// The floating capsule. Ink surface, light mark, in both appearances. Every
/// state is one clear line so it reads from across the screen without stealing
/// focus from the app you are dictating into. The view fills the panel's fixed
/// 400 by 160 pt window and keeps the capsule at the bottom centre, so every
/// morph (cross-fade, width easing, growing into the local bubble) happens inside
/// it and the window itself never resizes.
struct HUDView: View {
    let display: HUDDisplay
    var presentation: HUDPresentation = .shown
    var onFix: (DictationFix) -> Void = { _ in }
    var onClose: () -> Void = {}

    static let windowSize = CGSize(width: 400, height: 160)
    /// Transparent margin around the capsule, so its shadow is not clipped.
    static let shadowPad: CGFloat = 20
    static let capsuleHeight: CGFloat = 40
    static let bubbleWidth: CGFloat = 360

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        container
            .padding(.bottom, Self.shadowPad)
            .frame(width: Self.windowSize.width, height: Self.windowSize.height, alignment: .bottom)
            .opacity(presentation == .shown ? 1 : 0)
            .offset(y: offset)
            .animation(enterExitAnimation, value: presentation)
    }

    private var offset: CGFloat {
        if reduceMotion { return 0 }
        switch presentation {
        case .entering: return 8
        case .shown: return 0
        case .exiting: return 6
        }
    }

    private var enterExitAnimation: Animation? {
        reduceMotion ? nil : (presentation == .exiting ? BrandMotion.hudExit : BrandMotion.hudEnter)
    }

    /// The stable surface. Only the content inside it fades, so the surface never
    /// flickers during a state change while its size eases to the new content.
    private var container: some View {
        ZStack {
            content
                .id(display.phase)
                .transition(.opacity)
        }
        .frame(minHeight: Self.capsuleHeight)
        .background(surface)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: CapsuleSizeKey.self, value: proxy.size)
        })
        .animation(reduceMotion ? nil : BrandMotion.morph, value: display.phase)
        .accessibilityElement(children: display.isPersistent ? .contain : .ignore)
        .accessibilityLabel(display.accessibilityLabel)
    }

    /// The ink surface, its hairline ring and its shadow. The shadow belongs to the
    /// fill alone, so it never doubles up behind the ring. Circular corners: a
    /// continuous-corner stroke at a half-height radius draws a stray vertical
    /// segment past each end of the capsule.
    private var surface: some View {
        let radius = display.isBubble ? Radius.md : Self.capsuleHeight / 2
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        return ZStack {
            shape
                .fill(Theme.hudSurface)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.6 : 0.34), radius: 12, x: 0, y: 8)
            shape
                .strokeBorder(Color.white.opacity(0.14), lineWidth: colorScheme == .dark ? 1 : 0.5)
        }
    }

    // MARK: - States

    @ViewBuilder private var content: some View {
        switch display {
        case .recording(let seconds, let level, let stopsIn):
            row(trailing: 16) {
                RecordingDot(reduceMotion: reduceMotion)
                LandingMark(level: level, size: 22, fill: Theme.hudMark)
                Text(Self.timecode(seconds)).monospacedDigit()
                if let stopsIn { Text("Stops in \(stopsIn) s") }
                KeyCap(label: "esc")
            }
        case .transcribing(let partial, let local):
            if let partial, local {
                bubble(partial: partial)
            } else {
                row(trailing: 16) {
                    HUDSpinner(reduceMotion: reduceMotion)
                    Text(local ? "Transcribing locally" : "Transcribing")
                }
            }
        case .delivering:
            row(trailing: 16) {
                HUDSpinner(reduceMotion: reduceMotion)
                Text("Inserting")
            }
        case .done(let done):
            row(trailing: 16) {
                symbol("checkmark")
                HStack(spacing: 0) {
                    Text(done.label)
                    if let words = done.wordsText {
                        Text(" \u{00B7} \(words)").foregroundStyle(Theme.hudInk.opacity(0.72)).fontWeight(.regular)
                    }
                }
            }
        case .copiedNotPasted:
            row(trailing: 8) {
                symbol("doc.on.clipboard")
                Text("Copied. Press \u{2318}V to paste")
                fixButton(.openAccessibilitySettings)
                closeButton
            }
        case .cancelled:
            row(trailing: 16) {
                symbol("xmark")
                Text("Cancelled")
            }
        case .error(let error):
            row(trailing: 8) {
                symbol(error.symbol)
                // The message is the one flexible item: it truncates so the verb and
                // the close always stay whole inside the 360 pt content width.
                Text(error.message)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.messageWidth(for: error.fix), alignment: .leading)
                if let fix = error.fix { fixButton(fix) }
                closeButton
            }
        case .language(let pin):
            row(trailing: 16) {
                symbol("globe")
                Text(pin.hudName)
            }
        }
    }

    /// One capsule row: 40 pt tall, 16 pt in on the leading side, 10 pt between items.
    private func row<Items: View>(trailing: CGFloat, @ViewBuilder _ items: () -> Items) -> some View {
        HStack(spacing: 10) {
            items()
        }
        .font(.uv(.ui, .medium))
        .foregroundStyle(Theme.hudInk)
        .lineLimit(1)
        .fixedSize()
        .padding(.leading, 16)
        .padding(.trailing, trailing)
        .frame(height: Self.capsuleHeight)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.hudInk)
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    private func fixButton(_ fix: DictationFix) -> some View {
        Button { onFix(fix) } label: {
            Text(fix.hudTitle)
                .font(.uv(.meta, .semibold))
                .foregroundStyle(Theme.hudInk)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule(style: .continuous).fill(Color.white.opacity(0.16)))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(fix.hudTitle)
    }

    /// 24 pt target, the smallest the board allows for a close.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.hudInk)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Dismiss")
    }

    /// The local engine's live words. The capsule grows upward into a 360 pt
    /// bubble: the newest words sit at the end, the head is clipped, and a
    /// right-to-left script is clipped at its logical start.
    private func bubble(partial: String) -> some View {
        let rtl = HUDPartial.isRightToLeft(partial)
        let textWidth = Self.bubbleWidth - 32
        // Measured a little narrower than it is drawn, so SwiftUI and AppKit never
        // disagree about where a line breaks and clip the newest words.
        let text = HUDPartial.tail(partial, width: textWidth - 8, lines: 2)
        let lines = HUDPartial.lineCount(text, width: textWidth - 8)
        return VStack(alignment: .leading, spacing: 8) {
            PartialLabel(text: text, rtl: rtl, width: textWidth)
                .frame(width: textWidth, height: HUDPartial.lineHeight * CGFloat(min(lines, 2)),
                       alignment: rtl ? .trailing : .leading)
            HStack(spacing: 10) {
                HUDSpinner(reduceMotion: reduceMotion)
                Text("Transcribing locally")
                    .font(.uv(.ui, .medium))
                    .foregroundStyle(Theme.hudInk)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: Self.bubbleWidth, alignment: .leading)
    }

    /// The room an error message has: the 360 pt content width less the icon, the
    /// verb pill, the close and the gaps and padding around them.
    static func messageWidth(for fix: DictationFix?) -> CGFloat {
        let fixed: CGFloat = 16 + 16 + 10 + 10 + 24 + 8
        guard let fix else { return bubbleWidth - fixed }
        let label = NSAttributedString(string: fix.hudTitle, attributes: [
            .font: NSFont.systemFont(ofSize: TypeScale.meta.rawValue, weight: .semibold)])
        let pill = ceil(label.size().width) + 22
        return bubbleWidth - fixed - 10 - pill
    }

    /// m:ss, counting up from zero. Tabular digits so the capsule never jitters
    /// in width as the seconds tick over.
    static func timecode(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The live words of the local engine. An AppKit label rather than a SwiftUI
/// `Text`, because `Text` ignores the paragraph direction: a Persian line would be
/// laid out left to right, with the ellipsis at the wrong end. The label is told
/// the base direction, so the logical start is on the right and the newest words
/// stay in view.
private struct PartialLabel: NSViewRepresentable {
    let text: String
    let rtl: Bool
    let width: CGFloat

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
            .foregroundColor: NSColor(srgbRed: 0.98, green: 0.98, blue: 0.98, alpha: 0.7),
            .paragraphStyle: style,
        ])
    }
}

/// A record dot that breathes while recording, 1 down to 0.8 over 1,1 s. Solid
/// under Reduce Motion.
private struct RecordingDot: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            dot(opacity: 1)
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                dot(opacity: 0.9 + 0.1 * cos(t * 2 * .pi / 2.2))
            }
        }
    }

    private func dot(opacity: Double) -> some View {
        Circle()
            .fill(Theme.hudDanger)
            .frame(width: 8, height: 8)
            .opacity(opacity)
            .accessibilityHidden(true)
    }
}

/// A ring with a moving arc. Reduce Motion: a static ring.
private struct HUDSpinner: View {
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Theme.hudInk.opacity(reduceMotion ? 0.7 : 0.25), lineWidth: 2)
            if !reduceMotion {
                TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Theme.hudInk, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees((t / 0.9).truncatingRemainder(dividingBy: 1) * 360))
                }
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// A quiet keycap showing that Esc cancels the recording.
private struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.uv(.label, .semibold))
            .foregroundStyle(Theme.hudInk)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .fill(Color.white.opacity(0.14)))
    }
}
