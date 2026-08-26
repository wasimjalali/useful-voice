import SwiftUI
import UsefulVoiceCore

struct MicButton: View {
    let state: DictationState
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .strokeBorder(ringColor, lineWidth: state == .recording ? 3 : 1)
                    .frame(width: 126, height: 126)

                Circle()
                    .fill(Theme.brand)
                    .frame(width: 108, height: 108)
                    .shadow(
                        color: Theme.brand.opacity(hovering ? 0.22 : 0.12),
                        radius: hovering ? 18 : 10,
                        y: 8
                    )

                glyph
            }
            .frame(width: 132, height: 132)
            .contentShape(Circle())
        }
        .buttonStyle(PressButtonStyle())
        .onHover { hovering = $0 }
        .clickableCursor()
        .accessibilityLabel(accessibilityLabel)
    }

    private var ringColor: Color {
        switch state {
        case .recording: return Theme.accent
        case .transcribing, .delivering: return Theme.accent.opacity(0.65)
        case .idle, .error: return Theme.line
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .recording:
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.surface)
                .frame(width: 27, height: 27)
        case .transcribing, .delivering:
            ProgressView()
                .controlSize(.regular)
                .tint(Theme.accent)
        case .idle, .error:
            Image(systemName: "mic.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Theme.surface)
        }
    }

    private var accessibilityLabel: String {
        state == .recording ? "Stop dictation" : "Start dictation"
    }
}

private struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
