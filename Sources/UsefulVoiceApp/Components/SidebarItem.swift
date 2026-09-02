import SwiftUI

/// A single navigation row for the light rail. Pure presentation: the parent
/// owns selection and tap handling.
struct SidebarItem: View {
    let title: String
    let systemImage: String
    let isSelected: Bool

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
                .fill(isSelected ? Theme.sunken : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
