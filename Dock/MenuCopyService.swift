import AppKit
import Combine
@preconcurrency import ApplicationServices

private struct MenuCopyTarget: Sendable {
    let id: String
    let name: String
    let applicationPath: String
    let processID: pid_t?
    let dockProcessID: pid_t?
}

private struct MenuCopyCapture: Sendable {
    let menu: CopiedApplicationMenu
    let partial: Bool
    let detail: String
}

private enum MenuCopyError: LocalizedError {
    case permission, dockUnavailable, dockItemUnavailable, menuUnavailable, menuOccupied
    case applicationNotRunning, noCommands, changed, disabled, actionUnavailable, uncertain

    var errorDescription: String? {
        switch self {
        case .permission: return "尚未允许 Docker 读取应用菜单，请在辅助功能设置中授权 Docker。"
        case .dockUnavailable: return "未能连接原生 Dock，可能与 Dock 隐藏状态或系统限制有关。"
        case .dockItemUnavailable: return "原生 Dock 中找不到这个应用的图标。"
        case .menuUnavailable: return "原生 Dock 未提供可读取的菜单。"
        case .menuOccupied: return "原生 Dock 已有菜单打开，请关闭后重新扫描。"
        case .applicationNotRunning: return "应用尚未运行，无法读取应用菜单栏；请打开应用后重新扫描。"
        case .noCommands: return "没有读取到可复制的快捷操作。"
        case .changed: return "原菜单已经改变，或存在无法区分的同名项目。请重新复制该应用的菜单。"
        case .disabled: return "这个操作目前在原应用中不可用。"
        case .actionUnavailable: return "原应用没有提供可执行的菜单操作，请重新扫描。"
        case .uncertain: return "已发送一次菜单操作，但原应用未确认结果。请先查看应用，避免重复执行。"
        }
    }
}

/// Serial, bounded AX requests keep an unresponsive app from blocking the Dock UI.
private actor ApplicationMenuReader {
    private var deadline = Date.distantPast
    private var remaining = 300
    private var omitted = false
    private var dynamicWindowTitles = Set<String>()
    private struct LiveReference {
        let applicationID: String
        let processID: pid_t
        let window: AXUIElement
        let tab: AXUIElement?
        let expires: Date
    }
    private var liveReferences: [String: LiveReference] = [:]
    private let reservedDockTitles: Set<String> = [
        "Options", "选项", "選項", "Show All Windows", "显示所有窗口", "顯示所有視窗",
        "Hide", "隐藏", "隱藏", "Quit", "退出", "結束", "Force Quit", "强制退出", "強制結束",
        "Open", "打开", "打開", "Show in Finder", "在访达中显示", "在 Finder 中顯示"
    ]

    func capture(_ target: MenuCopyTarget, allowMenuBar: Bool) async throws -> MenuCopyCapture {
        guard AXIsProcessTrusted() else { throw MenuCopyError.permission }
        try Task.checkCancellation()
        deadline = Date().addingTimeInterval(8)
        remaining = 300; omitted = false
        dynamicWindowTitles.removeAll()
        if let pid = target.processID,
           let windows = value(kAXWindowsAttribute, AXUIElementCreateApplication(pid)) as? [AXUIElement] {
            dynamicWindowTitles = Set(windows.prefix(80).compactMap { value(kAXTitleAttribute, $0) as? String }.filter { !$0.isEmpty })
        }
        var dockFailure = ""
        do {
            let session = try await openDockMenu(target)
            defer { close(session.menu) }
            let items = try snapshot(session.menu, path: [], depth: 0, excluding: reservedDockTitles)
            guard !items.isEmpty else { throw MenuCopyError.noCommands }
            let partial = omitted
            return MenuCopyCapture(menu: makeMenu(target, source: .nativeDock, items: items), partial: partial,
                                   detail: partial ? "部分子菜单、同名项目或过长项目无法可靠读取，已跳过。" : "已复制原生 Dock 提供的快捷操作。")
        } catch is CancellationError { throw CancellationError() }
        catch { dockFailure = error.localizedDescription }

        guard allowMenuBar else { throw MenuReadFailure(detail: dockFailure) }
        try Task.checkCancellation()
        deadline = Date().addingTimeInterval(6)
        remaining = 300; omitted = false
        do {
            let bar = try applicationMenuBar(target)
            let items = try snapshot(bar, path: [], depth: 0)
            guard !items.isEmpty else { throw MenuCopyError.noCommands }
            let detail = dockFailure + " 已改为复制应用菜单栏，放在右键菜单的“应用菜单”中。"
                + (omitted ? "部分项目无法可靠读取，已跳过。" : "")
            return MenuCopyCapture(menu: makeMenu(target, source: .applicationMenu, items: items), partial: true, detail: detail)
        } catch is CancellationError { throw CancellationError() }
        catch { throw MenuReadFailure(detail: dockFailure + " 应用菜单栏：" + error.localizedDescription) }
    }

    func readWindows(_ target: MenuCopyTarget) throws -> LiveMenuSnapshot {
        guard AXIsProcessTrusted() else { throw MenuCopyError.permission }
        guard let pid = target.processID else { throw MenuCopyError.applicationNotRunning }
        deadline = Date().addingTimeInterval(1.8)
        liveReferences = liveReferences.filter { $0.value.expires > Date() }
        if liveReferences.count > 800 { liveReferences.removeAll() }
        let app = AXUIElementCreateApplication(pid)
        guard let elements = value(kAXWindowsAttribute, app) as? [AXUIElement] else {
            throw MenuReadFailure(detail: "无法读取该应用的窗口列表；未将读取失败报告为没有窗口。")
        }
        let browser = target.id == "com.apple.Safari" || target.id.hasPrefix("com.google.Chrome")
        var windows: [LiveMenuWindow] = []
        var tabsComplete = true
        for element in elements.prefix(80) {
            guard Date() < deadline else { break }
            guard value(kAXRoleAttribute, element) as? String == kAXWindowRole else { continue }
            let title = value(kAXTitleAttribute, element) as? String ?? ""
            let token = keepReference(target, window: element, tab: nil)
            var tabs: [LiveMenuTab] = []
            if browser {
                let result = readTabs(element, target: target)
                tabs = result.tabs
                tabsComplete = tabsComplete && result.complete
            }
            windows.append(LiveMenuWindow(id: token, title: title.isEmpty ? "未命名窗口" : title,
                                          minimized: value(kAXMinimizedAttribute, element) as? Bool == true, tabs: tabs))
        }
        let complete = windows.count == elements.count
        let count = windows.reduce(0) { $0 + $1.tabs.count }
        var detail = complete ? "实时窗口：已读取 \(windows.count) 个窗口。" : "实时窗口：只读取到部分窗口（\(windows.count) 个）。"
        if browser {
            detail += tabsComplete && complete ? "已读取 \(count) 个网页标签页。" : "只读取到 \(count) 个网页标签页，未将此数量当作全部标签页。"
        }
        return LiveMenuSnapshot(windows: windows, complete: complete, tabsComplete: tabsComplete,
                                available: true, detail: detail)
    }

    func performLive(_ token: String, applicationID: String) throws {
        guard AXIsProcessTrusted() else { throw MenuCopyError.permission }
        deadline = Date().addingTimeInterval(2)
        guard let reference = liveReferences[token], reference.applicationID == applicationID,
              reference.expires > Date(), value(kAXRoleAttribute, reference.window) as? String == kAXWindowRole else {
            throw MenuCopyError.changed
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(reference.window, &pid) == .success, pid == reference.processID else {
            throw MenuCopyError.changed
        }
        if value(kAXMinimizedAttribute, reference.window) as? Bool == true {
            guard AXUIElementSetAttributeValue(reference.window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                throw MenuCopyError.actionUnavailable
            }
        }
        if let tab = reference.tab {
            guard actions(tab).contains(kAXPressAction) else { throw MenuCopyError.changed }
            let result = AXUIElementPerformAction(tab, kAXPressAction as CFString)
            if result == .cannotComplete { throw MenuCopyError.uncertain }
            guard result == .success else { throw MenuCopyError.changed }
        }
        guard AXUIElementPerformAction(reference.window, kAXRaiseAction as CFString) == .success else {
            throw MenuCopyError.actionUnavailable
        }
        _ = AXUIElementSetAttributeValue(reference.window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    private func keepReference(_ target: MenuCopyTarget, window: AXUIElement, tab: AXUIElement?) -> String {
        let token = UUID().uuidString
        liveReferences[token] = LiveReference(applicationID: target.id, processID: target.processID ?? 0,
                                               window: window, tab: tab, expires: Date().addingTimeInterval(90))
        return token
    }

    private func readTabs(_ window: AXUIElement, target: MenuCopyTarget) -> (tabs: [LiveMenuTab], complete: Bool) {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 220, Date() < deadline {
            let (element, depth) = queue.removeFirst(); visited += 1
            let role = value(kAXRoleAttribute, element) as? String ?? ""
            if role == "AXWebArea" { continue } // Never crawl controls inside a webpage.
            let identifier = value(kAXIdentifierAttribute, element) as? String ?? ""
            if role == kAXTabGroupRole || identifier.hasPrefix("TabBar?") {
                let candidates = children(element).filter { child in
                    let childID = value(kAXIdentifierAttribute, child) as? String ?? ""
                    let childRole = value(kAXRoleAttribute, child) as? String ?? ""
                    return childID.hasPrefix("TabBarTab?") || childRole == kAXRadioButtonRole || childRole == "AXTab"
                }
                if !candidates.isEmpty {
                    var result: [LiveMenuTab] = []
                    for tab in candidates.prefix(200) {
                        guard Date() < deadline else { break }
                        var title = value(kAXTitleAttribute, tab) as? String ?? ""
                        if title.isEmpty { title = value(kAXDescriptionAttribute, tab) as? String ?? "" }
                        if title.isEmpty {
                            title = children(tab).compactMap { value(kAXValueAttribute, $0) as? String }.first ?? ""
                        }
                        guard !title.isEmpty, actions(tab).contains(kAXPressAction) else { continue }
                        let selected = (value(kAXValueAttribute, tab) as? NSNumber)?.boolValue == true
                            || value(kAXSelectedAttribute, tab) as? Bool == true
                        result.append(LiveMenuTab(id: keepReference(target, window: window, tab: tab), title: title, selected: selected))
                    }
                    return (result, result.count == candidates.count)
                }
            }
            if depth < 7 { queue += children(element).map { ($0, depth + 1) } }
        }
        return ([], false)
    }

    func perform(_ menu: CopiedApplicationMenu, path: [CopiedMenuStep], target: MenuCopyTarget) async throws {
        guard AXIsProcessTrusted() else { throw MenuCopyError.permission }
        deadline = Date().addingTimeInterval(8)
        var container: AXUIElement
        var opened: AXUIElement?
        if menu.source == .nativeDock {
            let session = try await openDockMenu(target)
            container = session.menu; opened = session.menu
        } else {
            container = try applicationMenuBar(target)
        }
        defer { if let opened { close(opened) } }
        guard !path.isEmpty else { throw MenuCopyError.changed }
        for (position, step) in path.enumerated() {
            try checkTime()
            let candidates = menuItems(container)
            let steps = candidates.map { menuStep($0) }
            guard let index = step.uniqueIndex(in: steps) else { throw MenuCopyError.changed }
            let element = candidates[index]
            guard (value(kAXEnabledAttribute, element) as? Bool) != false else { throw MenuCopyError.disabled }
            if position == path.count - 1 {
                guard actions(element).contains(kAXPressAction) else { throw MenuCopyError.actionUnavailable }
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if result == .cannotComplete { throw MenuCopyError.uncertain }
                guard result == .success else { throw MenuCopyError.actionUnavailable }
            } else {
                let role = value(kAXRoleAttribute, element) as? String
                // Only menu-bar headings can be pressed while resolving a path.
                // For ordinary menu items, never guess that a press opens a submenu.
                if role == kAXMenuBarItemRole {
                    guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                        throw MenuCopyError.menuUnavailable
                    }
                    if opened == nil { opened = submenu(element) }
                } else if actions(element).contains(kAXShowMenuAction) {
                    _ = AXUIElementPerformAction(element, kAXShowMenuAction as CFString)
                }
                guard let next = submenu(element) else { throw MenuCopyError.changed }
                container = next
            }
        }
    }

    private struct DockMenuSession {
        let menu: AXUIElement
    }

    private func openDockMenu(_ target: MenuCopyTarget) async throws -> DockMenuSession {
        guard let pid = target.dockProcessID else { throw MenuCopyError.dockUnavailable }
        let dock = AXUIElementCreateApplication(pid)
        guard findMenu(dock, depth: 1) == nil else { throw MenuCopyError.menuOccupied }
        guard let item = try dockItem(target, in: dock) else { throw MenuCopyError.dockItemUnavailable }
        guard actions(item).contains(kAXShowMenuAction) else { throw MenuCopyError.menuUnavailable }
        AXUIElementSetMessagingTimeout(item, 0.5)
        let result = AXUIElementPerformAction(item, kAXShowMenuAction as CFString)
        guard result == .success || result == .cannotComplete else { throw MenuCopyError.menuUnavailable }
        // AXShowMenu may return before the menu hierarchy has been published.
        for _ in 0..<8 {
            if let menu = findMenu(item, depth: 2) ?? findMenu(dock, depth: 2) {
                return DockMenuSession(menu: menu)
            }
            do {
                try checkTime()
                try await Task.sleep(for: .milliseconds(60))
            } catch {
                if let menu = findMenu(item, depth: 2) { close(menu) }
                throw error
            }
        }
        // Cancel only the item whose menu this request opened.
        _ = AXUIElementPerformAction(item, kAXCancelAction as CFString)
        throw MenuCopyError.menuUnavailable
    }

    private func dockItem(_ target: MenuCopyTarget, in dock: AXUIElement) throws -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(dock, 0)]
        var matches: [AXUIElement] = []
        var visited = 0
        while !queue.isEmpty, visited < 260 {
            try checkTime()
            let (element, depth) = queue.removeFirst(); visited += 1
            let role = value(kAXRoleAttribute, element) as? String
            if role == kAXDockItemRole {
                let raw = value(kAXURLAttribute, element)
                let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
                if let url, url.isFileURL, url.pathExtension.lowercased() == "app" {
                    if url.resolvingSymlinksInPath().path == URL(fileURLWithPath: target.applicationPath).resolvingSymlinksInPath().path { return element }
                    if Bundle(url: url)?.bundleIdentifier == target.id { matches.append(element) }
                }
            } else if depth < 3, role != kAXMenuRole {
                queue += children(element).map { ($0, depth + 1) }
            }
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func applicationMenuBar(_ target: MenuCopyTarget) throws -> AXUIElement {
        guard let pid = target.processID else { throw MenuCopyError.applicationNotRunning }
        let application = AXUIElementCreateApplication(pid)
        guard let bar = elementValue(kAXMenuBarAttribute, application) else { throw MenuCopyError.menuUnavailable }
        return bar
    }

    private func snapshot(_ container: AXUIElement, path: [CopiedMenuStep], depth: Int,
                          excluding: Set<String> = []) throws -> [CopiedMenuItem] {
        guard depth < 6 else { omitted = true; return [] }
        let candidates = menuItems(container)
        let steps = candidates.map { menuStep($0) }
        var result: [CopiedMenuItem] = []
        for (index, element) in candidates.enumerated() {
            try checkTime()
            guard remaining > 0 else { omitted = true; break }
            let step = steps[index]
            guard !step.title.isEmpty else { continue } // separators
            if excluding.contains(step.title) || dynamicWindowTitles.contains(step.title) { continue }
            if let primary = elementValue(kAXMenuItemPrimaryUIElementAttribute, element),
               value(kAXRoleAttribute, primary) as? String == kAXWindowRole { continue }
            guard step.title.count <= 500, step.uniqueIndex(in: steps) == index else { omitted = true; continue }
            remaining -= 1
            let nextPath = path + [step]
            let nested = submenu(element)
            if nested == nil && value(kAXRoleAttribute, element) as? String == kAXMenuBarItemRole {
                omitted = true; continue
            }
            let descendants = try nested.map { try snapshot($0, path: nextPath, depth: depth + 1) } ?? []
            if nested != nil && descendants.isEmpty { omitted = true; continue }
            if nested == nil && !actions(element).contains(kAXPressAction) { omitted = true; continue }
            result.append(CopiedMenuItem(title: step.title, path: nextPath,
                                         enabled: (value(kAXEnabledAttribute, element) as? Bool) != false,
                                         checked: !(value(kAXMenuItemMarkCharAttribute, element) as? String ?? "").isEmpty,
                                         children: descendants))
        }
        return result
    }

    private func makeMenu(_ target: MenuCopyTarget, source: CopiedMenuSource, items: [CopiedMenuItem]) -> CopiedApplicationMenu {
        CopiedApplicationMenu(id: target.id, name: target.name, applicationPath: target.applicationPath,
                              source: source, capturedAt: Date(), items: items)
    }

    private func checkTime() throws {
        try Task.checkCancellation()
        guard Date() < deadline else { throw MenuReadFailure(detail: "菜单读取超时，请稍后重新扫描。") }
    }

    private func value(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        guard Date() < deadline else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func elementValue(_ name: String, _ element: AXUIElement) -> AXUIElement? {
        guard let result = value(name, element), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(result, to: AXUIElement.self)
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        value(kAXChildrenAttribute, element) as? [AXUIElement] ?? []
    }

    private func actions(_ element: AXUIElement) -> [String] {
        guard Date() < deadline else { return [] }
        AXUIElementSetMessagingTimeout(element, 0.15)
        var result: CFArray?
        guard AXUIElementCopyActionNames(element, &result) == .success else { return [] }
        return result as? [String] ?? []
    }

    private func menuStep(_ element: AXUIElement) -> CopiedMenuStep {
        let identifier = value(kAXIdentifierAttribute, element) as? String
        return CopiedMenuStep(title: value(kAXTitleAttribute, element) as? String ?? "",
                              identifier: identifier?.isEmpty == false ? identifier : nil)
    }

    private func menuItems(_ element: AXUIElement) -> [AXUIElement] {
        children(element).filter {
            let role = value(kAXRoleAttribute, $0) as? String
            return role == kAXMenuItemRole || role == kAXMenuBarItemRole
        }
    }

    private func submenu(_ element: AXUIElement) -> AXUIElement? {
        children(element).first { value(kAXRoleAttribute, $0) as? String == kAXMenuRole }
    }

    private func findMenu(_ element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth >= 0, Date() < deadline else { return nil }
        if value(kAXRoleAttribute, element) as? String == kAXMenuRole { return element }
        if let shown = elementValue(kAXShownMenuUIElementAttribute, element) { return shown }
        guard depth > 0 else { return nil }
        for child in children(element).prefix(160) {
            if let menu = findMenu(child, depth: depth - 1) { return menu }
        }
        return nil
    }

    private func close(_ menu: AXUIElement) {
        AXUIElementSetMessagingTimeout(menu, 0.25)
        _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
    }
}

private struct MenuReadFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

@MainActor
final class MenuCopyService: NSObject, ObservableObject {
    static let shared = MenuCopyService()
    @Published private(set) var archive = MenuCopyArchive()
    @Published private(set) var scanning = false
    @Published private(set) var invoking = false
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published private(set) var progress = ""
    @Published private(set) var storageMessage = ""
    @Published private(set) var liveSnapshots: [String: LiveMenuSnapshot] = [:]
    var liveWindowsEnabled: Bool { archive.liveWindowsEnabled != false }
    var onWillInvoke: (() -> Void)?
    private let reader = ApplicationMenuReader()
    private var scanTask: Task<Void, Never>?
    private var archiveURL: URL {
        DockerStore.shared.directory.appendingPathComponent(DockWindowPaths.testing ? "menu-copies-testing.json" : "menu-copies.json")
    }

    private override init() {
        super.init()
        if let data = try? Data(contentsOf: archiveURL), data.count <= 4_194_304,
           let saved = try? JSONDecoder().decode(MenuCopyArchive.self, from: data), saved.schemaVersion == 1 {
            archive = saved
        }
    }

    func refreshPermission() { trusted = AXIsProcessTrusted() }

    func requestPermission() {
        guard !DockerStore.isPreview else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !trusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func scan(_ applications: [CatalogApplication], allowMenuBar: Bool) {
        guard !scanning, !invoking, !DockerStore.isPreview else { return }
        refreshPermission()
        let targets = applications.map { target(id: $0.id, name: $0.name, path: $0.path) }
        guard !targets.isEmpty else { return }
        scanning = true
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer { self.scanning = false; self.scanTask = nil; self.progress = "" }
            for (index, target) in targets.enumerated() {
                if Task.isCancelled { break }
                self.progress = "正在复制 \(target.name)（\(index + 1)/\(targets.count)）"
                let previous = self.archive
                do {
                    let capture = try await self.reader.capture(target, allowMenuBar: allowMenuBar)
                    var menu = capture.menu
                    menu.enabled = self.archive.menus[target.id]?.enabled ?? true
                    self.archive.menus[target.id] = menu
                    self.archive.reports[target.id] = MenuCopyReport(id: target.id, name: target.name, date: Date(),
                        outcome: capture.partial ? .partial : .copied, source: menu.source,
                        commandCount: menu.commandCount, detail: capture.detail)
                } catch is CancellationError { break }
                catch {
                    let retained = self.archive.menus[target.id] != nil ? " 保留上次成功复制的项目。" : " 未向右键菜单添加项目。"
                    let hasChromeActions = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"].contains(target.id)
                    self.archive.reports[target.id] = MenuCopyReport(id: target.id, name: target.name, date: Date(),
                        outcome: hasChromeActions ? .partial : .unavailable, source: nil, commandCount: hasChromeActions ? 2 : 0,
                        detail: error.localizedDescription + (hasChromeActions
                            ? " 已提供内置的“新建窗口”和“新建无痕窗口”，这两个项目不依赖菜单复制。" : retained))
                }
                self.persist(previous: previous)
                if self.liveWindowsEnabled, !Task.isCancelled {
                    await self.refreshWindows(target)
                    if let snapshot = self.liveSnapshots[target.id], snapshot.available, !snapshot.windows.isEmpty,
                       let report = self.archive.reports[target.id], report.outcome == .unavailable {
                        let before = self.archive
                        self.archive.reports[target.id] = MenuCopyReport(id: target.id, name: target.name, date: report.date,
                            outcome: .partial, source: nil, commandCount: 0,
                            detail: report.detail + " 实时窗口／网页列表可用，将在右键时刷新。")
                        self.persist(previous: before)
                    }
                }
            }
        }
    }

    func cancel() { scanTask?.cancel() }

    func setLiveWindowsEnabled(_ enabled: Bool) {
        let previous = archive
        archive.liveWindowsEnabled = enabled
        if !enabled { liveSnapshots.removeAll() }
        persist(previous: previous)
    }

    func prepareMenu(for app: DockApplication) async {
        guard liveWindowsEnabled, !scanning, !invoking, !DockerStore.isPreview else { return }
        let target = target(id: app.id, name: app.name, path: app.url?.path ?? "")
        guard target.processID != nil else { liveSnapshots.removeValue(forKey: app.id); return }
        await refreshWindows(target)
    }

    private func refreshWindows(_ target: MenuCopyTarget) async {
        do { liveSnapshots[target.id] = try await reader.readWindows(target) }
        catch {
            liveSnapshots[target.id] = LiveMenuSnapshot(windows: [], complete: false, tabsComplete: false,
                                                       available: false, detail: "实时窗口：" + error.localizedDescription)
        }
    }

    func appendWindowItems(to menu: NSMenu, for app: DockApplication) {
        guard liveWindowsEnabled, let snapshot = liveSnapshots[app.id], snapshot.available, !snapshot.windows.isEmpty else { return }
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: (snapshot.complete ? "已打开的窗口" : "已读取的窗口") + "（\(snapshot.windows.count)）", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        for window in snapshot.windows {
            let item = liveItem(title: window.title + (window.minimized ? "（已最小化）" : ""), token: window.id, app: app)
            menu.addItem(item)
        }
        if snapshot.tabCount > 0 {
            let heading = NSMenuItem(title: (snapshot.tabsComplete && snapshot.complete ? "网页标签页" : "已读取的网页标签页") + "（\(snapshot.tabCount)）", action: nil, keyEquivalent: "")
            let tabs = NSMenu(); tabs.autoenablesItems = false
            for (index, window) in snapshot.windows.enumerated() where !window.tabs.isEmpty {
                if snapshot.windows.count > 1 {
                    let label = NSMenuItem(title: "窗口 \(index + 1)：\(window.title)", action: nil, keyEquivalent: "")
                    label.isEnabled = false; tabs.addItem(label)
                }
                for tab in window.tabs {
                    let item = liveItem(title: tab.title, token: tab.id, app: app)
                    item.state = tab.selected ? .on : .off; tabs.addItem(item)
                }
            }
            heading.submenu = tabs; menu.addItem(heading)
        }
        menu.addItem(.separator())
    }

    private struct LiveInvocation {
        let token: String
        let applicationID: String
    }

    private func liveItem(title: String, token: String, app: DockApplication) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(invokeLive(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = LiveInvocation(token: token, applicationID: app.id)
        item.isEnabled = !scanning && !invoking
        return item
    }

    @objc private func invokeLive(_ item: NSMenuItem) {
        guard let invocation = item.representedObject as? LiveInvocation, !scanning, !invoking else { return }
        onWillInvoke?()
        invoking = true
        Task {
            defer { invoking = false }
            do {
                try await reader.performLive(invocation.token, applicationID: invocation.applicationID)
                NSRunningApplication.runningApplications(withBundleIdentifier: invocation.applicationID).first?.activate()
            } catch {
                let alert = NSAlert(); alert.messageText = "无法切换到“\(item.title)”"
                alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "好")
                NSApplication.shared.activate(); alert.runModal()
            }
        }
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        let previous = archive
        archive.menus[id]?.enabled = enabled
        persist(previous: previous)
    }

    func remove(_ id: String) {
        let previous = archive
        archive.menus.removeValue(forKey: id)
        archive.reports.removeValue(forKey: id)
        persist(previous: previous)
    }

    @discardableResult
    func appendItems(to menu: NSMenu, for applicationID: String) -> Set<String> {
        guard let saved = archive.menus[applicationID], saved.enabled, !saved.items.isEmpty else { return [] }
        menu.autoenablesItems = false
        menu.addItem(.separator())
        if saved.source == .applicationMenu {
            let heading = NSMenuItem(title: "应用菜单", action: nil, keyEquivalent: "")
            let submenu = NSMenu(); submenu.autoenablesItems = false
            add(saved.items, to: submenu, saved: saved)
            heading.submenu = submenu; menu.addItem(heading)
        } else {
            add(saved.items, to: menu, saved: saved)
        }
        menu.addItem(.separator())
        return Set(saved.items.map(\.title))
    }

    private struct Invocation {
        let menu: CopiedApplicationMenu
        let path: [CopiedMenuStep]
    }

    private func add(_ entries: [CopiedMenuItem], to menu: NSMenu, saved: CopiedApplicationMenu) {
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.isEnabled = entry.enabled && !scanning && !invoking
            item.state = entry.checked ? .on : .off
            if entry.children.isEmpty {
                item.action = #selector(invoke(_:)); item.target = self
                item.representedObject = Invocation(menu: saved, path: entry.path)
            } else {
                let submenu = NSMenu(); submenu.autoenablesItems = false
                add(entry.children, to: submenu, saved: saved)
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }

    @objc private func invoke(_ item: NSMenuItem) {
        guard let invocation = item.representedObject as? Invocation, !scanning, !invoking else { return }
        let saved = invocation.menu
        guard archive.menus[saved.id]?.enabled == true else { return }
        onWillInvoke?()
        invoking = true
        let target = target(id: saved.id, name: saved.name, path: saved.applicationPath)
        Task {
            defer { invoking = false }
            do {
                // Let AppKit finish dismissing Docker's own context menu first.
                try await Task.sleep(for: .milliseconds(100))
                if saved.source == .applicationMenu, let pid = target.processID {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                    try await Task.sleep(for: .milliseconds(100))
                }
                try await reader.perform(saved, path: invocation.path, target: target)
            } catch {
                let alert = NSAlert(); alert.messageText = "无法执行“\(item.title)”"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                NSApplication.shared.activate(); alert.runModal()
            }
        }
    }

    private func target(id: String, name: String, path: String) -> MenuCopyTarget {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { !$0.isTerminated }
        return MenuCopyTarget(id: id, name: name, applicationPath: running?.bundleURL?.path ?? path,
                              processID: running?.processIdentifier,
                              dockProcessID: NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier)
    }

    private func persist(previous: MenuCopyArchive) {
        guard !DockerStore.isPreview else { return }
        do {
            let data = try JSONEncoder().encode(archive)
            guard data.count <= 4_194_304 else { throw MenuReadFailure(detail: "复制的菜单超过保存容量，请移除部分应用后重新扫描。") }
            try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: archiveURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
            storageMessage = ""
        } catch {
            archive = previous
            storageMessage = "菜单未能保存：" + error.localizedDescription
        }
    }
}
