import AppKit
import SwiftUI

/// What the menu bar menu's header row shows. Updated by the app: the status on
/// every dictation state change, the timer and level on the recording tick.
@MainActor
final class MenuHeaderModel: ObservableObject {
    enum Status: Equatable {
        case ready
        case recording
        case transcribing
        case inserting
    }

    @Published var status: Status = .ready
    @Published var seconds = 0
    @Published var level: Float = 0
    /// The first line of the last dictation, nil before the first one.
    @Published var lastLine: String?
    @Published var copied = false
    var onCopy: () -> Void = {}
}

/// The one custom row of the menu bar menu (an `NSMenuItem.view`): the mark and
/// the status, then the last dictation with a Copy button. Everything below it is
/// a standard menu item, so keyboard and VoiceOver behave natively. The row has no
/// background of its own, so the menu draws its own material behind it.
struct MenuHeaderView: View {
    @ObservedObject var model: MenuHeaderModel

    static let size = CGSize(width: 260, height: 76)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow
            lastRow
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if model.status == .recording {
                Circle().fill(Theme.danger).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                LandingMark(level: model.level, size: 22, fill: Theme.ink)
            } else {
                LandingTile(size: 22, radius: Radius.xs)
            }
            Text(statusText)
                .font(.uv(.title, .semibold))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            if model.status == .recording {
                Text(HUDView.timecode(model.seconds))
                    .font(.uv(.ui, .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.status == .recording
            ? "Recording, \(HUDView.timecode(model.seconds))" : statusText)
    }

    private var lastRow: some View {
        HStack(spacing: 8) {
            Text(model.lastLine ?? "No dictations yet")
                .font(.uv(.ui))
                .foregroundStyle(Theme.inkMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if model.lastLine != nil {
                Button {
                    model.onCopy()
                } label: {
                    Text(model.copied ? "Copied" : "Copy")
                        .font(.uv(.meta, .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Theme.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy last dictation")
            }
        }
        .frame(height: 28)
    }

    private var statusText: String {
        switch model.status {
        case .ready: return "Ready"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .inserting: return "Inserting"
        }
    }
}

/// Renders the header row offscreen for `UV_MENU_HEADER=idle|recording`, on a
/// plain surface standing in for the menu's material.
@MainActor
enum MenuHeaderSnapshot {
    static func render(_ name: String, appearance: NSAppearance?, to url: URL,
                       completion: @escaping (Bool) -> Void) {
        let model = MenuHeaderModel()
        model.lastLine = "And again, when you run the reviews for this, skip the Opus review completely and just run the Sonnet reviews."
        if name == "recording" {
            model.status = .recording
            model.seconds = 7
            model.level = 0.08
        }
        // Stands in for the menu's own material behind the row.
        let canvas = Theme.dynamic(light: 0xF2F2F2, dark: 0x2B2B2B)
        let view = MenuHeaderView(model: model)
            .background(canvas)
        SnapshotWriter.write(view: AnyView(view), size: MenuHeaderView.size,
                             appearance: appearance, to: url, completion: completion)
    }
}
