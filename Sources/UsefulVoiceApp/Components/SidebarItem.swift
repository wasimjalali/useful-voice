import SwiftUI

/// A single navigation row for the light rail. Pure presentation: the parent
/// owns selection and tap handling.
struct SidebarItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected || hovering ? Theme.sunken : Color.clear)
        )
        // The highlight fades in and out instead of snapping, so the rail reads
        // as responsive rather than flickering as the pointer moves down it.
        .animation(BrandMotion.control, value: isSelected)
        .animation(BrandMotion.control, value: hovering)
        .onHover { hovering = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
