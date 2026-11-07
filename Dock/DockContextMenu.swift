import AppKit

@MainActor
enum DockContextMenuDiagnostics {
    private(set) static var snapshot: [String: Any] = [:]
    static func record(_ stage: String, view: NSView, items: Int? = nil) {
        snapshot = ["stage": stage, "view": String(describing: type(of: view)),
                    "windowVisible": view.window?.isVisible ?? false,
                    "ignoresMouseEvents": view.window?.ignoresMouseEvents ?? false,
                    "items": items ?? 0]
    }
}

@MainActor
enum DockContextMenu {
    /// Returns true once AppKit has shown the menu, including when tracking ends without a selection.
    static func show(_ menu: NSMenu, from view: NSView, anchor: NSRect? = nil) -> Bool {
        DockContextMenuDiagnostics.record("positioning", view: view, items: menu.numberOfItems)
        guard let window = view.window else { return false }
        let screenAnchor = window.convertToScreen(view.convert(anchor ?? view.bounds, to: nil))
        let center = NSPoint(x: screenAnchor.midX, y: screenAnchor.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? window.screen ?? NSScreen.main else { return false }

        menu.update()
        guard menu.numberOfItems > 0 else { return false }
        let frame = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = menu.size
        let width = min(frame.width, ceil(size.width))
        let height = min(frame.height, ceil(size.height))
        let gap: CGFloat = 6
        let above = frame.maxY - screenAnchor.maxY - gap
        let below = screenAnchor.minY - gap - frame.minY
        let preferredTop = above >= height || above >= below
            ? screenAnchor.maxY + gap + height
            : screenAnchor.minY - gap
        let top = min(frame.maxY, max(frame.minY + height, preferredTop))
        let left = min(frame.maxX - width, max(frame.minX, center.x - width / 2))
        let leading = view.userInterfaceLayoutDirection == .rightToLeft ? left + width : left

        // Use the screen as the positioning space so the short Dock panel
        // cannot constrain the menu to its own height.
        DockContextMenuDiagnostics.record("presenting", view: view, items: menu.numberOfItems)
        menu.popUp(positioning: nil, at: NSPoint(x: leading, y: top), in: nil)
        DockContextMenuDiagnostics.record("closed", view: view, items: menu.numberOfItems)
        return true
    }
}
