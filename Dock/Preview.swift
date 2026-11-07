import AppKit
import QuartzCore

@MainActor
private enum PreviewIcons {
    static let dockResources = URL(fileURLWithPath: "/System/Library/CoreServices/Dock.app/Contents/Resources")
    static let coreResources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources")
    static let finder = NSImage(contentsOf: coreResources.appendingPathComponent("FinderIcon.icns"))
        ?? NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")

    static func trash(full: Bool, appearance: NSAppearance) -> NSImage {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let variant = isDark ? "2" : ""
        let state = full ? "trashfull" : "trashempty"
        let name = "s-\(state)\(variant)@2x.png"
        let fallback = full ? "FullTrashIcon.icns" : "TrashIcon.icns"
        return NSImage(contentsOf: dockResources.appendingPathComponent(name))
            ?? NSImage(contentsOf: coreResources.appendingPathComponent(fallback))
            ?? NSImage(systemSymbolName: "trash", accessibilityDescription: "废纸篓")
            ?? NSImage()
    }
}

@MainActor
private final class PreviewTrashView: NSImageView {
    var isFull = false {
        didSet {
            if isFull != oldValue { updateImage() }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        updateImage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateImage()
    }

    private func updateImage() {
        image = PreviewIcons.trash(full: isFull, appearance: effectiveAppearance)
    }
}

@MainActor
private final class PreviewTile: NSButton {
    let iconView: NSView
    let indicator = NSView()
    private let artworkView = NSView()
    private let badgeView = DockBadgeView()
    var showsIndicator = false {
        didSet {
            guard showsIndicator != oldValue else { return }
            let visible = showsIndicator
            indicator.isHidden = false
            guard window?.isVisible == true else {
                indicator.alphaValue = visible ? 1 : 0
                indicator.isHidden = !visible
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.38
                indicator.animator().alphaValue = visible ? 1 : 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.showsIndicator == visible else { return }
                    self.indicator.isHidden = !visible
                }
            }
        }
    }
    var notificationBadge: String? {
        didSet {
            guard notificationBadge != oldValue else { return }
            badgeView.label = notificationBadge
            if let notificationBadge {
                setAccessibilityHelp(notificationBadge == "•" ? "有通知" : "通知角标 \(notificationBadge)")
            } else {
                setAccessibilityHelp(nil)
            }
        }
    }
    var actionMenu: (() -> NSMenu)? {
        didSet {
            guard actionMenu != nil else {
                setAccessibilityCustomActions([])
                return
            }
            let action = NSAccessibilityCustomAction(name: "显示菜单") { [weak self] in
                guard let self, self.window != nil else { return false }
                DispatchQueue.main.async { [weak self] in _ = self?.showContextMenu() }
                return true
            }
            setAccessibilityCustomActions([action])
        }
    }
    private var isControlClick = false
    private var contextMenuRevision = 0
    var prepareMenu: (() async -> Void)?
    var runningApplication: DockApplication?

    init(name: String, iconView: NSView, target: AnyObject, action: Selector) {
        self.iconView = iconView
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = ""
        setButtonType(.momentaryChange)
        isBordered = false
        focusRingType = .default
        wantsLayer = true
        setAccessibilityLabel(name)
        toolTip = name
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 2
        indicator.isHidden = true
        addSubview(indicator)
        artworkView.wantsLayer = true
        artworkView.addSubview(iconView)
        artworkView.addSubview(badgeView)
        addSubview(artworkView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The icon and running dot are decorative. Their parent is the click target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === self || hit.isDescendant(of: self) ? self : hit
    }

    override func layout() {
        super.layout()
        let side = bounds.width
        let indicatorOrigin = isFlipped ? side + 2 : 4
        artworkView.frame = bounds
        iconView.frame = NSRect(x: 0, y: 10, width: side, height: side)
        indicator.frame = NSRect(x: (side - 4) / 2, y: indicatorOrigin, width: 4, height: 4)
        badgeView.frame = artworkView.bounds
        badgeView.iconFrame = iconView.frame
        updateIndicatorColor()
    }

    func place(in frame: NSRect, animated: Bool) {
        if animated { animator().frame = frame }
        else { self.frame = frame }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateIndicatorColor()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard showContextMenu() else { super.rightMouseDown(with: event); return }
    }

    override func rightMouseUp(with event: NSEvent) {
        if actionMenu == nil {
            super.rightMouseUp(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        isControlClick = event.modifierFlags.contains(.control) && actionMenu != nil
        if isControlClick { _ = showContextMenu() }
        else { contextMenuRevision += 1; super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard isControlClick else {
            super.mouseUp(with: event)
            return
        }
        isControlClick = false
    }

    private func showContextMenu() -> Bool {
        DockContextMenuDiagnostics.record("requested", view: self)
        guard actionMenu != nil, window != nil else { return false }
        contextMenuRevision += 1
        let revision = contextMenuRevision
        Task { @MainActor [weak self] in
            guard let self else { return }
            DockContextMenuDiagnostics.record("preparing", view: self)
            await self.prepareMenu?()
            DockContextMenuDiagnostics.record("prepared", view: self)
            guard self.contextMenuRevision == revision, self.window?.isVisible == true,
                  let menu = self.actionMenu?() else { return }
            _ = DockContextMenu.show(menu, from: self)
        }
        return true
    }

    private func updateIndicatorColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            indicator.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.8).cgColor
        }
    }
}

@MainActor
private final class PreviewDockView: NSView {
    private(set) var iconSize: CGFloat
    private let groupTiles: [PreviewTile]
    private let utilityTiles: [PreviewTile]
    private var runningTiles: [PreviewTile] = []
    private var fadingTiles: [PreviewTile] = []
    private var runningLayoutRevision = 0
    private(set) var isAnimatingLayout = false
    private let glassBase = NSView()
    private let glass = NSGlassEffectView()
    private let tileContent = NSView()
    private let separator = NSView()
    let resizeHandles = [DockResizeMetrics.Edge.top, .bottom, .left, .right].map { DockResizeHandle(edge: $0) }
    var resizeSlotCount: Int { groupTiles.count + runningTiles.count + utilityTiles.count }
    var resizeScale: CGFloat { scale }
    private let spacing: CGFloat = 8
    private let separatorSpace: CGFloat = 14
    private let padding: CGFloat = 12
    private let baseline: CGFloat = 2
    var maximumWidth: CGFloat = .greatestFiniteMagnitude

    init(groups: [PreviewTile], utilities: [PreviewTile], iconSize: CGFloat) {
        groupTiles = groups
        utilityTiles = utilities
        self.iconSize = iconSize
        super.init(frame: .zero)
        glass.cornerRadius = 29
        glassBase.wantsLayer = true
        glassBase.layer?.cornerRadius = 29
        addSubview(glassBase)
        // This is the shared Dock surface, not one large button. Interactive
        // glass scales its content on press, which makes every icon grow.
        if #available(macOS 27.0, *) { glass.effectIsInteractive = false }
        addSubview(glass)
        // Icons have a stable coordinate space while the glass changes width.
        tileContent.wantsLayer = true
        addSubview(tileContent)
        tileContent.addSubview(separator)
        separator.wantsLayer = true
        separator.layer?.cornerRadius = 1
        separator.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.22).cgColor
        for tile in groupTiles { tileContent.addSubview(tile) }
        for tile in utilityTiles { tileContent.addSubview(tile) }
        for handle in resizeHandles { addSubview(handle) }
        applyGlass(configuration: DockerStore.shared.configuration)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func updateIconSize(_ size: CGFloat) {
        iconSize = size
        runningLayoutRevision += 1
        isAnimatingLayout = false
        for tile in fadingTiles { tile.removeFromSuperview() }
        fadingTiles.removeAll()
        withoutAnimation {
            for view in layoutViews { view.layer?.removeAllAnimations() }
            for tile in runningTiles + groupTiles + utilityTiles {
                tile.alphaValue = 1
            }
        }
        for handle in resizeHandles { handle.setAccessibilityValue(Double(size)) }
        needsLayout = true
    }

    func applyGlass(configuration: DockerConfiguration) {
        glass.style = configuration.glassStyle == "clear" ? .clear : .regular
        // Keep the native refraction and specular edges at full strength. Adjust
        // the neutral backing instead of fading the entire glass and its content.
        glass.alphaValue = 1
        glass.tintColor = nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            glassBase.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(1 - configuration.glassTransparency).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGlass(configuration: DockerStore.shared.configuration)
    }

    func tile(for applicationID: String) -> PreviewTile? {
        (runningTiles + fadingTiles).first { $0.runningApplication?.id == applicationID }
    }

    func setRunningTiles(_ tiles: [PreviewTile], reposition: @escaping @MainActor @Sendable () -> Void) {
        guard !runningTiles.elementsEqual(tiles, by: { $0 === $1 }) else { return }
        runningLayoutRevision += 1
        let revision = runningLayoutRevision
        isAnimatingLayout = true
        // Capture every icon, including a partially faded exit, before replacing
        // an in-flight transition. A new request always continues from this frame.
        freezeLayoutAnimations()
        let previousTiles = runningTiles + fadingTiles
        let previous = Set(previousTiles.map(ObjectIdentifier.init))
        let next = Set(tiles.map(ObjectIdentifier.init))
        let newTiles = tiles.filter { !previous.contains(ObjectIdentifier($0)) }
        fadingTiles = previousTiles.filter { !next.contains(ObjectIdentifier($0)) }
        runningTiles = tiles
        for tile in fadingTiles { tile.isEnabled = false }
        for tile in newTiles { tileContent.addSubview(tile, positioned: .below, relativeTo: groupTiles.first) }
        for tile in tiles { tile.isEnabled = true }

        guard let window, window.isVisible, let screen = window.screen else {
            for tile in fadingTiles { tile.removeFromSuperview() }
            fadingTiles.removeAll()
            withoutAnimation { for tile in tiles { tile.alphaValue = 1 } }
            isAnimatingLayout = false
            reposition()
            return
        }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let size = preferredSize
        let targetWindow = NSRect(
            x: floor(screen.frame.midX - size.width / 2), y: window.frame.minY,
            width: size.width, height: size.height
        )
        let envelope = window.frame.union(targetWindow)
        if envelope != window.frame {
            let shift = window.frame.minX - envelope.minX
            withoutAnimation {
                for view in layoutViews {
                    view.frame = view.frame.offsetBy(dx: shift, dy: 0)
                }
                window.setFrame(envelope, display: false)
                tileContent.frame = bounds
            }
        }
        let originX = targetWindow.minX - window.frame.minX
        let side = iconSize * scale
        withoutAnimation {
            for tile in newTiles {
                guard let index = runningTiles.firstIndex(where: { $0 === tile }) else { continue }
                tile.frame = NSRect(
                    x: originX + padding * scale + CGFloat(index) * (side + spacing * scale),
                    y: baseline, width: side, height: side + 10
                )
                tile.alphaValue = 0
            }
        }
        window.displayIfNeeded()

        let reflow: @MainActor @Sendable () -> Void = { [weak self] in
            self?.reflowRunningTiles(newTiles, revision: revision, targetWindow: targetWindow,
                                    reduceMotion: reduceMotion, reposition: reposition)
        }
        guard !fadingTiles.isEmpty else { reflow(); return }
        // Keep the old gap and glass fixed until the exiting artwork has gone.
        animateTransition(revision: revision, duration: reduceMotion ? 0.18 : 0.42) {
            for tile in self.fadingTiles {
                tile.animator().alphaValue = 0
                if !reduceMotion {
                    let inset = tile.frame.width * 0.12
                    tile.place(in: tile.frame.insetBy(dx: inset, dy: inset), animated: true)
                }
            }
        } completion: { [weak self] in
            guard let self else { return }
            for tile in self.fadingTiles { tile.removeFromSuperview() }
            self.fadingTiles.removeAll()
            reflow()
        }
    }

    private var layoutViews: [NSView] {
        [glassBase, glass, separator] + runningTiles + fadingTiles + groupTiles + utilityTiles + resizeHandles
    }

    func positionWindow(in frame: NSRect) {
        guard !isAnimatingLayout, let window else { return }
        withoutAnimation {
            if window.frame != frame { window.setFrame(frame, display: false) }
            tileContent.frame = bounds
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        window.displayIfNeeded()
    }

    private func withoutAnimation(_ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }
    }

    private func freezeLayoutAnimations() {
        let states = layoutViews.map { view -> (NSView, NSRect, CGFloat) in
            var frame = view.frame
            var alpha = view.alphaValue
            if let layer = view.layer, let presentation = layer.presentation() {
                frame.origin.x += presentation.frame.minX - layer.frame.minX
                frame.origin.y += presentation.frame.minY - layer.frame.minY
                frame.size = presentation.frame.size
                alpha = CGFloat(presentation.opacity)
            }
            return (view, frame, alpha)
        }
        withoutAnimation {
            for (view, frame, alpha) in states {
                view.layer?.removeAllAnimations()
                view.frame = frame
                view.alphaValue = alpha
                view.layoutSubtreeIfNeeded()
            }
        }
    }

    private func animateTransition(revision: Int, duration: TimeInterval,
                                   changes: @escaping @MainActor () -> Void,
                                   completion: @escaping @MainActor @Sendable () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            changes()
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.runningLayoutRevision == revision else { return }
                completion()
            }
        }
    }

    private func reflowRunningTiles(_ newTiles: [PreviewTile], revision: Int, targetWindow: NSRect,
                                    reduceMotion: Bool, reposition: @escaping @MainActor @Sendable () -> Void) {
        guard let window, runningLayoutRevision == revision else { return }
        let inserted = Set(newTiles.map(ObjectIdentifier.init))
        let originX = targetWindow.minX - window.frame.minX
        animateTransition(revision: revision, duration: reduceMotion ? 0.20 : 0.42) {
            self.layoutContents(originX: originX, animated: true)
            for tile in self.runningTiles where !inserted.contains(ObjectIdentifier(tile)) {
                tile.animator().alphaValue = 1
            }
        } completion: { [weak self, weak window] in
            guard let self, let window else { return }
            // Rebase the outer window and the entire icon plane in one flush.
            self.withoutAnimation {
                window.setFrame(targetWindow, display: false)
                self.tileContent.frame = self.bounds
                self.layoutContents(originX: 0, animated: false)
                self.layoutSubtreeIfNeeded()
            }
            window.displayIfNeeded()
            let finish: @MainActor @Sendable () -> Void = { [weak self] in
                self?.isAnimatingLayout = false
                reposition()
            }
            guard !newTiles.isEmpty else { finish(); return }
            self.animateTransition(revision: revision, duration: reduceMotion ? 0.20 : 0.40) {
                for tile in newTiles { tile.animator().alphaValue = 1 }
            } completion: { finish() }
        }
    }

    private var fullWidth: CGFloat {
        let count = CGFloat(groupTiles.count + runningTiles.count + utilityTiles.count)
        return count * iconSize + (count - 1) * spacing + separatorSpace + 2 * padding
    }

    private var scale: CGFloat {
        min(1, maximumWidth / fullWidth)
    }

    var preferredSize: NSSize {
        NSSize(width: ceil(fullWidth * scale), height: ceil(iconSize * scale) + 28)
    }

    var glassFrameInWindow: NSRect { glass.convert(glass.bounds, to: nil) }
    var glassIsInteractive: Bool {
        if #available(macOS 27.0, *) { return glass.effectIsInteractive }
        return false
    }

    override func layout() {
        super.layout()
        tileContent.frame = bounds
        guard !isAnimatingLayout else { return }
        layoutContents(originX: 0, animated: false)
    }

    private func layoutContents(originX: CGFloat, animated: Bool) {
        func place(_ view: NSView, _ frame: NSRect) {
            if animated {
                view.animator().frame = frame
            } else {
                view.frame = frame
            }
        }

        let scale = self.scale
        let side = iconSize * scale
        let glassHeight = side + 13
        let separatorHeight = (side * 0.70).rounded()
        place(glass, NSRect(x: originX, y: baseline, width: preferredSize.width, height: glassHeight))
        place(glassBase, NSRect(x: originX, y: baseline, width: preferredSize.width, height: glassHeight))
        var x = originX + padding * scale
        for tile in runningTiles + groupTiles {
            let frame = NSRect(x: x, y: baseline, width: side, height: side + 10)
            tile.place(in: frame, animated: animated)
            x += side + spacing * scale
        }
        let gap = separatorSpace * scale
        place(separator, NSRect(
            x: x + gap / 2 - 1,
            y: baseline + (glassHeight - separatorHeight) / 2,
            width: 2,
            height: separatorHeight
        ))
        x += gap
        for tile in utilityTiles {
            tile.place(in: NSRect(x: x, y: baseline, width: side, height: side + 10), animated: animated)
            x += side + spacing * scale
        }
        for handle in resizeHandles {
            let frame: NSRect
            switch handle.edge {
            case .top: frame = NSRect(x: originX, y: baseline + glassHeight - 4, width: preferredSize.width, height: 8)
            case .bottom: frame = NSRect(x: originX, y: 0, width: preferredSize.width, height: 6)
            case .left: frame = NSRect(x: originX, y: 6, width: 7, height: max(0, glassHeight - 8))
            case .right: frame = NSRect(x: originX + preferredSize.width - 7, y: 6, width: 7, height: max(0, glassHeight - 8))
            }
            place(handle, frame)
        }
    }
}

@MainActor
private final class DockFanPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class DockPreviewController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let apps = DockApplications()
    private let notificationBadges = DockNotificationBadges()
    private var badgesByApp: [String: String] = [:]
    private let windowBoundary = DockWindowBridge()
    private let windowShortcut = DockWindowShortcut()
    private let windowBoundaryKey = "maximizeAboveDock"
    private var panel: NSPanel?
    private var dockView: PreviewDockView?
    private var statusItem: NSStatusItem?
    private var toggleMenuItem: NSMenuItem?
    private var windowBoundaryMenuItem: NSMenuItem?
    private var directMaximizeMenuItem: NSMenuItem?
    private var groupTiles: [PreviewTile] = []
    private var applicationTiles: [PreviewTile] = []
    private var libraryTile: PreviewTile?
    private var renderedConfiguration: DockerConfiguration?
    private var trashIcon: PreviewTrashView?
    private var trashTile: PreviewTile?
    private let trashService = TrashService()
    private var trashTimer: Timer?
    private var fanPanel: DockFanPanel?
    private var openGroup: Int?
    private var stackEditors: [String: StackListEditorController] = [:]
    private var localFanMonitor: Any?
    private var globalFanMonitor: Any?
    private weak var fanContextMenu: NSMenu?
    private var fanContextMenuIsOpen = false
    private var dockRequestedVisible = true
    private var dockSuppressed = false
    private var visibilityRevision = 0
    var onShowSettings: (() -> Void)?
    var onShowQuit: (() -> Void)?
    var onRecover: (() -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var activityTimer: Timer?
    private var displayCandidate: String?
    private var displayCandidateSince = Date.distantPast
    private var automaticMeeting = false
    private var shouldShowDock: Bool {
        let c = DockerStore.shared.configuration
        return dockRequestedVisible && !dockSuppressed && c.nativeDockHidden && !c.meetingMode && !automaticMeeting
    }
    private var transitionalDockTop: CGFloat?
    private var isResizingDock = false
    private var deferredReload = false
    private var frozenGeometry: (screenFrame: NSRect, visibleFrame: NSRect, dockFrame: NSRect)?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var foregroundRevision = 0
    private var stopping = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuCopyService.shared.onWillInvoke = { [weak self] in self?.dismissGroup() }
        buildStatusMenu()
        buildPanel()
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDockForeground() }
            })
        }
        apps.onRunningApplicationsChange = { [weak self] in self?.refreshRunningTiles() }
        refreshRunningTiles()
        notificationBadges.onChange = { [weak self] badges in self?.applyNotificationBadges(badges) }
        notificationBadges.start()
        windowBoundary.geometry = { [weak self] in self?.windowBoundaryGeometry() }
        windowBoundary.onStatusChange = { status in
            UserDefaults.standard.set(status, forKey: "maximizeAboveDockStatus")
        }
        UserDefaults.standard.removeObject(forKey: "maximizeAboveDockStatus")
        windowBoundary.onSuppressionChange = { [weak self] suppressed in
            self?.dockSuppressed = suppressed
            self?.applyDockVisibility()
        }
        apps.onRestoreMinimizedWindow = { [weak self] pid in
            self?.windowBoundary.restoreMinimizedWindow(for: pid)
        }
        windowBoundary.enabled = DockerStore.shared.configuration.avoidanceEnabled
        dockRequestedVisible = DockerStore.shared.configuration.dockVisible
        configurationObserver = NotificationCenter.default.addObserver(forName: .dockerConfigurationChanged, object: DockerStore.shared, queue: .main) { [weak self] notification in
            let catalogChanged = notification.userInfo?["catalogChanged"] as? Bool == true
            Task { @MainActor in self?.reloadConfiguration(catalogChanged: catalogChanged) }
        }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.activityTick() }
        }
        timer.tolerance = 0.1; RunLoop.main.add(timer, forMode: .common); activityTimer = timer
        windowBoundary.start()
        refreshTrash()
        trashTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrash() }
        }
        applyDockVisibility()
        activityTick()
        updateWindowShortcut()
        buildApplicationMenu()

    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        if isResizingDock { finishDockResize(Double(dockView?.iconSize ?? 81)) }
        dismissGroup()
        positionPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuCopyService.shared.onWillInvoke = nil
        stopping = true; foregroundRevision += 1
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        windowShortcut.stop()
        activityTimer?.invalidate()
        trashTimer?.invalidate()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        dismissGroup()
        Array(stackEditors.values).forEach { $0.close() }
        stackEditors.removeAll()
        dockView?.resizeHandles.forEach { $0.cancelCursorTracking() }
        panel?.orderOut(nil)
        windowBoundary.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        dockRequestedVisible = true
        toggleMenuItem?.title = "隐藏 Dock"
        applyDockVisibility()
        showSettings()
        return true
    }

    private func dismissGroup() {
        if let localFanMonitor { NSEvent.removeMonitor(localFanMonitor) }
        if let globalFanMonitor { NSEvent.removeMonitor(globalFanMonitor) }
        localFanMonitor = nil
        globalFanMonitor = nil
        openGroup = nil
        fanContextMenuIsOpen = false
        fanContextMenu = nil
        if let closing = fanPanel {
            closing.ignoresMouseEvents = true
            if let view = closing.contentView as? DockStackFanView, closing.isVisible {
                view.animateClosing { closing.orderOut(nil) }
            } else {
                closing.orderOut(nil)
            }
        }
        fanPanel = nil
    }

    private func buildStatusMenu() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Docker")
            ?? NSImage(systemSymbolName: "square.stack", accessibilityDescription: "Docker")
        image?.isTemplate = true
        status.button?.image = image
        status.button?.toolTip = "Docker"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "打开 Docker 控制台…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: dockRequestedVisible ? "隐藏 Dock" : "显示 Dock", action: #selector(toggleDock), keyEquivalent: "")
        toggle.target = self
        toggleMenuItem = toggle
        for (index, group) in apps.groups.enumerated() {
            let submenu = NSMenu()
            for (appIndex, app) in group.applications.enumerated() {
                let item = submenu.addItem(withTitle: app.name, action: #selector(openFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [index, appIndex]
            }
            let groupItem = menu.addItem(withTitle: group.name, action: nil, keyEquivalent: "")
            groupItem.submenu = submenu
        }
        menu.addItem(.separator())
        let boundary = menu.addItem(withTitle: "窗口避开 Dock", action: #selector(toggleWindowBoundary(_:)), keyEquivalent: "")
        boundary.target = self
        windowBoundaryMenuItem = boundary
        let direct = menu.addItem(withTitle: "最大化到 Dock 上方", action: #selector(maximizeAboveDock), keyEquivalent: "")
        direct.target = self
        direct.keyEquivalentModifierMask = [.control, .option]
        directMaximizeMenuItem = direct
        menu.addItem(.separator())
        menu.addItem(withTitle: "一键退出其他应用…", action: #selector(showQuitPage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "恢复系统 Dock", action: #selector(recoverNativeDock), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Docker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApplication.shared
        status.menu = menu
        statusItem = status
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === fanContextMenu {
            fanContextMenuIsOpen = true
        } else if menu === statusItem?.menu {
            windowBoundaryMenuItem?.state = windowBoundaryMenuState
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === fanContextMenu else { return }
        fanContextMenuIsOpen = false
        fanContextMenu = nil
    }

    private var windowBoundaryMenuState: NSControl.StateValue {
        guard windowBoundary.enabled else { return .off }
        return DockWindowBridge.isTrusted ? .on : .mixed
    }

    private func buildPanel() {
        groupTiles = apps.groups.enumerated().map { index, group in
            let stack = DockStackIconView(frame: .zero)
            let covers = PlacementResolver.coverIDs(memberIDs: group.applications.map(\.id), topApplicationID: group.topApplicationID)
            stack.icons = covers.compactMap { id in group.applications.first(where: { $0.id == id })?.icon }
            if group.symbol.hasPrefix("custom:"), let icon = NSImage(systemSymbolName: String(group.symbol.dropFirst(7)), accessibilityDescription: group.name) { stack.icons = [icon] }
            if stack.icons.isEmpty, let icon = NSImage(systemSymbolName: group.symbol, accessibilityDescription: group.name) { stack.icons = [icon] }
            let tile = PreviewTile(name: group.name, iconView: stack, target: self, action: #selector(openGroupFromTile(_:)))
            tile.tag = index
            tile.actionMenu = { [weak self] in self?.groupMenu(index: index) ?? NSMenu() }
            return tile
        }
        do {
            let image = NativeApplicationLibrary.icon
            let tile = PreviewTile(name: "程序列表", iconView: imageView(image), target: self, action: #selector(openApplicationLibrary(_:)))
            tile.actionMenu = { [weak self] in
                let menu = NSMenu()
                menu.addItem(withTitle: "打开程序列表", action: #selector(DockPreviewController.openApplicationLibrary(_:)), keyEquivalent: "").target = self
                return menu
            }
            libraryTile = tile
        }
        let trashImage = PreviewTrashView(frame: .zero)
        trashIcon = trashImage
        let trash = PreviewTile(name: "废纸篓", iconView: trashImage, target: self, action: #selector(openTrash(_:)))
        trashTile = trash
        trash.actionMenu = { [weak self] in
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(withTitle: "打开废纸篓", action: #selector(DockPreviewController.openTrash(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            self?.refreshTrash()
            let empty = menu.addItem(withTitle: self?.trashService.isEmptying == true ? "正在清倒…" : "清倒废纸篓…", action: #selector(DockPreviewController.emptyTrash(_:)), keyEquivalent: "")
            empty.target = self
            empty.isEnabled = self?.trashService.state != .empty && self?.trashService.isEmptying == false
            return menu
        }
        let iconSize = CGFloat(DockerStore.shared.configuration.iconSize)
        let dock = PreviewDockView(groups: groupTiles, utilities: [trash], iconSize: iconSize)
        dockView = dock
        for handle in dock.resizeHandles {
            handle.currentSize = { [weak dock] in Double(dock?.iconSize ?? 81) }
            handle.slotCount = { [weak dock] in dock?.resizeSlotCount ?? 1 }
            handle.renderScale = { [weak dock] in Double(dock?.resizeScale ?? 1) }
            handle.setAccessibilityValue(Double(iconSize))
            handle.onBegin = { [weak self] in self?.beginDockResize() }
            handle.onChange = { [weak self] in self?.previewDockSize($0) }
            handle.onEnd = { [weak self] in self?.finishDockResize($0) }
        }
        let frame = NSRect(origin: .zero, size: dock.preferredSize)
        let window = NSPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        window.title = "Docker"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.becomesKeyOnlyIfNeeded = true
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone, .ignoresCycle]
        window.contentView = dock
        window.setAccessibilityLabel("Docker")
        panel = window
        refreshTrash()
        renderedConfiguration = DockerStore.shared.configuration
    }

    private func positionPanel() {
        guard panel != nil, let dockView,
              let screen = selectedScreen() else { return }
        // Foreground and display-follow callbacks must not replace the envelope
        // used by an active icon transition with its smaller final window.
        guard !dockView.isAnimatingLayout else { return }
        dockView.maximumWidth = screen.frame.width - 16
        let size = dockView.preferredSize
        let origin = NSPoint(x: floor(screen.frame.midX - size.width / 2), y: screen.frame.minY + 3)
        let target = NSRect(origin: origin, size: size)
        dockView.positionWindow(in: target)
        windowBoundary.geometryChanged()
        if let fanPanel, let openGroup, let fanView = fanPanel.contentView as? DockStackFanView,
           let origin = fanOrigin(for: fanView, relativeTo: groupTiles[openGroup]) {
            fanPanel.setFrameOrigin(origin)
        }
    }

    private func windowBoundaryGeometry() -> (screenFrame: NSRect, visibleFrame: NSRect, dockFrame: NSRect)? {
        if isResizingDock { return frozenGeometry }
        guard dockRequestedVisible, DockerStore.shared.configuration.nativeDockHidden, !DockerStore.shared.configuration.meetingMode, !automaticMeeting, let panel, let screen = panel.screen, let dockView else { return nil }
        var dockFrame = panel.convertToScreen(dockView.glassFrameInWindow)
        if let transitionalDockTop { dockFrame.size.height = max(dockFrame.height, transitionalDockTop - dockFrame.minY) }
        return (screen.frame, screen.visibleFrame, dockFrame)
    }

    @objc private func toggleWindowBoundary(_ item: NSMenuItem) {
        DockerStore.shared.change { $0.avoidanceEnabled.toggle() }
        windowBoundary.enabled = DockerStore.shared.configuration.avoidanceEnabled
        item.state = windowBoundaryMenuState
        updateWindowShortcut()
        if windowBoundary.enabled, !DockWindowBridge.isTrusted {
            windowBoundary.requestTrust()
        }
    }

    @objc private func maximizeAboveDock() {
        windowBoundary.maximizeFocusedWindow()
    }

    private func updateWindowShortcut() {
        let enabled = windowBoundary.enabled && panel?.isVisible == true
        directMaximizeMenuItem?.isHidden = !enabled
        guard enabled else {
            windowShortcut.stop()
            return
        }
        let registered = windowShortcut.start { [weak self] in self?.maximizeAboveDock() }
        directMaximizeMenuItem?.keyEquivalent = registered ? "\r" : ""
    }

    private func refreshRunningTiles() {
        guard !isResizingDock else { deferredReload = true; return }
        let visibleApps = apps.visibleApplications
        let priorTiles = Dictionary(uniqueKeysWithValues: applicationTiles.compactMap { tile in
            tile.runningApplication.map { ($0.id, tile) }
        })
        applicationTiles = visibleApps.map { app in
            let tile: PreviewTile
            if let prior = priorTiles[app.id] ?? dockView?.tile(for: app.id) {
                tile = prior
            } else {
                let icon = app.id == DockApplications.finderID ? PreviewIcons.finder : app.icon
                tile = PreviewTile(name: app.name, iconView: imageView(icon), target: self, action: #selector(openRunningTile(_:)))
            }
            let running = apps.isRunning(app)
            tile.showsIndicator = running && DockerStore.shared.configuration.showRunningIndicators
            tile.notificationBadge = DockerStore.shared.configuration.showBadges ? badgesByApp[app.id] : nil
            tile.runningApplication = app
            tile.prepareMenu = { await MenuCopyService.shared.prepareMenu(for: app) }
            tile.actionMenu = { [weak self] in
                self?.applicationMenu(for: app, isStandalone: true) ?? NSMenu()
            }
            return tile
        }
        var slots = applicationTiles
        if let libraryTile { slots.insert(libraryTile, at: min(1, slots.count)) }
        dockView?.setRunningTiles(slots) { [weak self] in
            self?.positionPanel()
        }
    }

    private func applyNotificationBadges(_ badges: [String: String]) {
        badgesByApp = (DockerStore.shared.configuration.showBadges ? badges : [:]).mapValues { label in
            ["•", "●", "·", "⬤"].contains(label) ? "•" : label
        }
        for tile in applicationTiles {
            if let app = tile.runningApplication {
                tile.notificationBadge = DockerStore.shared.configuration.showBadges ? badgesByApp[app.id] : nil
            }
        }
        for (group, tile) in zip(apps.groups, groupTiles) {
            tile.notificationBadge = groupedNotificationBadge(for: group)
        }
        if let openGroup, let view = fanPanel?.contentView as? DockStackFanView {
            view.updateNotificationBadges(apps.groups[openGroup].applications.map { badgesByApp[$0.id] })
        }
    }

    private func groupedNotificationBadge(for group: DockGroup) -> String? {
        let labels = group.applications.compactMap { badgesByApp[$0.id] }
        guard labels.count > 1 else { return labels.first }
        var total = 0
        var partial = false
        for label in labels {
            let hasPlus = label.hasSuffix("+")
            let digits = hasPlus ? String(label.dropLast()) : label
            if let count = Int(digits), count >= 0 {
                total += min(count, 1000)
                partial = partial || hasPlus
            } else {
                partial = true
            }
        }
        if total == 0, partial { return "•" }
        if total > 999 { return "999+" }
        return partial ? "\(total)+" : "\(total)"
    }

    private func imageView(_ image: NSImage) -> NSImageView {
        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    @objc private func openApplicationLibrary(_ sender: Any?) {
        dismissGroup()
        NativeApplicationLibrary.open()
    }

    private func groupMenu(index: Int) -> NSMenu {
        let menu = NSMenu()
        let group = apps.groups[index]
        let edit = menu.addItem(withTitle: "编辑列表…", action: #selector(editGroupListFromMenu(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = group.id
        menu.addItem(.separator())
        for (appIndex, app) in group.applications.enumerated() {
            let item = menu.addItem(withTitle: app.name, action: #selector(openFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [index, appIndex]
        }
        menu.addItem(.separator())
        let cover = NSMenu()
        let automatic = cover.addItem(withTitle: "自动（按应用顺序）", action: #selector(setCoverFromMenu(_:)), keyEquivalent: "")
        automatic.target = self; automatic.representedObject = [group.id, ""]
        automatic.state = group.topApplicationID == nil ? .on : .off
        for app in group.applications {
            let item = cover.addItem(withTitle: app.name, action: #selector(setCoverFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = [group.id, app.id]
            item.state = group.topApplicationID == app.id ? .on : .off
        }
        menu.addItem(withTitle: "最上面的应用", action: nil, keyEquivalent: "").submenu = cover
        return menu
    }

    @objc private func editGroupListFromMenu(_ item: NSMenuItem) {
        guard let groupID = item.representedObject as? String,
              DockerStore.shared.configuration.groups.contains(where: { $0.id == groupID }) else { return }
        dismissGroup()
        if let editor = stackEditors[groupID] {
            editor.present()
            return
        }
        let editor = StackListEditorController(groupID: groupID, store: DockerStore.shared) { [weak self] in
            self?.stackEditors.removeValue(forKey: groupID)
        }
        stackEditors[groupID] = editor
        editor.present()
    }

    @objc private func setCoverFromMenu(_ item: NSMenuItem) {
        guard let ids = item.representedObject as? [String], ids.count == 2 else { return }
        DockerStore.shared.setTopApplication(ids[1].isEmpty ? nil : ids[1], for: ids[0])
    }

    private func applicationMenu(for app: DockApplication, isStandalone: Bool = false, groupID: String? = nil) -> NSMenu {
        let menu = NSMenu()
        MenuCopyService.shared.appendWindowItems(to: menu, for: app)
        let running = apps.isRunning(app)
        let title = running ? "显示窗口" : "打开"
        let show = menu.addItem(withTitle: title, action: #selector(showRunningAppFromMenu(_:)), keyEquivalent: "")
        show.target = self
        show.representedObject = app

        let copiedTitles = MenuCopyService.shared.appendItems(to: menu, for: app.id)
        let quickActions = apps.quickActions(for: app).filter { !copiedTitles.contains($0.title) }
        if !quickActions.isEmpty {
            menu.addItem(.separator())
            for action in quickActions {
                let item = menu.addItem(withTitle: action.title, action: #selector(performApplicationQuickAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (app, action)
            }
            menu.addItem(.separator())
        }

        let options = NSMenu()
        if app.id != DockApplications.finderID {
            let keepTitle = apps.isPinned(app) ? "从程序坞中移除" : "在程序坞中保留"
            let keep = options.addItem(withTitle: keepTitle, action: #selector(togglePinFromMenu(_:)), keyEquivalent: "")
            keep.target = self
            keep.representedObject = app
            let rule = DockerStore.shared.rule(for: app.id)
            if let groupID = rule.groupID {
                let top = options.addItem(withTitle: "设为叠放最上面的应用", action: #selector(setCoverFromMenu(_:)), keyEquivalent: "")
                top.target = self; top.representedObject = [groupID, app.id]
                top.state = DockerStore.shared.configuration.groups.first(where: { $0.id == groupID })?.topApplicationID == app.id ? .on : .off
            }
        }
        if let url = app.url {
            let reveal = options.addItem(withTitle: "在访达中显示", action: #selector(revealRunningAppFromMenu(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = url
        }
        if options.numberOfItems > 0 {
            let optionsItem = menu.addItem(withTitle: "选项", action: nil, keyEquivalent: "")
            optionsItem.submenu = options
        }
        if let groupID, DockerStore.shared.rule(for: app.id).groupID == groupID {
            menu.addItem(.separator())
            let remove = menu.addItem(withTitle: "从叠放中移除", action: #selector(removeFromGroupFromMenu(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = [groupID, app.id]
        }
        if app.id != DockApplications.finderID, running {
            menu.addItem(.separator())
            let quit = menu.addItem(withTitle: "退出", action: #selector(quitRunningAppFromMenu(_:)), keyEquivalent: "")
            quit.target = self
            quit.representedObject = app
        }
        if !isStandalone {
            menu.delegate = self
            fanContextMenu = menu
        }
        return menu
    }

    @objc private func removeFromGroupFromMenu(_ item: NSMenuItem) {
        guard let ids = item.representedObject as? [String], ids.count == 2 else { return }
        dismissGroup()
        DockerStore.shared.removeApplication(ids[1], from: ids[0])
    }

    @objc private func performApplicationQuickAction(_ item: NSMenuItem) {
        guard let (app, action) = item.representedObject as? (DockApplication, DockApplicationQuickAction) else { return }
        dismissGroup()
        do { try apps.perform(action, for: app) }
        catch {
            let alert = NSAlert()
            alert.messageText = "无法\(action.title)"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            NSApplication.shared.activate()
            alert.runModal()
        }
    }

    @objc private func togglePinFromMenu(_ item: NSMenuItem) {
        guard let app = item.representedObject as? DockApplication else { return }
        apps.setPinned(!apps.isPinned(app), for: app)
    }

    @objc private func showRunningAppFromMenu(_ item: NSMenuItem) {
        if let app = item.representedObject as? DockApplication { launch(app) }
    }

    @objc private func revealRunningAppFromMenu(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL {
            dismissGroup()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    @objc private func quitRunningAppFromMenu(_ item: NSMenuItem) {
        guard let app = item.representedObject as? DockApplication else { return }
        dismissGroup()
        NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first?.terminate()
    }

    private func trashURL() -> URL {
        TrashService.homeURL
    }

    private func refreshTrash() {
        trashService.refresh()
        if trashService.state != .unknown { trashIcon?.isFull = trashService.state == .full }
        let label = trashService.isEmptying ? "废纸篓，正在清倒" : trashService.state == .full ? "废纸篓，有内容" : trashService.state == .empty ? "废纸篓，空" : "废纸篓"
        trashTile?.setAccessibilityLabel(label)
        trashTile?.toolTip = label
    }

    @objc private func emptyTrash(_ sender: Any?) {
        dismissGroup()
        trashService.confirmAndEmpty()
        refreshTrash()
    }

    private func buildApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Docker")
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Docker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApplication.shared.mainMenu = main
    }

    @objc private func showSettings() { onShowSettings?() }
    @objc private func showQuitPage() { onShowQuit?() }
    @objc private func recoverNativeDock() { onRecover?() }
    func authorizeWindowHelper() { windowBoundary.requestTrust() }

    func runtimeSnapshot() -> [String: Any] {
        ["dockVisible": panel?.isVisible ?? false,
         "standaloneApplicationIDs": apps.visibleApplications.map(\.id),
         "dockSlotIDs": PlacementResolver.dockSlotIDs(configuration: DockerStore.shared.configuration, standaloneIDs: apps.visibleApplications.map(\.id)),
         "glassStyle": DockerStore.shared.configuration.glassStyle,
         "glassTransparency": DockerStore.shared.configuration.glassTransparency,
         "glassLayerOpacity": 1,
         "glassInteractive": dockView?.glassIsInteractive ?? false,
         "dockResizing": isResizingDock,
         "resizeCursor": DockResizeCursorDiagnostics.snapshot,
         "contextMenu": DockContextMenuDiagnostics.snapshot,
         "windowManagement": windowBoundary.diagnostics,
         "iconSize": Double(dockView?.iconSize ?? 81),
         "dockOnActiveSpace": panel?.isOnActiveSpace ?? false,
         "dockAlpha": Double(panel?.alphaValue ?? 0),
         "dockLevel": panel?.level.rawValue ?? 0,
         "dockSuppressedForFullscreen": dockSuppressed,
         "dockBottomOffset": panel.map { $0.frame.minY - ($0.screen?.frame.minY ?? 0) } ?? 0,
         "trashState": trashService.state.rawValue,
         "trashEmptying": trashService.isEmptying,
         "trashLastAction": trashService.lastAction,
         "groups": apps.groups.map { ["id": $0.id, "name": $0.name, "applications": $0.applications.map(\.id), "topApplicationID": $0.topApplicationID ?? "", "coverApplicationIDs": PlacementResolver.coverIDs(memberIDs: $0.applications.map(\.id), topApplicationID: $0.topApplicationID)] as [String: Any] },
         "dockFrame": panel.map { ["x": $0.frame.minX, "y": $0.frame.minY, "width": $0.frame.width, "height": $0.frame.height] } ?? [:],
         "screen": panel?.screen?.localizedName ?? ""]
    }

    func reloadConfiguration(catalogChanged: Bool = false) {
        let config = DockerStore.shared.configuration
        if !catalogChanged, config == renderedConfiguration { return }
        if catalogChanged, config == renderedConfiguration {
            // An application scan changes metadata, not the Dock surface.
            apps.reload(notify: false)
            refreshRunningTiles()
            applyNotificationBadges(badgesByApp)
            return
        }
        if !catalogChanged, let prior = renderedConfiguration, config != prior {
            var withoutGlassChanges = config
            withoutGlassChanges.glassStyle = prior.glassStyle
            withoutGlassChanges.glassTransparency = prior.glassTransparency
            withoutGlassChanges.iconSize = prior.iconSize
            if withoutGlassChanges == prior {
                dockView?.applyGlass(configuration: config)
                previewDockSize(config.iconSize)
                renderedConfiguration = config
                return
            }
        }
        guard !isResizingDock else { deferredReload = true; return }
        apps.reload(notify: false)
        windowBoundary.enabled = DockerStore.shared.configuration.avoidanceEnabled
        dockRequestedVisible = DockerStore.shared.configuration.dockVisible
        changeIconSize(DockerStore.shared.configuration.iconSize)
        applyNotificationBadges(badgesByApp)
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        buildStatusMenu()
        applyDockVisibility()
    }

    private func selectedScreen() -> NSScreen? {
        if isResizingDock { return panel?.screen }
        let store = DockerStore.shared
        let c = store.configuration
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        func uuid(_ screen: NSScreen) -> String {
            guard let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value,
                  let unmanaged = CGDisplayCreateUUIDFromDisplayID(id),
                  let text = CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) else { return screen.localizedName }
            return text as String
        }
        let screenList = NSScreen.screens
        var candidate: NSScreen?
        if c.displayPolicy == .pointer {
            candidate = screenList.first { $0.frame.contains(NSEvent.mouseLocation) }
        } else if c.displayPolicy == .window || c.displayPolicy == .app {
            let active = NSWorkspace.shared.frontmostApplication
            if active?.bundleIdentifier == Bundle.main.bundleIdentifier { return panel?.screen ?? NSScreen.main }
            if c.displayPolicy == .app, let id = active?.bundleIdentifier, let target = c.rules[id]?.displayUUID {
                candidate = screenList.first { uuid($0) == target }
            }
            if candidate == nil, let pid = active?.processIdentifier,
               let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
               let entry = entries.first(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
               let bounds = entry[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) {
                let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
                let cocoa = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
                candidate = screenList.max { a,b in
                    let x = a.frame.intersection(cocoa), y = b.frame.intersection(cocoa)
                    return (x.isNull ? 0 : x.width*x.height) < (y.isNull ? 0 : y.width*y.height)
                }
            }
        }
        if c.displayPolicy == .pointer, let candidate {
            let id = uuid(candidate)
            if displayCandidate != id { displayCandidate = id; displayCandidateSince = Date() }
            if Date().timeIntervalSince(displayCandidateSince) < c.pointerFollowDelay { return panel?.screen ?? candidate }
        }
        let arrangement = screenList.map(uuid).sorted().joined(separator: "+")
        let home = c.arrangementHomes[arrangement] ?? c.homeDisplayUUID
        return candidate ?? screenList.first(where: { uuid($0) == home }) ?? screenList.first ?? NSScreen.main
    }

    private func activityTick() {
        let store = DockerStore.shared
        let config = store.configuration
        let meeting = config.hideForMeetingApps && !store.runningIDs.isDisjoint(with: config.meetingBundleIDs)
        let changed = automaticMeeting != meeting
        automaticMeeting = meeting
        if changed { applyDockVisibility() }
        if config.displayPolicy != .fixed { positionPanel() }
        if shouldShowDock, panel?.isVisible != true || (panel?.alphaValue ?? 0) < 0.98 || panel?.occlusionState.contains(.visible) != true { reassertDockForeground() }
        let trusted = DockWindowBridge.isTrusted
        if store.helperTrusted != trusted { store.helperTrusted = trusted }
        let labels = ["watching": "已连接，仅最大化和平铺时避让", "adjusted": "已为最大化或平铺窗口留位", "userInteracting": "手动操作窗口中，暂停避让", "dockResizing": "调整 Dock 大小中，松手后更新留位", "permissionRequired": "等待测试窗口助手授权", "disabled": "窗口避让已关闭", "fullScreen": "系统全屏中，Dock 暂时收起", "windowSizeConstrained": "窗口尺寸受限，Dock 保持显示", "dockStopped": "Dock 已暂停", "helperUnavailable": "窗口助手暂未连接"]
        let label = labels[windowBoundary.statusCode] ?? windowBoundary.statusCode
        if store.helperStatus != label { store.helperStatus = label }
        var names: [String: String] = [:]
        for screen in NSScreen.screens {
            if let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
               let unmanaged = CGDisplayCreateUUIDFromDisplayID(id), let text = CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) {
                names[text as String] = screen.localizedName
            }
        }
        if store.screens != names { store.screens = names }
    }

    private func changeIconSize(_ size: Double) {
        guard let previous = panel else { return }
        let oldTop = windowBoundaryGeometry()?.dockFrame.maxY
        dismissGroup()
        dockView?.resizeHandles.forEach { $0.cancelCursorTracking() }
        previous.ignoresMouseEvents = true
        applicationTiles.removeAll()
        buildPanel()
        refreshRunningTiles()
        transitionalDockTop = oldTop
        panel?.alphaValue = 0
        let current = panel
        let visible = shouldShowDock
        if visible { current?.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            previous.animator().alphaValue = 0
            current?.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self, weak current] in
            Task { @MainActor in
                previous.orderOut(nil)
                if self?.panel === current { self?.transitionalDockTop = nil }
            }
        }
        updateWindowShortcut()
    }

    private func beginDockResize() {
        guard !isResizingDock else { return }
        frozenGeometry = windowBoundaryGeometry()
        isResizingDock = true
        windowBoundary.dockResizing = true
        dismissGroup()
    }

    private func refreshDockForeground() {
        foregroundRevision += 1
        let revision = foregroundRevision
        for delay in [0.05, 0.3, 0.75] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.foregroundRevision == revision else { return }
                self.reassertDockForeground()
            }
        }
    }

    private func reassertDockForeground() {
        guard !stopping, shouldShowDock, let panel else { return }
        positionPanel()
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        if !panel.isVisible || panel.alphaValue < 0.98 {
            visibilityRevision += 1
            panel.alphaValue = 1
        }
        panel.orderFrontRegardless()
    }

    private func previewDockSize(_ size: Double) {
        dockView?.updateIconSize(CGFloat(size))
        positionPanel()
    }

    private func finishDockResize(_ size: Double) {
        previewDockSize(size)
        DockerStore.shared.change { $0.iconSize = size }
        isResizingDock = false; frozenGeometry = nil
        if deferredReload { deferredReload = false; reloadConfiguration(catalogChanged: true) }
        windowBoundary.dockResizing = false
        positionPanel()
    }

    @objc private func toggleDock() {
        DockerStore.shared.change { $0.dockVisible.toggle() }
    }

    private func applyDockVisibility() {
        guard let panel else { return }
        let visible = shouldShowDock
        visibilityRevision += 1
        let revision = visibilityRevision
        if visible {
            positionPanel()
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
        } else {
            dismissGroup()
            dockView?.resizeHandles.forEach { $0.cancelCursorTracking() }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            panel.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.visibilityRevision == revision else { return }
                if !visible { self.panel?.orderOut(nil) }
            }
        }
        updateWindowShortcut()
        windowBoundary.geometryChanged()
    }

    @objc private func openRunningTile(_ tile: PreviewTile) {
        if let app = tile.runningApplication { launch(app) }
    }

    @objc private func openTrash(_ sender: Any?) {
        NSWorkspace.shared.open(trashURL())
    }

    @objc private func openGroupFromTile(_ tile: PreviewTile) {
        let index = tile.tag
        let closeOnly = fanPanel?.isVisible == true && openGroup == index
        dismissGroup()
        guard !closeOnly, let window = tile.window else { return }

        let group = apps.groups[index]
        guard !group.applications.isEmpty else {
            DockerStore.shared.message = "「\(group.name)」尚未添加应用，可拖拽应用到此叠放。"
            DockerStore.shared.selectedPage = "stacks"
            onShowSettings?()
            return
        }
        let items = group.applications.map { app in
            DockStackGridItem(
                title: app.name, icon: app.icon, isRunning: apps.isRunning(app),
                notificationBadge: badgesByApp[app.id],
                menu: { [weak self] in self?.applicationMenu(for: app, groupID: group.id) ?? NSMenu() },
                prepareMenu: { await MenuCopyService.shared.prepareMenu(for: app) }
            )
        }
        let available = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let maximumSize = NSSize(width: available.width - 24, height: max(140, available.maxY - window.frame.maxY - 16))
        let view = DockStackFanView(items: items, maximumSize: maximumSize) { [weak self] selected in
            self?.launch(group.applications[selected])
        }
        view.onDismiss = { [weak self] in self?.dismissGroup() }
        guard let origin = fanOrigin(for: view, relativeTo: tile) else { return }
        let fan = DockFanPanel(
            contentRect: NSRect(origin: origin, size: view.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        fan.title = group.name
        fan.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        fan.isOpaque = false
        fan.backgroundColor = .clear
        fan.hasShadow = false
        fan.hidesOnDeactivate = false
        fan.isReleasedWhenClosed = false
        fan.collectionBehavior = window.collectionBehavior
        fan.contentView = view
        fanPanel = fan
        openGroup = index
        fan.makeKeyAndOrderFront(nil)
        view.animateOpening()

        localFanMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleFanEvent(event)
        }
        globalFanMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.fanContextMenuIsOpen,
                      let fan = self.fanPanel, !fan.frame.contains(NSEvent.mouseLocation) else { return }
                self.dismissGroup()
            }
        }
    }

    private func fanOrigin(for view: DockStackFanView, relativeTo tile: PreviewTile) -> NSPoint? {
        guard let window = tile.window, let screen = window.screen ?? NSScreen.main else { return nil }
        let anchor = window.convertToScreen(tile.convert(tile.bounds, to: nil))
        let minX = screen.frame.minX + 6
        let maxX = screen.frame.maxX - view.preferredSize.width - 6
        return NSPoint(x: max(minX, min(maxX, anchor.midX - view.anchorX)), y: anchor.maxY - 8)
    }

    private func handleFanEvent(_ event: NSEvent) -> NSEvent? {
        if fanContextMenuIsOpen { return event }
        if event.type == .keyDown {
            if event.keyCode == 53 {
                dismissGroup()
                return nil
            }
            return event
        }
        if let fan = fanPanel, event.window === fan,
           let view = fan.contentView as? DockStackFanView, view.handleContextMenuEvent(event) {
            return nil
        }
        if (event.type == .leftMouseDown || event.type == .rightMouseDown),
           event.window !== fanPanel, event.window !== panel {
            dismissGroup()
        }
        return event
    }

    @objc private func openFromMenu(_ sender: NSMenuItem) {
        guard let indexes = sender.representedObject as? [Int], indexes.count == 2 else { return }
        launch(apps.groups[indexes[0]].applications[indexes[1]])
    }

    private func launch(_ app: DockApplication) {
        dismissGroup()
        apps.open(app) { result in
            if case .failure(let error) = result {
                let alert = NSAlert()
                alert.messageText = "无法打开\(app.name)"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                NSApplication.shared.activate()
                alert.runModal()
            }
        }
    }
}
