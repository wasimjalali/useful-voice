import AppKit
import SwiftUI
import UsefulVoiceCore

/// Display-only state for the HUD pill. Richer than DictationState on purpose
/// (recording carries seconds and level), so new display-only cases land here,
/// not in the controller state machines.
enum HUDDisplay: Equatable {
    case recording(seconds: Int, level: Float)
    /// Local transcription emits segments as they decode; `partial` is the
    /// latest one, shown as a live preview instead of the static label.
    case transcribing(partial: String?)
    case delivering
    /// A brief success confirmation shown after a dictation lands.
    case done
    case error(String)
    /// A brief confirmation that the dictation language was switched.
    case language(LanguagePin)
}

/// The floating pill. Ink surface, light mark, matching the dark-theme logo.
/// Every state is one clear line so it reads from across the screen without
/// stealing focus from the app you're dictating into.
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
        .background(Capsule(style: .continuous).fill(Theme.hudSurface))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.hudMark.opacity(0.28), lineWidth: 1))
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
            LandingMark(level: level, size: 22, fill: Theme.hudMark)
            Text(Self.timecode(seconds))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.hudInk)
            KeyHint(label: "esc")
        case .transcribing(let partial):
            // A live preview gets a fixed width and truncates at its head (the
            // newest words stay visible), so the pill does not resize with
            // every partial.
            status(Self.transcribingLabel(partial),
                   fixedWidth: partial == nil ? nil : 260)
        case .delivering:
            status("Inserting")
        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.hudMark)
                Text("Done")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.hudInk)
            }
        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.hudMark)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.hudInk)
                    .lineLimit(2)
            }
        case .language(let pin):
            // A clear, glanceable confirmation of the language you just switched
            // to: a globe and the language name, larger than the working
            // labels so it reads at a glance from across the screen.
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.hudMark)
                Text(PageFormat.languageLabel(pin))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.hudInk)
            }
        }
    }

    /// The transcribing label: the static word, or a quoted preview of the
    /// latest decoded segment trimmed so the pill stays compact.
    private static func transcribingLabel(_ partial: String?) -> String {
        guard let partial else { return "Transcribing" }
        let tail = String(partial.suffix(56)).trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? "Transcribing" : "“\(tail)”"
    }

    /// A working state: a spinner plus a quiet label. The recording state shows
    /// the full waveform, so these brief states stay minimal.
    private func status(_ label: String, fixedWidth: CGFloat? = nil) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(Theme.hudInk)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.hudInk)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(width: fixedWidth, alignment: .leading)
        }
    }

    /// mm:ss, counting up from zero. Tabular digits so the pill never jitters
    /// in width as the seconds tick over.
    static func timecode(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A record dot that breathes while recording. Static under reduced motion.
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
            .fill(Theme.danger)
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
            .foregroundStyle(Theme.hudInk.opacity(0.65))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.hudInk.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Theme.hudInk.opacity(0.16), lineWidth: 1)
            )
    }
}
