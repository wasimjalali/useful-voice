import SwiftUI

/// A single navigation row for the navy sidebar. Pure presentation: the parent
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
        .foregroundStyle(isSelected ? Theme.brandStrong : Theme.white.opacity(0.68))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Theme.surface : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
