import AppKit

@MainActor
final class DockBadgeView: NSView {
    var label: String? {
        didSet { if label != oldValue { needsDisplay = true } }
    }

    var iconFrame = NSRect.zero {
        didSet { if iconFrame != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { superview?.isFlipped ?? false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let label else { return }
        Self.draw(label, on: iconFrame, in: bounds, isFlipped: isFlipped, diameterRatio: 0.28)
    }

    static func draw(_ label: String, on icon: NSRect, in bounds: NSRect, isFlipped: Bool, diameterRatio: CGFloat) {
        guard !icon.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let side = icon.width
        let isDot = label == "•"
        let diameter = (side * diameterRatio * (isDot ? 0.60 : 1)).rounded()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: diameter * 0.56, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let text = label as NSString
        let textSize = text.size(withAttributes: attributes)
        let width = isDot ? diameter : max(diameter, min(side * 0.80, ceil(textSize.width + diameter * 0.52)))

        // Long counts expand inward from the same corner as a single digit.
        let cornerInset = side * 0.18
        let right = min(bounds.maxX - 2, icon.maxX - cornerInset + diameter / 2)
        let centerY = isFlipped ? icon.minY + cornerInset : icon.maxY - cornerInset
        let y = min(max(centerY - diameter / 2, bounds.minY + 2), bounds.maxY - diameter - 2)
        let frame = NSRect(x: right - width, y: y, width: width, height: diameter)
        let capsule = NSBezierPath(roundedRect: frame, xRadius: diameter / 2, yRadius: diameter / 2)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: isFlipped ? 1 : -1), blur: 2,
                          color: NSColor.black.withAlphaComponent(0.22).cgColor)
        NSColor.systemRed.setFill()
        capsule.fill()
        context.restoreGState()

        guard !isDot else { return }
        let textHeight = ceil(textSize.height)
        text.draw(in: NSRect(x: frame.minX + 3, y: frame.midY - textHeight / 2,
                             width: frame.width - 6, height: textHeight), withAttributes: attributes)
    }
}
