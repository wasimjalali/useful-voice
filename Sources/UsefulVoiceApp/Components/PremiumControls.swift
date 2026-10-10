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

    /// The board's field: 32 pt, 10 pt radius, a `controlEdge` border that turns ink on
    /// focus (with a soft 3 pt ring) and danger on error.
    func premiumInputChrome(error: Bool = false) -> some View {
        modifier(PremiumInputChrome(error: error))
    }

    /// The board's lift card: bubble surface, faint edge, 14 pt radius, lift shadow.
    func liftCard() -> some View {
        self
            .background(Theme.bubble, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Theme.edge, lineWidth: 1))
            .themeShadow(.lift)
    }

    /// The soft ring around a focused field: ink at low strength, outside the border.
    fileprivate func fieldFocusRing(_ focused: Bool, error: Bool) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(error ? Theme.danger.opacity(0.14) : Theme.ink.opacity(0.12), lineWidth: 3)
                .padding(-3)
                .opacity(focused || error ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

private struct PremiumInputChrome: ViewModifier {
    let error: Bool
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.uv(.ui))
            .foregroundStyle(Theme.ink)
            .focused($focused)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(error ? Theme.danger : focused ? Theme.ink : Theme.controlEdge, lineWidth: 1))
            .fieldFocusRing(focused, error: error)
            .opacity(isEnabled ? 1 : 0.55)
            .brandAnimation(BrandMotion.control, value: focused)
    }
}

// MARK: - Buttons

/// Primary, secondary, ghost and tone buttons from the board. 30 pt tall (38 with
/// `.controlSize(.large)`, 26 with `.small`), 10 pt radius, hover, pressed, a ring
/// when keyboard-focused, and a 55 % disabled state.
struct BrandButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case ghost
        /// A tinted button such as danger: `foreground` text on a `background` wash.
        case tone(foreground: Color, background: Color)
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        BrandButtonBody(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == BrandButtonStyle {
    static var brandPrimary: BrandButtonStyle { BrandButtonStyle(kind: .primary) }
    static var brandSecondary: BrandButtonStyle { BrandButtonStyle(kind: .secondary) }
    static var brandGhost: BrandButtonStyle { BrandButtonStyle(kind: .ghost) }
    static var brandDanger: BrandButtonStyle {
        BrandButtonStyle(kind: .tone(foreground: Theme.danger, background: Theme.dangerSoft))
    }
}

private struct BrandButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: BrandButtonStyle.Kind

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    private var height: CGFloat {
        switch controlSize {
        case .large, .extraLarge: return 38
        case .small, .mini: return 26
        default: return 30
        }
    }

    private var font: Font {
        switch controlSize {
        case .large, .extraLarge: return .uv(.body, .medium)
        case .small, .mini: return .uv(.meta, .medium)
        default: return .uv(.ui, .medium)
        }
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .large, .extraLarge: return 16
        case .small, .mini: return 10
        default: return 12
        }
    }

    private var active: Bool { hovering || configuration.isPressed }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.accentInk
        case .secondary: return Theme.ink
        case .ghost: return active ? Theme.ink : Theme.inkMuted
        case .tone(let foreground, _): return foreground
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return active ? Theme.accentStrong : Theme.accent
        case .secondary: return active ? Theme.line : Theme.sunken
        case .ghost: return active ? Theme.sunken : Color.clear
        case .tone(_, let background): return background
        }
    }

    private var edge: Color {
        switch kind {
        case .secondary: return Theme.edge
        default: return Color.clear
        }
    }

    var body: some View {
        configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay {
                if case .tone(let foreground, _) = kind, active {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(foreground.opacity(0.1))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(edge, lineWidth: 1))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: 2)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
            }
            .modifier(PrimaryShadow(enabled: { if case .primary = kind { return true } else { return false } }()))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .onHover { hovering = $0 }
            .focusEffectDisabled()
            .clickableCursor()
            .brandAnimation(BrandMotion.control, value: hovering)
            .brandAnimation(BrandMotion.control, value: configuration.isPressed)
    }
}

private struct PrimaryShadow: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.themeShadow(.small)
        } else {
            content
        }
    }
}

// MARK: - Switch

/// The board's switch: 34 by 20. Off is a hollow track with a 3:1 edge and a muted
/// knob, on is a solid ink track with a light knob, so state reads without color.
struct BrandSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BrandSwitchBody(configuration: configuration)
    }
}

private struct BrandSwitchBody: View {
    let configuration: ToggleStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                track
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .overlay(alignment: .trailing) {
            if isFocused {
                RoundedRectangle(cornerRadius: 12.5, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: 2)
                    .frame(width: 40, height: 26)
                    .allowsHitTesting(false)
            }
        }
        .opacity(isEnabled ? 1 : 0.55)
        .clickableCursor()
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }

    /// A pill drawn as a circular-style rounded rectangle a little under half its height.
    /// A stroked `Capsule` (or a continuous corner at half height) renders flat stubs at
    /// both ends in CoreGraphics.
    private var track: some View {
        let on = configuration.isOn
        let shape = RoundedRectangle(cornerRadius: 9, style: .circular)
        return shape
            .fill(on ? Theme.accent : Theme.surface)
            .overlay(shape.strokeBorder(on ? Color.clear : Theme.controlEdge, lineWidth: 1.5))
            .overlay(alignment: .leading) {
                Circle()
                    .fill(on ? Theme.accentInk : Theme.inkMuted)
                    .frame(width: 12, height: 12)
                    .offset(x: on ? 18 : 4)
            }
            .frame(width: 34, height: 20)
            .brandAnimation(BrandMotion.control, value: on)
    }
}

// MARK: - Chip, key cap and status pill

/// A filter or tag chip: 26 pt, pill, quiet by default, solid ink when selected.
/// Display-only when `action` is nil.
struct BrandChip: View {
    let title: String
    var selected = false
    var action: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .clickableCursor()
                .accessibilityAddTraits(selected ? [.isSelected] : [])
        } else {
            chip
        }
    }

    private var chip: some View {
        Text(title)
            .font(.uv(.meta))
            .lineLimit(1)
            .foregroundStyle(selected ? Theme.accentInk : Theme.inkMuted)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(selected ? Theme.accent : (hovering ? Theme.line : Theme.sunken), in: Capsule())
            .overlay(RoundedRectangle(cornerRadius: 12, style: .circular)
                .strokeBorder(selected ? Color.clear : Theme.edge, lineWidth: 1))
            .brandAnimation(BrandMotion.control, value: hovering)
    }
}

/// A key cap such as "Right Command": 20 pt, 6 pt radius, a 1 pt bottom edge.
struct BrandKbd: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.uv(.label, .semibold))
            .lineLimit(1)
            .foregroundStyle(Theme.inkMuted)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: Theme.lineStrong, radius: 0, x: 0, y: 1))
            .overlay(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .strokeBorder(Theme.lineStrong, lineWidth: 1))
            .fixedSize()
    }
}

/// The status pill: 22 pt, pill radius, a soft wash of the status color.
struct PremiumStatusBadge: View {
    enum Kind {
        case ok
        case warn
        case bad
        case neutral
    }

    let icon: String?
    let text: String
    private let foreground: Color
    private let background: Color

    /// Any tint; the wash is the tint at low strength.
    init(icon: String? = nil, text: String, tint: Color) {
        self.icon = icon
        self.text = text
        self.foreground = tint
        self.background = tint.opacity(0.12)
    }

    /// The four status roles with their exact soft backgrounds.
    init(kind: Kind, icon: String? = nil, text: String) {
        self.icon = icon
        self.text = text
        switch kind {
        case .ok: (foreground, background) = (Theme.success, Theme.successSoft)
        case .warn: (foreground, background) = (Theme.warning, Theme.warningSoft)
        case .bad: (foreground, background) = (Theme.danger, Theme.dangerSoft)
        case .neutral: (foreground, background) = (Theme.inkMuted, Theme.sunken)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.uv(.label, .semibold))
            }
            Text(text)
                .font(.uv(.label, .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(background, in: Capsule())
    }
}

// MARK: - Icon button, search field, menus

/// The board's icon button: 30 pt, 10 pt radius, muted ink, a soft wash on hover.
struct PremiumIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PremiumIconButtonBody(configuration: configuration)
    }
}

private struct PremiumIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.uv(.meta, .semibold))
            .foregroundStyle(hovering || configuration.isPressed ? Theme.ink : Theme.inkMuted)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering || configuration.isPressed ? Theme.accentSoft : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(Theme.ink, lineWidth: 2)
                    .padding(-2)
                    .opacity(isFocused ? 1 : 0)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .onHover { hovering = $0 }
            .focusEffectDisabled()
            .clickableCursor()
            .brandAnimation(BrandMotion.control, value: hovering)
            .brandAnimation(BrandMotion.control, value: configuration.isPressed)
    }
}

struct PremiumSearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.uv(.ui, .semibold))
                .foregroundStyle(focused ? Theme.ink : Theme.inkMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.uv(.ui))
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(focused ? Theme.ink : Theme.controlEdge, lineWidth: 1)
        )
        .fieldFocusRing(focused, error: false)
        .brandAnimation(BrandMotion.control, value: focused)
    }
}

/// An on-brand selection dropdown.
///
/// Previously this was a SwiftUI `Menu`, whose popup is drawn by AppKit and so
/// ignored the design system entirely. That is the same reason the language control was
/// moved to a popover. A popover lets the list keep the surface, hairline border,
/// sunken hover and ink checkmark every other control uses.
struct BrandedMenuPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    @State private var isPresented = false
    @State private var hovering = false
    /// The row the pointer or the arrow keys last landed on. One piece of state
    /// drives both, so hover and keyboard can never disagree about the highlight.
    @State private var highlightedIndex = 0
    /// Holds focus while the popover is open so Up/Down/Return work without the
    /// mouse; the native `Menu` this replaced had that, so the popover must too.
    @FocusState private var listFocused: Bool

    private var selectedLabel: String {
        options.first { $0.value == selection }?.label ?? title
    }

    var body: some View {
        Button {
            highlightedIndex = options.firstIndex { $0.value == selection } ?? 0
            isPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                Text(selectedLabel)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.uv(.label, .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
            .font(.uv(.ui, .medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(hovering || isPresented ? Theme.sunken : Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(isPresented ? Theme.ink : Theme.controlEdge, lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering = $0 }
        .brandAnimation(BrandMotion.control, value: hovering)
        .brandAnimation(BrandMotion.control, value: isPresented)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { menuList }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(selectedLabel)
        .clickableCursor()
    }

    private var menuList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    choose(option.value)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark")
                            .font(.uv(.label, .bold))
                            .foregroundStyle(Theme.ink)
                            .opacity(isSelected ? 1 : 0)
                            .frame(width: 12, alignment: .leading)
                        Text(option.label)
                            .font(.uv(.ui, isSelected ? .semibold : .regular))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                            .fill(highlightedIndex == index ? Theme.sunken : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { highlightedIndex = $0 ? index : highlightedIndex }
                .clickableCursor()
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(6)
        .frame(minWidth: 170)
        .background(Theme.bubble)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Theme.lineStrong, lineWidth: 1)
        )
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onAppear { listFocused = true }
        .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
        .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
        .onKeyPress(.return) {
            guard options.indices.contains(highlightedIndex) else { return .ignored }
            choose(options[highlightedIndex].value)
            return .handled
        }
        .onKeyPress(.escape) { isPresented = false; return .handled }
    }

    private func moveHighlight(_ delta: Int) {
        guard !options.isEmpty else { return }
        highlightedIndex = (highlightedIndex + delta + options.count) % options.count
    }

    private func choose(_ value: Value) {
        selection = value
        isPresented = false
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
                .font(.uv(.meta, .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .fill(hovering ? Theme.sunken : Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                        .strokeBorder(Theme.lineStrong, lineWidth: 1)
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
        .brandAnimation(BrandMotion.control, value: hovering)
    }
}

/// The board's segmented control: a `line` track with a 2 pt inset, 6 pt item radius,
/// and a raised `segmentOn` item for the selection.
struct BrandedSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.uv(.meta, selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.ink : Theme.inkMuted)
                        .lineLimit(1)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                                .fill(selected ? Theme.segmentOn : Color.clear)
                                .themeShadow(selected ? .segment : .none)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickableCursor()
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(Theme.line, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .brandAnimation(BrandMotion.control, value: selection)
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
                        .foregroundStyle(Theme.inkMuted)
                }
                Text(title)
                    .font(.uv(.title, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            content
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
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
    let title: String
    let accessory: Accessory

    init(title: String,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.accessory = accessory()
    }

    var body: some View {
        CommandPageHeaderLayout(
            horizontalSpacing: 18,
            verticalSpacing: 14,
            minimumTitleWidth: 280
        ) {
            Text(title)
                .font(.uv(.statement, .bold))
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
            accessory
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension CommandPageHeader where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) {
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
                            .font(.uv(.ui, .semibold))
                            .foregroundStyle(Theme.inkMuted)
                    }
                    if let title {
                        Text(title)
                            .font(.uv(.title, .semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    Spacer(minLength: 0)
                }
            }
            content
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }
}

struct CommandMetric: View {
    let icon: String
    let value: String
    let label: String
    var tint: Color = Theme.ink

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.uv(.title, .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.uv(.figure, .bold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(label)
                    .font(.uv(.label, .medium))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surfaceSubtle, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }
}

struct CommandToolbarButton: View {
    let systemImage: String
    let title: String
    var tint: Color = Theme.ink
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.uv(.meta, .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
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
                .font(.uv(.statement, .light))
                .foregroundStyle(Theme.inkMuted)
            Text(title)
                .font(.uv(.title, .semibold))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.uv(.ui))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

/// A quiet inline note under a settings row.
///
/// For facts the user needs but did not ask for (a provider charge, a limit)
/// where an alert would be alarming and silence would be dishonest. Deliberately
/// low-contrast and sunken so it reads as a footnote rather than a call to action,
/// and uses no new hue: the design system has exactly three status colours and this
/// is not a status.
struct InlineNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.uv(.label))
                .foregroundStyle(Theme.inkMuted)
                .padding(.top, 1)
            Text(text)
                .font(.uv(.label))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
