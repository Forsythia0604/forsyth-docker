import AppKit
import Darwin

@MainActor
private enum DockBackgroundCursor {
    private typealias Connection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static let symbols = UnsafeMutableRawPointer(bitPattern: -2)
    private static let connection: Connection? = {
        guard let symbol = dlsym(symbols, "CGSMainConnectionID") else { return nil }
        return unsafeBitCast(symbol, to: Connection.self)
    }()
    private static let setProperty: SetProperty? = {
        guard let symbol = dlsym(symbols, "CGSSetConnectionProperty") else { return nil }
        return unsafeBitCast(symbol, to: SetProperty.self)
    }()
    private static var enabled = false

    @discardableResult
    static func setEnabled(_ value: Bool) -> Bool {
        guard value != enabled, let connection, let setProperty else { return false }
        let identifier = connection()
        // WindowServer otherwise ignores NSCursor changes from an inactive app.
        // This optional SPI affects only our connection's cursor, and is enabled
        // only for an owned resize interaction. Missing symbols fail harmlessly.
        guard setProperty(identifier, identifier, "SetsCursorInBackground" as CFString,
                          value ? kCFBooleanTrue : kCFBooleanFalse) == 0 else { return false }
        enabled = value
        return true
    }
}

enum DockResizeMetrics {
    enum Edge { case top, bottom, left, right }
    static let range: ClosedRange<Double> = 40...112
    static func size(start: Double, verticalDelta: Double) -> Double {
        let proposed = start + verticalDelta
        guard proposed.isFinite else { return start }
        return min(range.upperBound, max(range.lowerBound, proposed)).rounded()
    }

    static func size(start: Double, translation: CGPoint, edge: Edge, slotCount: Int, scale: Double) -> Double {
        let scale = scale.isFinite ? max(0.1, scale) : 1
        let delta: Double
        switch edge {
        case .top: delta = Double(translation.y) / scale
        case .bottom: delta = -Double(translation.y) / scale
        case .left: delta = -2 * Double(translation.x) / (Double(max(1, slotCount)) * scale)
        case .right: delta = 2 * Double(translation.x) / (Double(max(1, slotCount)) * scale)
        }
        return size(start: start, verticalDelta: delta)
    }
}

@MainActor
final class DockResizeHandle: NSView {
    var currentSize: (() -> Double)?
    var onBegin: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?
    var slotCount: (() -> Int)?
    var renderScale: (() -> Double)?
    let edge: DockResizeMetrics.Edge
    private var startPoint: CGPoint?
    private var startSlotCount = 1
    private var startScale: Double = 1
    private var startSize: Double = 81
    private var lastSize: Double = 81
    private var cursorTrackingArea: NSTrackingArea?
    private var dragCursorPushed = false
    private static weak var cursorOwner: DockResizeHandle?
    private static weak var dragOwner: DockResizeHandle?

    private var resizeCursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch edge {
        case .top: position = .top
        case .bottom: position = .bottom
        case .left: position = .left
        case .right: position = .right
        }
        return .frameResize(position: position, directions: .all)
    }

    init(edge: DockResizeMetrics.Edge) {
        self.edge = edge
        super.init(frame: .zero)
        let side: String
        switch edge { case .top: side = "上"; case .bottom: side = "下"; case .left: side = "左"; case .right: side = "右" }
        toolTip = "拖动 Dock 外边缘调整大小"
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Dock \(side)边缘大小")
        setAccessibilityHelp("拖动 Dock 外边缘调整大小")
        setAccessibilityMinValue(40); setAccessibilityMaxValue(112)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: resizeCursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // A Dock panel stays non-key while another application is active.
        // activeAlways does not deliver cursorUpdate, so set the cursor from
        // entered/moved events as well as keeping the ordinary cursor rect.
        if cursorTrackingArea == nil {
            // inVisibleRect follows layout automatically. Replacing the area
            // on every drag frame can lose the pending mouse-exited event.
            let area = NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                          .inVisibleRect, .enabledDuringMouseDrag],
                owner: self, userInfo: nil)
            cursorTrackingArea = area
            addTrackingArea(area)
        }
        if Self.dragOwner == nil, Self.cursorOwner === self { restoreHoverCursor() }
    }

    override func cursorUpdate(with event: NSEvent) { showResizeCursor() }
    override func mouseEntered(with event: NSEvent) { showResizeCursor(); recordCursor("entered") }
    override func mouseMoved(with event: NSEvent) { showResizeCursor(); recordCursor("moved") }
    override func mouseExited(with event: NSEvent) {
        if let owner = Self.dragOwner { owner.showResizeCursor() }
        else if Self.cursorOwner === self {
            Self.cursorOwner = nil
            NSCursor.arrow.set()
            DockBackgroundCursor.setEnabled(false)
        }
        recordCursor("exited")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { cancelCursorTracking() }
        super.viewWillMove(toWindow: newWindow)
    }

    func cancelCursorTracking() {
        let wasDragging = startPoint != nil
        startPoint = nil
        releaseDragCursor()
        if Self.cursorOwner === self {
            Self.cursorOwner = nil
            NSCursor.arrow.set()
            DockBackgroundCursor.setEnabled(false)
        }
        if wasDragging { onEnd?(lastSize) }
    }

    private func showResizeCursor() {
        let owner = Self.dragOwner ?? self
        Self.cursorOwner = owner
        if DockBackgroundCursor.setEnabled(true) { NSCursor.arrow.set() }
        owner.resizeCursor.set()
        // AppKit may refresh cursor rects after dispatching the mouse event or
        // laying out the resized panel. Reassert only while we still own it.
        DispatchQueue.main.async { [weak owner] in
            guard let owner, Self.cursorOwner === owner else { return }
            owner.resizeCursor.set()
        }
    }

    private func releaseDragCursor() {
        if Self.dragOwner === self { Self.dragOwner = nil }
        if dragCursorPushed { NSCursor.pop(); dragCursorPushed = false }
    }

    private func restoreHoverCursor() {
        if let content = window?.contentView,
           let location = window?.mouseLocationOutsideOfEventStream,
           let handle = content.hitTest(content.convert(location, from: nil)) as? DockResizeHandle {
            handle.showResizeCursor()
        } else if Self.cursorOwner === self {
            Self.cursorOwner = nil
            NSCursor.arrow.set()
            DockBackgroundCursor.setEnabled(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = NSEvent.mouseLocation
        startSize = currentSize?() ?? 81; lastSize = startSize
        startSlotCount = slotCount?() ?? 1; startScale = renderScale?() ?? 1
        Self.dragOwner = self
        resizeCursor.push(); dragCursorPushed = true
        onBegin?()
        showResizeCursor()
        recordCursor("pressed")
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = NSEvent.mouseLocation
        lastSize = DockResizeMetrics.size(start: startSize,
            translation: CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y),
            edge: edge, slotCount: startSlotCount, scale: startScale)
        setAccessibilityValue(lastSize)
        onChange?(lastSize)
        // Resizing moves the hit regions under the pointer. Keep the original
        // drag direction even when the pointer leaves an edge or crosses another.
        showResizeCursor()
        recordCursor("dragged")
    }

    override func mouseUp(with event: NSEvent) {
        guard startPoint != nil else { return }
        startPoint = nil
        releaseDragCursor()
        onEnd?(lastSize)
        restoreHoverCursor()
        recordCursor("released")
    }

    private func recordCursor(_ phase: String) {
        guard DockResizeCursorDiagnostics.enabled else { return }
        captureCursor(phase)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.captureCursor(phase + ".settled")
        }
    }

    private func captureCursor(_ phase: String) {
        let owner = Self.dragOwner ?? Self.cursorOwner
        DockResizeCursorDiagnostics.record(phase: phase, edge: String(describing: edge),
            expected: owner?.resizeCursor ?? .arrow,
            axis: owner.map { $0.edge == .left || $0.edge == .right ? "horizontal" : "vertical" } ?? "arrow",
            window: window, size: currentSize?() ?? lastSize)
    }

    override func accessibilityPerformIncrement() -> Bool { accessibleStep(1); return true }
    override func accessibilityPerformDecrement() -> Bool { accessibleStep(-1); return true }
    private func accessibleStep(_ delta: Double) {
        let size = DockResizeMetrics.size(start: currentSize?() ?? 81, verticalDelta: delta)
        onBegin?(); onChange?(size); onEnd?(size)
        setAccessibilityValue(size)
    }
}

// Opt-in evidence for live testing, never collected in a normal launch or a
// release build. Read the system cursor, rather than just the cursor we requested.
@MainActor
enum DockResizeCursorDiagnostics {
    static let enabled = Bundle.main.object(forInfoDictionaryKey: "ForsythDevelopmentBuild") as? Bool == true
        && CommandLine.arguments.contains("--resize-cursor-diagnostics")
    private static var samples: [[String: Any]] = []
    static var snapshot: [String: Any] { enabled ? ["samples": samples] : [:] }

    static func record(phase: String, edge: String, expected: NSCursor, axis: String,
                       window: NSWindow?, size: Double) {
        guard enabled else { return }
        let system = NSCursor.currentSystem
        let point = NSEvent.mouseLocation
        var sample: [String: Any] = [
            "phase": phase, "edge": edge, "axis": axis,
            "timestamp": Date().timeIntervalSince1970,
            "mouseButtons": NSEvent.pressedMouseButtons,
            "pointerX": point.x, "pointerY": point.y,
            "iconSize": size, "applicationActive": NSApp.isActive,
            "windowKey": window?.isKeyWindow ?? false,
            "applicationCursorMatches": NSCursor.current == expected,
            "systemCursorAvailable": system != nil
        ]
        if let system {
            sample["systemCursorPNG"] = png(system.image)?.base64EncodedString()
            sample["systemHotSpot"] = [system.hotSpot.x, system.hotSpot.y]
        }
        sample["expectedCursorPNG"] = png(expected.image)?.base64EncodedString()
        samples.append(sample)
        if samples.count > 256 { samples.removeFirst(samples.count - 256) }
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
