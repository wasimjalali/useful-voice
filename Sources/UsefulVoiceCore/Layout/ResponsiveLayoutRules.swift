public enum ResponsiveLayoutAxis: Equatable, Sendable {
    case horizontal
    case vertical
}

public enum ResponsiveLayoutRules {
    public static func headerAxis(
        availableWidth: Double,
        accessoryWidth: Double,
        minimumTitleWidth: Double,
        spacing: Double
    ) -> ResponsiveLayoutAxis {
        let requiredWidth = accessoryWidth + minimumTitleWidth + spacing
        return availableWidth >= requiredWidth ? .horizontal : .vertical
    }

    public static func rows(
        availableWidth: Double,
        itemWidths: [Double],
        spacing: Double
    ) -> [[Int]] {
        guard !itemWidths.isEmpty else { return [] }

        var rows: [[Int]] = []
        var currentRow: [Int] = []
        var currentWidth = 0.0

        for (index, itemWidth) in itemWidths.enumerated() {
            let proposedWidth = currentRow.isEmpty
                ? itemWidth
                : currentWidth + spacing + itemWidth

            if !currentRow.isEmpty, proposedWidth > availableWidth {
                rows.append(currentRow)
                currentRow = [index]
                currentWidth = itemWidth
            } else {
                currentRow.append(index)
                currentWidth = proposedWidth
            }
        }

        rows.append(currentRow)
        return rows
    }

    public static func remainingHeight(
        totalHeight: Double,
        fixedHeight: Double,
        spacing: Double
    ) -> Double {
        max(0, totalHeight - fixedHeight - spacing)
    }
}
