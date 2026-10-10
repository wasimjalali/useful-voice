import AppKit
import SwiftUI

/// A bubble's text. SwiftUI's `Text` cannot report which words are selected, and
/// Teach a fix needs exactly that, so this is a read-only, selectable `NSTextView`.
///
/// It reports the selection (range and rect) when the mouse is released, turns a
/// Shift-click into a multi-select toggle instead of extending the text selection,
/// lays out RTL text per bubble, clamps to a line limit and reports how many lines
/// the full text needs so the bubble knows whether to offer "Show all".
struct StreamTextView: NSViewRepresentable {
    let spec: StreamTextSpec
    var lineLimit: Int?
    var maxWidth: CGFloat = 608
    var selectable = true
    var onSelectionEnd: ((NSRange, CGRect) -> Void)?
    var onShiftClick: (() -> Void)?
    var onPlainClick: (() -> Void)?
    var onLineCount: ((Int) -> Void)?

    func makeNSView(context: Context) -> StreamNSTextView {
        StreamNSTextView()
    }

    func updateNSView(_ view: StreamNSTextView, context: Context) {
        view.onSelectionEnd = onSelectionEnd
        view.onShiftClick = onShiftClick
        view.onPlainClick = onPlainClick
        view.onLineCount = onLineCount
        view.isSelectable = selectable
        if view.appliedSpec != spec { view.apply(spec) }
        if view.lineLimit != lineLimit {
            view.lineLimit = lineLimit
            view.textContainer?.maximumNumberOfLines = lineLimit ?? 0
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: StreamNSTextView, context: Context) -> CGSize? {
        let width = min(max(proposal.width ?? maxWidth, 40), maxWidth)
        return view.measure(width: width, finite: proposal.width != nil)
    }
}

final class StreamNSTextView: NSTextView {
    var onSelectionEnd: ((NSRange, CGRect) -> Void)?
    var onShiftClick: (() -> Void)?
    var onPlainClick: (() -> Void)?
    var onLineCount: ((Int) -> Void)?
    private(set) var appliedSpec: StreamTextSpec?
    var lineLimit: Int?
    private var lineHeight: CGFloat = 22
    private var reportedLines = 0

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 608, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byTruncatingTail
        container.widthTracksTextView = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        focusRingType = .none
        allowsUndo = false
        isAutomaticLinkDetectionEnabled = false
        selectedTextAttributes = [.backgroundColor: NSColor(Theme.ink).withAlphaComponent(0.16)]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { isSelectable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ spec: StreamTextSpec) {
        appliedSpec = spec
        let size: CGFloat = spec.rtl ? 15 : 14
        lineHeight = spec.rtl ? 26 : 22
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.baseWritingDirection = spec.rtl ? .rightToLeft : .leftToRight
        paragraph.alignment = .natural
        paragraph.lineBreakMode = .byWordWrapping
        let ink = NSColor(Theme.ink)
        let muted = NSColor(Theme.inkMuted)
        let regular = NSFont.systemFont(ofSize: size, weight: .regular)
        let strong = NSFont.systemFont(ofSize: size, weight: .semibold)
        let text = NSMutableAttributedString(string: spec.text, attributes: [
            .font: regular, .foregroundColor: ink, .paragraphStyle: paragraph,
        ])
        for span in spec.spans where NSMaxRange(span.range) <= text.length {
            switch span.style {
            case .match, .added:
                text.addAttributes([.font: strong, .backgroundColor: ink.withAlphaComponent(0.08)], range: span.range)
            case .removed:
                text.addAttributes([
                    .foregroundColor: muted,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: muted,
                ], range: span.range)
            case .teach:
                text.addAttributes([.backgroundColor: ink.withAlphaComponent(0.16)], range: span.range)
            }
        }
        textStorage?.setAttributedString(text)
    }

    /// The size the text needs at `width`: as wide as its longest line (the bubble hugs
    /// its text), or the full width for right-to-left text so it lines up on the right.
    /// Measured on the attributed string, so it never disturbs the layout the view draws.
    func measure(width: CGFloat, finite: Bool) -> CGSize {
        guard let storage = textStorage else { return .zero }
        let bound = storage.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        let lines = max(1, Int((bound.height / lineHeight).rounded()))
        // Only a real width counts: layout probes with tiny widths would report a long text.
        if finite, width >= 200, lines != reportedLines {
            reportedLines = lines
            DispatchQueue.main.async { [weak self] in self?.onLineCount?(lines) }
        }
        let shown = lineLimit.map { min(lines, $0) } ?? lines
        let rtl = appliedSpec?.rtl ?? false
        return CGSize(width: rtl ? width : min(ceil(bound.width), width), height: CGFloat(shown) * lineHeight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let container = textContainer, abs(container.containerSize.width - newSize.width) > 0.5, newSize.width > 0 {
            container.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) {
            onShiftClick?()
            return
        }
        onPlainClick?()
        // The base class tracks the drag and returns when the mouse is released.
        super.mouseDown(with: event)
        let range = selectedRange()
        if range.length > 0 {
            onSelectionEnd?(range, rect(for: range))
        }
    }

    /// Drops the system selection once Teach a fix has taken over the highlight.
    func clearSelection() {
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
    }

    private func rect(for range: NSRange) -> CGRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }
}
