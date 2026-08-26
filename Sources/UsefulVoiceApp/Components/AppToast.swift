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
        withAnimation(.easeOut(duration: 0.18)) {
            current = item
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.current?.id == item.id else { return }
            withAnimation(.easeIn(duration: 0.16)) {
                self.current = nil
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func dismiss() {
        hideWorkItem?.cancel()
        withAnimation(.easeIn(duration: 0.16)) {
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
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 22)
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(toasts.current != nil)
        .animation(.easeOut(duration: 0.18), value: toasts.current?.id)
    }
}

private struct PremiumToastBanner: View {
    let item: AppToastCenter.Item
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))

            Text(item.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .help("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .frame(maxWidth: 420)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .shadow(color: Theme.brand.opacity(0.10), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.message)
    }

    private var tint: Color {
        switch item.kind {
        case .success: return Theme.success
        case .info: return Theme.brand
        case .danger: return Theme.danger
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
