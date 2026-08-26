import AppKit
import SwiftUI
import UsefulVoiceCore

private struct ClickableCursorModifier: ViewModifier {
    let enabled: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard enabled, isEnabled else {
                    popIfNeeded()
                    return
                }
                if inside, !cursorPushed {
                    NSCursor.pointingHand.push()
                    cursorPushed = true
                } else if !inside {
                    popIfNeeded()
                }
            }
            .onDisappear {
                popIfNeeded()
            }
    }

    private func popIfNeeded() {
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

extension View {
    func clickableCursor(_ enabled: Bool = true) -> some View {
        modifier(ClickableCursorModifier(enabled: enabled))
    }

    func premiumInputChrome() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, lineWidth: 1))
    }
}

struct PremiumStatusBadge: View {
    let icon: String?
    let text: String
    let tint: Color

    init(icon: String? = nil, text: String, tint: Color) {
        self.icon = icon
        self.text = text
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.08)))
    }
}

struct PremiumIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PremiumIconButtonBody(configuration: configuration)
    }
}

private struct PremiumIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.navy)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.navy.opacity(hovering ? 0.10 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Theme.navy.opacity(hovering ? 0.35 : 0.16), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onHover { hovering = $0 }
            .clickableCursor()
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct PremiumSearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(focused ? Theme.gold : Theme.charcoal.opacity(0.45))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.charcoal.opacity(0.35))
                }
                .buttonStyle(.plain)
                .clickableCursor()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Theme.accent : Theme.line,
                              lineWidth: 1)
        )
        .shadow(color: focused ? Theme.accent.opacity(0.12) : .clear, radius: 0, x: 0, y: 0)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

struct BrandedMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    private var selectedLabel: String {
        options.first { $0.value == selection }?.label ?? title
    }

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(selectedLabel)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.brand.opacity(0.55))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.brand.opacity(0.22), lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(selectedLabel)
        .clickableCursor()
    }
}

/// On-brand overflow / actions menu (replaces bare system ellipsis menus).
struct BrandedMenuButton<Content: View>: View {
    let help: String
    var systemImage: String = "ellipsis"
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.brand.opacity(hovering ? 0.10 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.brand.opacity(hovering ? 0.32 : 0.18), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .clickableCursor()
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

/// Compact brand-tinted segment control for page-local tabs.
struct BrandedSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selected ? Theme.surface : Theme.ink.opacity(0.72))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selected ? Theme.brand : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .clickableCursor()
            }
        }
        .padding(3)
        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }
}

struct PremiumSection<Content: View>: View {
    let title: String
    let icon: String?
    let content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(Theme.gold)
                }
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.navy)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }
}

struct FillRemainingHeightLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let metrics = metrics(for: proposal, subviews: subviews)
        return CGSize(width: metrics.width, height: metrics.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let metrics = metrics(
            for: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews
        )

        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: metrics.fixedSize.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + metrics.fixedSize.height + spacing),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: metrics.remainingHeight)
        )
    }

    private func metrics(for proposal: ProposedViewSize, subviews: Subviews) -> Metrics {
        guard subviews.count == 2 else { return .zero }

        let proposedWidth = finite(proposal.width)
        let fixedSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: proposedWidth, height: nil)
        )
        let width = proposedWidth ?? fixedSize.width

        guard let proposedHeight = finite(proposal.height) else {
            let flexibleSize = subviews[1].sizeThatFits(
                ProposedViewSize(width: width, height: nil)
            )
            return Metrics(
                width: max(width, flexibleSize.width),
                height: fixedSize.height + spacing + flexibleSize.height,
                fixedSize: fixedSize,
                remainingHeight: flexibleSize.height
            )
        }

        let remainingHeight = CGFloat(ResponsiveLayoutRules.remainingHeight(
            totalHeight: Double(proposedHeight),
            fixedHeight: Double(fixedSize.height),
            spacing: Double(spacing)
        ))
        return Metrics(
            width: width,
            height: proposedHeight,
            fixedSize: fixedSize,
            remainingHeight: remainingHeight
        )
    }

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private struct Metrics {
        let width: CGFloat
        let height: CGFloat
        let fixedSize: CGSize
        let remainingHeight: CGFloat

        static let zero = Metrics(width: 0, height: 0, fixedSize: .zero, remainingHeight: 0)
    }
}

struct WrappingHStack: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let layout = layout(for: proposal.width, subviews: subviews)
        return CGSize(width: layout.width, height: layout.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let layout = layout(for: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in layout.rows {
            var x = bounds.minX
            let rowHeight = row.map { layout.itemSizes[$0].height }.max() ?? 0
            for index in row {
                let size = layout.itemSizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + horizontalSpacing
            }
            y += rowHeight + verticalSpacing
        }
    }

    private func layout(for proposedWidth: CGFloat?, subviews: Subviews) -> Metrics {
        let itemSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let naturalWidth = itemSizes.reduce(0) { $0 + $1.width }
            + horizontalSpacing * CGFloat(max(0, itemSizes.count - 1))
        let availableWidth = finite(proposedWidth) ?? naturalWidth
        let rows = ResponsiveLayoutRules.rows(
            availableWidth: Double(max(0, availableWidth)),
            itemWidths: itemSizes.map { Double($0.width) },
            spacing: Double(horizontalSpacing)
        )
        let rowWidths = rows.map { row in
            row.reduce(0) { $0 + itemSizes[$1].width }
                + horizontalSpacing * CGFloat(max(0, row.count - 1))
        }
        let rowHeights = rows.map { row in
            row.map { itemSizes[$0].height }.max() ?? 0
        }
        let height = rowHeights.reduce(0, +)
            + verticalSpacing * CGFloat(max(0, rows.count - 1))

        return Metrics(
            width: finite(proposedWidth) ?? (rowWidths.max() ?? 0),
            height: height,
            itemSizes: itemSizes,
            rows: rows
        )
    }

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private struct Metrics {
        let width: CGFloat
        let height: CGFloat
        let itemSizes: [CGSize]
        let rows: [[Int]]
    }
}

private struct CommandPageHeaderLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let minimumTitleWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let metrics = metrics(for: proposal.width, subviews: subviews)
        return CGSize(width: metrics.width, height: metrics.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }
        let metrics = metrics(for: bounds.width, subviews: subviews)

        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: metrics.titleSize.width, height: metrics.titleSize.height)
        )

        let accessoryOrigin: CGPoint
        switch metrics.axis {
        case .horizontal:
            accessoryOrigin = CGPoint(
                x: bounds.maxX - metrics.accessorySize.width,
                y: bounds.minY
            )
        case .vertical:
            accessoryOrigin = CGPoint(
                x: bounds.minX,
                y: bounds.minY + metrics.titleSize.height + verticalSpacing
            )
        }
        subviews[1].place(
            at: accessoryOrigin,
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: metrics.accessorySize.width,
                height: metrics.accessorySize.height
            )
        )
    }

    private func metrics(for proposedWidth: CGFloat?, subviews: Subviews) -> Metrics {
        guard subviews.count == 2 else { return .zero }

        let titleIdeal = subviews[0].sizeThatFits(.unspecified)
        let accessorySize = subviews[1].sizeThatFits(.unspecified)
        let accessorySpacing = accessorySize.width > 0 ? horizontalSpacing : 0
        let naturalWidth = titleIdeal.width + accessorySpacing + accessorySize.width
        let availableWidth = finite(proposedWidth) ?? naturalWidth
        let axis = accessorySize.width == 0
            ? ResponsiveLayoutAxis.horizontal
            : ResponsiveLayoutRules.headerAxis(
                availableWidth: Double(availableWidth),
                accessoryWidth: Double(accessorySize.width),
                minimumTitleWidth: Double(minimumTitleWidth),
                spacing: Double(horizontalSpacing)
            )

        switch axis {
        case .horizontal:
            let titleWidth = max(0, availableWidth - accessorySize.width - accessorySpacing)
            let titleSize = subviews[0].sizeThatFits(
                ProposedViewSize(width: titleWidth, height: nil)
            )
            return Metrics(
                axis: axis,
                width: availableWidth,
                height: max(titleSize.height, accessorySize.height),
                titleSize: CGSize(width: titleWidth, height: titleSize.height),
                accessorySize: accessorySize
            )
        case .vertical:
            let titleSize = subviews[0].sizeThatFits(
                ProposedViewSize(width: availableWidth, height: nil)
            )
            return Metrics(
                axis: axis,
                width: availableWidth,
                height: titleSize.height + verticalSpacing + accessorySize.height,
                titleSize: titleSize,
                accessorySize: accessorySize
            )
        }
    }

    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private struct Metrics {
        let axis: ResponsiveLayoutAxis
        let width: CGFloat
        let height: CGFloat
        let titleSize: CGSize
        let accessorySize: CGSize

        static let zero = Metrics(
            axis: .horizontal,
            width: 0,
            height: 0,
            titleSize: .zero,
            accessorySize: .zero
        )
    }
}

struct CommandPageHeader<Accessory: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String
    let accessory: Accessory

    init(eyebrow: String? = nil,
         title: String,
         subtitle: String,
         @ViewBuilder accessory: () -> Accessory) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        CommandPageHeaderLayout(
            horizontalSpacing: 18,
            verticalSpacing: 14,
            minimumTitleWidth: 340
        ) {
            titleBlock
            accessory
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension CommandPageHeader where Accessory == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}

struct CommandPanel<Content: View>: View {
    let title: String?
    let icon: String?
    let content: Content

    init(_ title: String? = nil,
         icon: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || icon != nil {
                HStack(spacing: 8) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.gold)
                    }
                    if let title {
                        Text(title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.navy)
                    }
                    Spacer(minLength: 0)
                }
            }
            content
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }
}

struct CommandMetric: View {
    let icon: String
    let value: String
    let label: String
    var tint: Color = Theme.navy

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }
}

struct CommandToolbarButton: View {
    let systemImage: String
    let title: String
    var tint: Color = Theme.navy
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .background(Theme.white, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(tint.opacity(0.24), lineWidth: 1)
        )
        .help(title)
        .clickableCursor()
    }
}

struct CommandEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.gold)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}
