import SwiftUI
import Combine

/// Global, lightweight action feedback for the main window (copy, delete,
/// send to notes, learn, import). One toast at a time, auto-dismisses.
@MainActor
final class AppToastCenter: ObservableObject {
    enum Kind: Equatable {
        case success
        case info
        case danger
    }

    struct Item: Equatable, Identifiable {
        let id: UUID
        let message: String
        let kind: Kind

        init(id: UUID = UUID(), message: String, kind: Kind) {
            self.id = id
            self.message = message
            self.kind = kind
        }
    }

    @Published private(set) var current: Item?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ message: String, kind: Kind = .success, duration: TimeInterval = 2.4) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        hideWorkItem?.cancel()
        let item = Item(message: trimmed, kind: kind)
        withAnimation(BrandMotion.resolved(BrandMotion.hudEnter)) {
            current = item
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.current?.id == item.id else { return }
            withAnimation(BrandMotion.resolved(BrandMotion.hudExit)) {
                self.current = nil
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss() {
        hideWorkItem?.cancel()
        withAnimation(BrandMotion.resolved(BrandMotion.hudExit)) {
            current = nil
        }
    }
}

struct PremiumToastHost: View {
    @EnvironmentObject private var toasts: AppToastCenter

    var body: some View {
        VStack {
            Spacer()
            if let item = toasts.current {
                PremiumToastBanner(item: item) {
                    toasts.dismiss()
                }
                .transition(.brandRise())
                .padding(.bottom, 22)
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(toasts.current != nil)
        .animation(BrandMotion.resolved(BrandMotion.hudEnter), value: toasts.current?.id)
    }
}

/// The board's toast: an always-dark capsule (hud surface and ink) with a status
/// glyph, the message and a 24 pt close target.
private struct PremiumToastBanner: View {
    let item: AppToastCenter.Item
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.uv(.ui, .semibold))
                .foregroundStyle(tint)

            Text(item.message)
                .font(.uv(.ui, .medium))
                .foregroundStyle(Theme.hudInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.uv(.label, .bold))
                    .foregroundStyle(Theme.hudInk.opacity(0.7))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 38)
        .frame(maxWidth: 420)
        .background(Theme.hudSurface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .themeShadow(.pop)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.message)
    }

    /// The glyph sits on the dark toast in both themes, so it takes the dark-palette
    /// status colors.
    private var tint: Color {
        switch item.kind {
        case .success: return Theme.rgb(0x4C, 0xC3, 0x9B)
        case .info: return Theme.hudInk
        case .danger: return Theme.hudDanger
        }
    }

    private var icon: String {
        switch item.kind {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .danger: return "exclamationmark.triangle.fill"
        }
    }
}
