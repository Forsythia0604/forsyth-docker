import AppKit

final class DockStackIconView: NSView {
    var icons: [NSImage] = [] {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let images = Array(icons.prefix(3))
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard images.count > 1 else {
            images.first?.draw(in: bounds)
            return
        }

        let poses: [(x: CGFloat, y: CGFloat, scale: CGFloat, angle: CGFloat)] = [
            (-0.062, -0.043, 0.90, -2),
            (0.092, 0.065, 0.82, 8),
            (-0.035, 0.135, 0.75, -8)
        ]
        let side = min(bounds.width, bounds.height)
        for index in images.indices.reversed() {
            let pose = poses[index]
            let edge = side * pose.scale
            context.saveGState()
            context.translateBy(x: bounds.midX + side * pose.x, y: bounds.midY + side * pose.y)
            context.rotate(by: pose.angle * .pi / 180)
            context.setShadow(
                offset: CGSize(width: 0, height: -side * 0.02),
                blur: side * 0.04,
                color: NSColor.black.withAlphaComponent(0.20).cgColor
            )
            images[index].draw(in: NSRect(x: -edge / 2, y: -edge / 2, width: edge, height: edge))
            context.restoreGState()
        }
    }
}

struct DockStackGridItem {
    let title: String
    let icon: NSImage
    let isRunning: Bool
    let notificationBadge: String?
    let menu: (() -> NSMenu)?
    let prepareMenu: (() async -> Void)?

    init(title: String, icon: NSImage, isRunning: Bool, notificationBadge: String? = nil, menu: (() -> NSMenu)? = nil,
         prepareMenu: (() async -> Void)? = nil) {
        self.title = title
        self.icon = icon
        self.isRunning = isRunning
        self.notificationBadge = notificationBadge
        self.menu = menu
        self.prepareMenu = prepareMenu
    }
}

@MainActor
final class DockStackFanView: NSView {
    private static let iconWidth: CGFloat = 86
    private static let rowRise: CGFloat = 78
    private static let inset: CGFloat = 7
    private let onSelect: (Int) -> Void
    private var buttons: [DockStackFanButton] = []
    private var gridMode = false
    private weak var contextMenuButton: DockStackFanButton?
    private(set) var preferredSize = NSSize(width: 140, height: 70)
    private(set) var anchorX: CGFloat = 0
    var onDismiss: (() -> Void)?

    override var intrinsicContentSize: NSSize { preferredSize }

    init(items: [DockStackGridItem], maximumSize: NSSize, onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)

        for (index, item) in items.enumerated() {
            let button = DockStackFanButton(item: item)
            button.tag = index
            button.target = self
            button.action = #selector(selectMember(_:))
            buttons.append(button)
        }

        let fanHeight = CGFloat(max(0, buttons.count - 1)) * Self.rowRise + Self.iconWidth + Self.inset
        gridMode = DockerStore.shared.configuration.stackStyle == "grid" || buttons.count > 6 || fanHeight > maximumSize.height
        if gridMode {
            let cellWidth = min(maximumSize.width - 28, (buttons.map(\.labelWidth).max() ?? 120) + Self.iconWidth + 14)
            let columns = max(1, min(3, Int((maximumSize.width - 28) / max(1, cellWidth))))
            let rows = max(1, Int(ceil(Double(buttons.count) / Double(columns))))
            let documentHeight = CGFloat(rows) * 91 + 16
            let height = min(maximumSize.height, documentHeight)
            preferredSize = NSSize(width: CGFloat(columns) * cellWidth + 28, height: height)
            anchorX = preferredSize.width / 2
            setFrameSize(preferredSize)
            wantsLayer = true
            layer?.cornerRadius = 14
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.97).cgColor
            let scroll = NSScrollView(frame: bounds.insetBy(dx: 9, dy: 7))
            scroll.drawsBackground = false; scroll.hasVerticalScroller = documentHeight > height
            scroll.autohidesScrollers = true
            let document = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(columns) * cellWidth, height: documentHeight))
            for (index, button) in buttons.enumerated() {
                let row = index / columns, column = index % columns
                button.frame = NSRect(x: CGFloat(column) * cellWidth, y: documentHeight - CGFloat(row + 1) * 91,
                                      width: Self.iconWidth + button.labelWidth, height: Self.iconWidth)
                document.addSubview(button)
            }
            scroll.documentView = document
            addSubview(scroll)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, documentHeight - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            setAccessibilityChildren(buttons)
            return
        }

        if let labelWidth = buttons.map(\.labelWidth).max() {
            anchorX = Self.inset + labelWidth + Self.iconWidth / 2
            preferredSize = NSSize(
                width: labelWidth + Self.iconWidth + 2 * Self.inset,
                height: CGFloat(buttons.count - 1) * Self.rowRise + Self.iconWidth + Self.inset
            )
        }
        setFrameSize(preferredSize)

        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: anchorX - Self.iconWidth / 2 - button.labelWidth,
                y: CGFloat(index) * Self.rowRise,
                width: Self.iconWidth + button.labelWidth,
                height: Self.iconWidth
            )
            addSubview(button)
        }
        setAccessibilityChildren(buttons)
    }

    required init?(coder: NSCoder) { nil }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    func handleContextMenuEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown, .leftMouseDown:
            guard let button = hitTest(convert(event.locationInWindow, from: nil)) as? DockStackFanButton,
                  button.beginContextMenuPress(for: event) else { return false }
            contextMenuButton = button
            return true
        case .rightMouseUp, .leftMouseUp:
            guard let button = contextMenuButton, button.endContextMenuPress(for: event) else { return false }
            contextMenuButton = nil
            return true
        default:
            return false
        }
    }

    func updateNotificationBadges(_ labels: [String?]) {
        for (index, button) in buttons.enumerated() {
            button.notificationBadge = index < labels.count ? labels[index] : nil
        }
    }

    func animateOpening() {
        if gridMode { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        for button in buttons {
            let translation = CABasicAnimation(keyPath: "transform.translation.y")
            translation.fromValue = 14 - button.frame.midY
            translation.toValue = 0
            translation.duration = 0.34
            translation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            button.layer?.add(translation, forKey: "fanOpening")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.26
            button.layer?.add(fade, forKey: "fanVisibility")
        }
    }

    func animateClosing(completion: @escaping @MainActor @Sendable () -> Void) {
        if gridMode {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                animator().alphaValue = 0
            } completionHandler: { Task { @MainActor in completion() } }
            return
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Capture the displayed pose so dismissing during opening does not jump.
        let poses = buttons.map { button in
            let layer = button.layer?.presentation() ?? button.layer
            return (translation: layer?.transform.m42 ?? 0, opacity: layer?.opacity ?? 1)
        }
        let bottomInset = reduceMotion ? 0 : reserveClosingSpace()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
            for (index, button) in buttons.enumerated() {
                guard let layer = button.layer else { continue }
                layer.removeAnimation(forKey: "fanOpening")
                layer.removeAnimation(forKey: "fanVisibility")

                let opacity = CABasicAnimation(keyPath: "opacity")
                opacity.fromValue = poses[index].opacity
                opacity.toValue = poses[index].opacity
                var animations: [CAAnimation] = [opacity]
                if !reduceMotion {
                    let direction: CGFloat = layer.superlayer?.isGeometryFlipped == true ? -1 : 1
                    let translation = CABasicAnimation(keyPath: "transform.translation.y")
                    translation.fromValue = poses[index].translation
                    translation.toValue = direction * (bottomInset + 14 - button.frame.midY)
                    animations.append(translation)
                }
                let closing = CAAnimationGroup()
                closing.animations = animations
                closing.duration = context.duration
                closing.timingFunction = context.timingFunction
                closing.fillMode = .forwards
                closing.isRemovedOnCompletion = false
                layer.add(closing, forKey: "fanClosing")
            }
        } completionHandler: {
            Task { @MainActor in completion() }
        }
    }

    private func reserveClosingSpace() -> CGFloat {
        guard let window, window.contentView === self else { return 0 }
        // The folded icon is centered at y=14, below its resting bounds. Enlarge
        // only the closing window, keeping every icon at the same screen position.
        // Moving NSView frames down instead would crop their backing stores before
        // their presentation layers have had a chance to animate there.
        let inset = Self.iconWidth / 2 - 14 + Self.inset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var expanded = window.frame
        expanded.origin.y -= inset
        expanded.size.height += inset
        window.setFrame(expanded, display: false)
        for button in buttons {
            button.frame = button.frame.offsetBy(dx: 0, dy: inset)
        }
        CATransaction.commit()
        return inset
    }

    @objc private func selectMember(_ sender: NSButton) {
        onSelect(sender.tag)
    }
}

@MainActor
private final class DockStackFanButton: NSButton {
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let item: DockStackGridItem
    let labelWidth: CGFloat
    var notificationBadge: String? {
        didSet {
            guard notificationBadge != oldValue else { return }
            updateAccessibilityHelp()
            needsDisplay = true
        }
    }
    private var tracking: NSTrackingArea?
    private var expectedContextMenuMouseUp: NSEvent.EventType?
    private var hovered = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }

    init(item: DockStackGridItem) {
        self.item = item
        notificationBadge = item.notificationBadge
        let width = (item.title as NSString).size(withAttributes: [.font: Self.font]).width
        labelWidth = min(172, ceil(width) + (item.isRunning ? 32 : 24))
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        wantsLayer = true
        setAccessibilityLabel(item.title)
        if item.menu != nil {
            let action = NSAccessibilityCustomAction(name: "显示菜单") { [weak self] in
                self?.accessibilityPerformShowMenu() ?? false
            }
            setAccessibilityCustomActions([action])
        }
        updateAccessibilityHelp()
    }

    required init?(coder: NSCoder) { nil }

    private func updateAccessibilityHelp() {
        var accessibilityStatus: [String] = []
        if item.isRunning { accessibilityStatus.append("正在运行") }
        if let notificationBadge {
            accessibilityStatus.append(notificationBadge == "•" ? "有通知" : "通知标记 \(notificationBadge)")
        }
        setAccessibilityHelp(accessibilityStatus.isEmpty ? nil : accessibilityStatus.joined(separator: "，"))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        if !beginContextMenuPress(for: event) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !endContextMenuPress(for: event) {
            super.rightMouseUp(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !beginContextMenuPress(for: event) {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !endContextMenuPress(for: event) {
            super.mouseUp(with: event)
        }
    }

    func beginContextMenuPress(for event: NSEvent) -> Bool {
        guard item.menu != nil else { return false }
        if event.type == .rightMouseDown {
            expectedContextMenuMouseUp = .rightMouseUp
        } else if event.type == .leftMouseDown && event.modifierFlags.contains(.control) {
            expectedContextMenuMouseUp = .leftMouseUp
        } else {
            return false
        }
        return true
    }

    func endContextMenuPress(for event: NSEvent) -> Bool {
        guard event.type == expectedContextMenuMouseUp else { return false }
        expectedContextMenuMouseUp = nil
        let point = convert(event.locationInWindow, from: nil)
        if iconHitArea.contains(point) || labelHitArea.contains(point) {
            _ = showContextMenu()
        }
        return true
    }

    private func showContextMenu() -> Bool {
        DockContextMenuDiagnostics.record("requested", view: self)
        guard item.menu != nil, window != nil else { return false }
        Task { @MainActor [weak self] in
            guard let self else { return }
            DockContextMenuDiagnostics.record("preparing", view: self)
            await self.item.prepareMenu?()
            DockContextMenuDiagnostics.record("prepared", view: self)
            guard self.window?.isVisible == true, self.window?.ignoresMouseEvents == false,
                  let menu = self.item.menu?() else { return }
            _ = DockContextMenu.show(menu, from: self, anchor: self.iconHitArea)
        }
        return true
    }

    override func accessibilityFrame() -> NSRect {
        guard let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(iconHitArea, to: nil))
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(accessibilityPerformShowMenu) { return item.menu != nil }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard item.menu != nil, window != nil else { return false }
        DispatchQueue.main.async { [weak self] in
            _ = self?.showContextMenu()
        }
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, super.hitTest(point) != nil else { return nil }
        let local = convert(point, from: superview)
        return iconHitArea.contains(local) || labelHitArea.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func updateHover(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hovered = iconHitArea.contains(point) || pillFrame.contains(point)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        drawLabel(emphasized: hovered || pressed)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let side: CGFloat = pressed ? 72 : 76
        let iconRect = NSRect(
            x: iconHitArea.midX - side / 2, y: iconHitArea.midY - side / 2,
            width: side, height: side
        )
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -2),
            blur: 5,
            color: NSColor.black.withAlphaComponent(0.3).cgColor
        )
        item.icon.draw(in: iconRect)
        context.restoreGState()

        if let notificationBadge {
            DockBadgeView.draw(notificationBadge, on: iconRect, in: bounds, isFlipped: isFlipped, diameterRatio: 0.235)
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: pillFrame, xRadius: 10, yRadius: 10).fill()
    }

    override var focusRingMaskBounds: NSRect { pillFrame }

    private var iconHitArea: NSRect {
        NSRect(x: labelWidth, y: 0, width: bounds.width - labelWidth, height: bounds.height)
            .insetBy(dx: 3, dy: 4)
    }

    private var pillFrame: NSRect {
        NSRect(x: 1, y: bounds.midY - 12, width: labelWidth - 5, height: 24)
    }

    private var labelHitArea: NSRect {
        NSRect(x: 0, y: pillFrame.minY, width: iconHitArea.minX, height: pillFrame.height)
    }

    private func drawLabel(emphasized: Bool) {
        let pill = pillFrame
        NSColor.black.withAlphaComponent(emphasized ? 0.79 : 0.61).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()

        let padding: CGFloat = item.isRunning ? 18 : 9
        if item.isRunning {
            NSColor.white.withAlphaComponent(0.83).setFill()
            NSBezierPath(ovalIn: NSRect(x: pill.minX + 8, y: pill.midY - 2, width: 4, height: 4)).fill()
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = item.isRunning ? .left : .center
        paragraph.lineBreakMode = .byTruncatingTail
        (item.title as NSString).draw(
            in: NSRect(x: pill.minX + padding, y: pill.midY - 8, width: pill.width - padding - 8, height: 16),
            withAttributes: [.font: Self.font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        )
    }
}
