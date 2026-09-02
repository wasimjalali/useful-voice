import AppKit
import ObjectiveC.runtime

/// Thin overlay scrollbar, matching Useful Brain's 3px faint thumb.
/// Replaces the system "always show" scroller, which is wide and dark gray.
final class ThinScroller: NSScroller {
    private static let thickness: CGFloat = 5
    private static let gutter: CGFloat = 8

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        gutter
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        controlSize = .mini
        scrollerStyle = .overlay
        knobStyle = .default
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        var knob = rect(for: .knob)
        guard !knob.isEmpty else { return }

        if bounds.width >= bounds.height {
            let y = knob.midY - Self.thickness / 2
            knob = NSRect(
                x: knob.minX + 3,
                y: y,
                width: max(0, knob.width - 6),
                height: Self.thickness
            )
        } else {
            let x = knob.midX - Self.thickness / 2
            knob = NSRect(
                x: x,
                y: knob.minY + 3,
                width: Self.thickness,
                height: max(0, knob.height - 6)
            )
        }

        let path = NSBezierPath(roundedRect: knob, xRadius: Self.thickness / 2, yRadius: Self.thickness / 2)
        let color = isHighlighted ? Theme.scrollKnobActiveNSColor : Theme.scrollKnobNSColor
        color.setFill()
        path.fill()
    }
}

enum ThinScrollbar {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        guard
            let original = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.tile)),
            let swizzled = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.uv_tile))
        else { return }
        method_exchangeImplementations(original, swizzled)
    }
}

private var uvApplyingThinChrome: UInt8 = 0
private var uvScrollObserver: UInt8 = 0
private var uvHideWork: UInt8 = 0
private var uvLastOrigin: UInt8 = 0
private var uvRevealed: UInt8 = 0

extension NSScrollView {
    @objc fileprivate func uv_tile() {
        uv_tile()
        uv_applyThinChrome()
    }

    fileprivate func uv_applyThinChrome() {
        if objc_getAssociatedObject(self, &uvApplyingThinChrome) as? Bool == true { return }
        objc_setAssociatedObject(self, &uvApplyingThinChrome, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        defer {
            objc_setAssociatedObject(self, &uvApplyingThinChrome, false, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        if scrollerStyle != .overlay {
            scrollerStyle = .overlay
        }
        autohidesScrollers = true
        if !(verticalScroller is ThinScroller) {
            verticalScroller = ThinScroller(frame: verticalScroller?.frame ?? .zero)
        }
        if !(horizontalScroller is ThinScroller) {
            horizontalScroller = ThinScroller(frame: horizontalScroller?.frame ?? .zero)
        }
        uv_installScrollFade()
        if objc_getAssociatedObject(self, &uvRevealed) as? Bool != true {
            uv_setScrollersHidden(true)
        }
    }

    fileprivate func uv_installScrollFade() {
        contentView.postsBoundsChangedNotifications = true
        if objc_getAssociatedObject(self, &uvScrollObserver) as? Bool == true { return }
        objc_setAssociatedObject(self, &uvScrollObserver, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(uv_contentBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
        uv_setScrollersHidden(true)
    }

    @objc fileprivate func uv_contentBoundsDidChange() {
        uv_revealScrollers()
    }

    fileprivate func uv_revealScrollers() {
        let origin = contentView.bounds.origin
        let boxed = NSValue(point: origin)
        if let previous = objc_getAssociatedObject(self, &uvLastOrigin) as? NSValue {
            if previous.pointValue == origin { return }
        } else {
            objc_setAssociatedObject(self, &uvLastOrigin, boxed, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        objc_setAssociatedObject(self, &uvLastOrigin, boxed, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(self, &uvRevealed, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        uv_setScrollersHidden(false)

        if let previous = objc_getAssociatedObject(self, &uvHideWork) as? DispatchWorkItem {
            previous.cancel()
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            objc_setAssociatedObject(self, &uvRevealed, false, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                self.verticalScroller?.animator().alphaValue = 0
                self.horizontalScroller?.animator().alphaValue = 0
            } completionHandler: {
                if objc_getAssociatedObject(self, &uvRevealed) as? Bool != true {
                    self.uv_setScrollersHidden(true)
                }
            }
        }
        objc_setAssociatedObject(self, &uvHideWork, work, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    fileprivate func uv_setScrollersHidden(_ hidden: Bool) {
        for scroller in [verticalScroller, horizontalScroller] {
            guard let scroller else { continue }
            scroller.isHidden = hidden
            scroller.alphaValue = hidden ? 0 : 1
        }
    }
}
