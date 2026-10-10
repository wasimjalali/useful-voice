import SwiftUI

/// One rail item: icon over a label, 68 x 54. The selected item gets the lift (surface
/// card with a hairline) and a 2 pt leading ink bar, so selection is never only a tint.
/// Pure presentation: the parent owns selection and tap handling.
struct RailItem: View {
    let title: String
    let systemImage: String
    var isSelected = false
    /// A status glyph keeps its own tone (the status button); nil uses ink.
    var glyphTint: Color?

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                .frame(height: 20)
                .foregroundStyle(glyphTint ?? (isSelected || hovering ? Theme.ink : Theme.inkMuted))
            Text(title)
                .font(.uv(.label, .medium))
                .foregroundStyle(isSelected || hovering ? Theme.ink : Theme.inkMuted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 68, height: 54)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(isSelected ? Theme.surface : hovering ? Theme.sunken : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(Theme.edge, lineWidth: isSelected ? 0.5 : 0)
        )
        .shadow(color: Theme.ink.opacity(isSelected ? 0.06 : 0), radius: 1, y: 1)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.ink)
                .frame(width: 2)
                .padding(.vertical, 14)
                .opacity(isSelected ? 1 : 0)
        }
        // The highlight fades in and out (150 ms) instead of snapping.
        .brandAnimation(BrandMotion.control, value: isSelected)
        .brandAnimation(BrandMotion.control, value: hovering)
        .onHover { hovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
    }
}
