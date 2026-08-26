import AppKit
import SwiftUI
import UsefulVoiceCore

/// Display-only state for the HUD pill. Richer than DictationState on purpose
/// (recording carries seconds and level), so new display-only cases land here,
/// not in the controller state machines.
enum HUDDisplay: Equatable {
    case recording(seconds: Int, level: Float)
    case transcribing
    case delivering
    /// A brief success confirmation shown after a dictation lands.
    case done
    case error(String)
    /// A brief confirmation that the dictation language was switched.
    case language(LanguagePin)
}

/// The floating pill. A premium, glanceable status badge: navy surface, gold
/// mark, cream text. Every state is one clear line so it reads from across the
/// screen without stealing focus from the app you're dictating into.
struct HUDView: View {
    let display: HUDDisplay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        // A fixed floor on the height keeps every state the same pill shape and
        // guarantees a non-zero size even if a child (the live waveform's
        // TimelineView) hasn't resolved its own layout yet.
        .frame(minHeight: 40)
        // The pill is the logo's colorway: deep navy surface, gold mark. A thin
        // gold hairline ties it to the icon; a soft shadow lifts it off the
        // screen so it never blends into whatever is behind it.
        .background(Capsule(style: .continuous).fill(Theme.navy800))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.gold.opacity(0.20), lineWidth: 1))
        .clipShape(Capsule(style: .continuous))
        .shadow(color: Color.black.opacity(0.32), radius: 14, x: 0, y: 7)
        // The hosting panel is sized to this view's fittingSize, so the soft
        // shadow needs real margin around the pill or the window clips it off and
        // the pill looks flat. This transparent inset gives the blur room; the
        // panel background stays clear so only the capsule and its shadow show.
        .padding(22)
        .fixedSize()
        // Cross-fade only on real state changes (listening -> transcribing ->
        // done), keyed on a coarse phase so the per-frame level/seconds updates
        // during recording don't restart the animation every tick.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: phase)
    }

    /// A coarse identity for the current state, so content animates when the
    /// kind of state changes but not as the recording timer/level tick.
    private var phase: Int {
        switch display {
        case .recording: return 0
        case .transcribing: return 1
        case .delivering: return 2
        case .done: return 3
        case .error: return 4
        case .language: return 5
        }
    }

    @ViewBuilder private var content: some View {
        switch display {
        case .recording(let seconds, let level):
            // The hero state. A live record dot, the living Useful Voice waveform, the
            // running time, and a quiet hint that Esc cancels: everything a
            // dictation app like WhisperFlow shows while you speak.
            RecordingDot(reduceMotion: reduceMotion)
            UsefulVoiceWaveBars(style: .live(level: level))
            Text(Self.timecode(seconds))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.cream)
            KeyHint(label: "esc")
        case .transcribing:
            status("Transcribing")
        case .delivering:
            status("Inserting")
        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.gold)
                Text("Done")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.cream)
            }
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.gold)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(2)
            }
        case .language(let pin):
            // A clear, glanceable confirmation of the language you just switched
            // to: a gold globe and the language name, larger than the working
            // labels so it reads at a glance from across the screen.
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.gold)
                Text(PageFormat.languageLabel(pin))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.cream)
            }
        }
    }

    /// A working state: a spinner plus a quiet label. The recording state shows
    /// the full waveform, so these brief states stay minimal. The spinner is
    /// cream, not gold: dark gold on the near-black navy pill was effectively
    /// invisible, so the ring never read as "working". Cream matches the label.
    private func status(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(Theme.cream)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.cream)
        }
    }

    /// mm:ss, counting up from zero. Tabular digits so the pill never jitters
    /// in width as the seconds tick over.
    static func timecode(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A small gold record dot that breathes while recording, so the pill reads as
/// live even at a glance. Static under reduced motion.
private struct RecordingDot: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            dot(opacity: 1)
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // A gentle 0.55...1.0 pulse, ~1.1s period.
                let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.1))
                dot(opacity: pulse)
            }
        }
    }

    private func dot(opacity: Double) -> some View {
        Circle()
            .fill(Theme.gold)
            .frame(width: 8, height: 8)
            .opacity(opacity)
    }
}

/// A quiet keycap, used to show that Esc cancels the recording. Tertiary by
/// design: present for the people who want it, never competing with the mark.
private struct KeyHint: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.cream.opacity(0.65))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.cream.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.cream.opacity(0.16), lineWidth: 1)
            )
    }
}

/// The Useful Voice mark, rendered live: five rounded bars in the logo's
/// 0.4 / 0.7 / 1.0 / 0.7 / 0.4 mountain. In `.live` mode the bars rise with the
/// mic level while always holding the mountain silhouette, so the pill reads as
/// the logo even in silence. `.still` is the resting mark used as a small glyph.
struct UsefulVoiceWaveBars: View {
    enum Style: Equatable { case live(level: Float), still }
    let style: Style
    var barHeight: CGFloat = 22
    var barWidth: CGFloat = 4
    var spacing: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The logo's silhouette.
    private let weights: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]
    /// Shortest a bar ever gets, so the mark never collapses to a flat line.
    private let floorRatio: CGFloat = 0.18
    /// Height held at silence, as a fraction of each bar's full height: keeps the
    /// mountain readable with no sound.
    private let restRatio: CGFloat = 0.6
    /// Mic-level sensitivity. The recorder's level is roughly 0...1 already; this
    /// opens up the usable speaking range.
    private let gain: CGFloat = 11

    var body: some View {
        switch style {
        case .still:
            bars { fraction(at: $0, level: 0, phase: 0, animated: false) }
        case .live(let level):
            if reduceMotion {
                // Reduced motion: follow loudness only, no ripple, gentle ease.
                bars { fraction(at: $0, level: level, phase: 0, animated: false) }
                    .animation(.easeOut(duration: 0.12), value: level)
            } else {
                // A continuous time source so the bars ripple EVERY frame, not
                // only when a new level sample arrives (~10-30Hz). The mic level
                // sets the wave's amplitude; time gives it the flow. This is what
                // makes the mark read as a live waveform instead of a slow pulse.
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate
                    bars { fraction(at: $0, level: level, phase: phase, animated: true) }
                }
            }
        }
    }

    private func bars(_ heightFraction: @escaping (Int) -> CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: barWidth, height: pixels(heightFraction(index)))
            }
        }
        .frame(width: CGFloat(weights.count) * barWidth + CGFloat(weights.count - 1) * spacing,
               height: barHeight, alignment: .center)
    }

    /// Maps a 0...1 fraction of full height to pixels, never below the floor so
    /// the mark never collapses to a flat line.
    private func pixels(_ fraction: CGFloat) -> CGFloat {
        let floor = barHeight * floorRatio
        let span = barHeight - floor
        return floor + span * min(max(fraction, 0), 1)
    }

    /// Height fraction (0...1) for one bar. The bar sits on the logo's resting
    /// mountain, rises with loudness, and ripples with a per-bar phase offset so
    /// the five bars travel as a wave instead of pulsing in lockstep. The ripple
    /// is barely there in silence and grows with the mic level; the wave also
    /// speeds up as you get louder, for an energetic, realistic feel.
    private func fraction(at index: Int, level: Float,
                          phase: Double, animated: Bool) -> CGFloat {
        let norm = min(max(CGFloat(level) * gain, 0), 1)
        let base = weights[index] * (restRatio + (1 - restRatio) * norm)
        guard animated else { return base }
        let speed = 7.0 + 7.0 * Double(norm)          // quiet = calm, loud = lively
        let offset = Double(index) * 0.9              // staggers the bars into a wave
        let ripple = sin(phase * speed + offset)      // -1...1
        let amplitude = 0.05 + 0.25 * norm            // gentle idle, strong on sound
        return base + CGFloat(ripple) * amplitude * weights[index]
    }
}
