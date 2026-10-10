import AppKit
import SwiftUI
import UsefulVoiceCore

/// Colors the first-run mockups use that Theme has no role for.
enum FRColor {
    // The Deepgram card is dark in both themes, so everything on it is fixed.
    static let darkField = Theme.rgb(0x23, 0x23, 0x23)
    static let darkFieldLine = Theme.rgb(0x3A, 0x3A, 0x3A)
    static let darkRule = Theme.rgb(0x2E, 0x2E, 0x2E)
    static let darkButton = Theme.rgb(0x33, 0x33, 0x33)
    static let quiet = Theme.rgb(0x8C, 0x8C, 0x8C)
    static let cardSurface = Theme.hudSurface
    static let cardInk = Theme.hudInk
    static let cardButtonInk = Theme.rgb(0x17, 0x17, 0x17)
    static let cardFaint = Theme.rgb(0xA3, 0xA3, 0xA3)

    static let rowLine = Theme.dynamic(light: 0xE4E4E4, dark: 0x2A2A2A)
    static let track = Theme.dynamic(light: 0xDCDCDC, dark: 0x333333)
    static let hover = Theme.dynamic(light: 0xE6E6E6, dark: 0x2C2C2C)
    static let meterQuiet = Theme.dynamic(light: 0xD4D4D4, dark: 0x3A3A3A)
    static let toggleOff = Theme.dynamic(light: 0xD4D4D4, dark: 0x3A3A3A)
    static let switchKnob = Theme.dynamic(light: 0xFFFFFF, dark: 0xE0E0E0)
    static let spinnerTrack = Theme.dynamic(light: 0xD9D9D9, dark: 0x3A3A3A)
}

// MARK: - Glyphs

/// The check used for success states, drawn on the mockups' 20-point grid.
struct CheckGlyph: View {
    var size: CGFloat = 18
    var color: Color = Theme.success
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 20
            var path = Path()
            path.move(to: CGPoint(x: 4.5 * scale, y: 10.5 * scale))
            path.addLine(to: CGPoint(x: 8 * scale, y: 14 * scale))
            path.addLine(to: CGPoint(x: 15.5 * scale, y: 6 * scale))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth * scale,
                                              lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The circled exclamation mark used for errors.
struct AlertGlyph: View {
    var size: CGFloat = 18

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 20
            let style = StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round)
            context.stroke(
                Path(ellipseIn: CGRect(x: 2.5 * scale, y: 2.5 * scale,
                                       width: 15 * scale, height: 15 * scale)),
                with: .color(Theme.danger), style: style)
            var bar = Path()
            bar.move(to: CGPoint(x: 10 * scale, y: 6 * scale))
            bar.addLine(to: CGPoint(x: 10 * scale, y: 10.5 * scale))
            bar.move(to: CGPoint(x: 10 * scale, y: 13.5 * scale))
            bar.addLine(to: CGPoint(x: 10 * scale, y: 14 * scale))
            context.stroke(bar, with: .color(Theme.danger), style: style)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct MicGlyph: View {
    var size: CGFloat = 18

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 20
            let style = StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round)
            context.stroke(
                Path(roundedRect: CGRect(x: 7 * scale, y: 2.5 * scale,
                                         width: 6 * scale, height: 10 * scale),
                     cornerRadius: 3 * scale),
                with: .color(Theme.brandInk), style: style)
            var arc = Path()
            arc.addArc(center: CGPoint(x: 10 * scale, y: 9.5 * scale), radius: 6 * scale,
                       startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            arc.move(to: CGPoint(x: 10 * scale, y: 15.5 * scale))
            arc.addLine(to: CGPoint(x: 10 * scale, y: 18 * scale))
            context.stroke(arc, with: .color(Theme.brandInk), style: style)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ExternalArrowGlyph: View {
    var color: Color = Theme.ink

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 12
            var path = Path()
            path.move(to: CGPoint(x: 3.5 * scale, y: 8.5 * scale))
            path.addLine(to: CGPoint(x: 8.5 * scale, y: 3.5 * scale))
            path.move(to: CGPoint(x: 4.5 * scale, y: 3.5 * scale))
            path.addLine(to: CGPoint(x: 8.5 * scale, y: 3.5 * scale))
            path.addLine(to: CGPoint(x: 8.5 * scale, y: 7.5 * scale))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// The waiting spinner: a ring with a dark arc. Under Reduce Motion it is a
/// still dot instead of a turning ring.
struct WaitingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turn = false

    var body: some View {
        Group {
            if reduceMotion {
                Circle().fill(Theme.inkMuted).frame(width: 8, height: 8)
                    .frame(width: 14, height: 14)
            } else {
                Circle()
                    .stroke(FRColor.spinnerTrack, lineWidth: 2)
                    .overlay(Circle().trim(from: 0, to: 0.25).stroke(Theme.ink, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(turn ? 360 : 0))
                    .animation(.linear(duration: 0.8).repeatForever(autoreverses: false),
                               value: turn)
                    .onAppear { turn = true }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The dark waveform tile from the app icon, drawn from bar heights.
struct WaveMark: View {
    let size: CGFloat
    let radius: CGFloat
    let barWidth: CGFloat
    let gap: CGFloat
    let heights: [CGFloat]
    var animated = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var low = false

    var body: some View {
        HStack(spacing: gap) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                    .fill(index == 2 ? FRColor.quiet : Theme.brandInk)
                    .frame(width: barWidth, height: height)
                    .scaleEffect(y: animated && !reduceMotion && low ? 0.5 : 1)
                    .animation(
                        animated && !reduceMotion
                            ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
                                .delay(0.12 * Double(index))
                            : nil,
                        value: low)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onAppear { if animated { low = true } }
        .accessibilityElement()
        .accessibilityLabel("Useful Voice")
    }
}

// MARK: - Buttons and text

/// The solid 44-point button every step ends on.
struct FRPrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.brandInk)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Theme.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
        .clickableCursor(enabled)
    }
}

/// Quiet centered text link (Skip for now, Cancel download).
struct FRTextLink: View {
    let title: String
    var underline = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
                .underline(underline)
        }
        .buttonStyle(.plain)
        .clickableCursor()
    }
}

struct FRBackLink: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("‹ Back")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkMuted)
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .accessibilityLabel("Back")
    }
}

struct FRHeader: View {
    var step: Int?
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let step {
                Text("Step \(step) of 4")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkMuted)
            }
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.56)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FRErrorBanner: View {
    let text: String

    /// VoiceOver speaks the message when the banner appears.
    private static func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text,
                       .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AlertGlyph().padding(.top, 1)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(2.5)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .onAppear { Self.announce(text) }
        .onChange(of: text) { _, next in Self.announce(next) }
    }
}

/// A key cap, as on the Try it and Done steps.
struct FRKeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: FRColor.track, radius: 0, x: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(FRColor.track, lineWidth: 1))
            .fixedSize()
    }
}

struct FRProgressTrack: View {
    let fraction: Double
    var fill: Color = Theme.ink
    var label = "Download progress"

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(FRColor.track)
                Capsule().fill(fill)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((min(1, max(0, fraction)) * 100).rounded())) percent")
    }
}

/// A column centered in the stage that scrolls instead of clipping on a short window.
struct FRColumn<Content: View>: View {
    var width: CGFloat = 480
    var spacing: CGFloat = 18
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: spacing) { content }
                    .frame(width: width)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
