import AppKit
import SwiftUI
import Carbon

@MainActor
final class ConsoleShortcut {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?
    func configure(enabled: Bool, key: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        stop()
        guard enabled else { return true }
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4652444B else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<ConsoleShortcut>.fromOpaque(context).takeUnretainedValue().action?() }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                                  Unmanaged.passUnretained(self).toOpaque(), &eventHandler) == noErr else { return false }
        let id = EventHotKeyID(signature: 0x4652444B, id: 1)
        guard RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey) == noErr else {
            stop(); return false
        }
        return true
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil; eventHandler = nil; action = nil
    }
}

@MainActor
final class DockerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = DockerStore.shared
    private lazy var quit = QuitService(store: store)
    private lazy var nativeDock = NativeDockService(store: store)
    private var dock: DockPreviewController?
    private var window: NSWindow?
    private let shortcut = ConsoleShortcut()
    private var observer: NSObjectProtocol?
    private var diagnosticsTimer: Timer?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !DockerStore.isPreview {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").filter { $0.processIdentifier != getpid() }
            if !CommandLine.arguments.contains("--replace-running"),
               let existing = others.first(where: { $0.bundleURL?.lastPathComponent == "Docker.app" }) {
                existing.activate()
                NSApplication.shared.terminate(nil)
                return
            }
            // The new main app retains the old Dock bundle identity so its trusted window
            // helper can be reused without replacing its signed executable.
            others.forEach { _ = $0.terminate() }
            let deadline = Date().addingTimeInterval(10)
            while others.contains(where: { !$0.isTerminated }), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            if others.contains(where: { !$0.isTerminated }) {
                let alert = NSAlert(); alert.messageText = "上一份 Docker 尚未退出"
                alert.informativeText = "请先结束上一份 Docker，再打开当前版本。"; alert.runModal()
                NSApplication.shared.terminate(nil); return
            }
            let controller = DockPreviewController()
            controller.onShowSettings = { [weak self] in self?.showConsole() }
            controller.onShowQuit = { [weak self] in self?.quit.preview(); self?.store.selectedPage = "quit"; self?.showConsole() }
            controller.onRecover = { [weak self] in self?.store.change { $0.nativeDockHidden = false } }
            dock = controller
            controller.applicationDidFinishLaunching(notification)
            nativeDock.start()
        } else {
            store.nativeDockStatus = "界面预览 · 未接管系统 Dock"
            store.helperStatus = "界面预览 · 未启动窗口助手"
        }
        buildMenus()
        if !DockerStore.isPreview { NativeQuitControl.register() }
        observer = NotificationCenter.default.addObserver(forName: .dockerConfigurationChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyAppearance(); self?.configureShortcut(); self?.writeDiagnostics() }
        }
        applyAppearance(); configureShortcut()
        showConsole()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.writeDiagnostics() }
        }
        timer.tolerance = 0.4; RunLoop.main.add(timer, forMode: .common); diagnosticsTimer = timer
        writeDiagnostics()
    }

    func showConsole() {
        guard !quitting else { return }
        NSApplication.shared.setActivationPolicy(.regular)
        if window == nil {
            let view = DockerRootView(store: store, quit: quit,
                                      authorizeWindow: { [weak self] in if !DockerStore.isPreview { self?.dock?.authorizeWindowHelper() } },
                                      authorizeNative: { [weak self] in if !DockerStore.isPreview { self?.nativeDock.openPermissions() } },
                                      showWindow: { [weak self] in self?.showConsole() })
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
            let width = min(1140, screen.width - 70), height = min(690, screen.height - 85)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            let development = Bundle.main.object(forInfoDictionaryKey: "ForsythDevelopmentBuild") as? Bool == true
            window.title = DockerStore.isPreview ? "Docker · 界面预览" : (development ? "Docker · 测试版" : (CommandLine.arguments.contains("--profile") ? "Docker · 开发调试" : "Docker"))
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 1010, height: 560)
            window.contentView = NSHostingView(rootView: view)
            window.delegate = self
            window.setFrameAutosaveName("ForsythDockerConsole")
            window.center()
            self.window = window
        }
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !DockerStore.isPreview { NSApplication.shared.setActivationPolicy(.accessory) }
    }

    private func applyAppearance() {
        switch store.configuration.appearance {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: NSApplication.shared.appearance = nil
        }
    }

    private func configureShortcut() {
        guard !DockerStore.isPreview else { return }
        let c = store.configuration
        let registered = shortcut.configure(enabled: c.mainShortcutEnabled, key: c.shortcutKeyCode, modifiers: c.shortcutModifiers) { [weak self] in
            guard let self else { return }
            if self.window?.isVisible == true { self.window?.performClose(nil) }
            else { self.showConsole() }
        }
        if !registered { store.message = "控制台快捷键已被其他应用占用，请在设置中更换。" }
    }

    private func buildMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "Docker")
        appMenu.addItem(withTitle: "关于 Docker", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "打开 Docker 控制台", action: #selector(openConsole), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Docker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApplication.shared
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem)
        let windowItem = NSMenuItem(); let windows = NSMenu(title: "窗口")
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windows; menu.addItem(windowItem)
        NSApplication.shared.mainMenu = menu; NSApplication.shared.windowsMenu = windows
    }

    @objc private func openConsole() { showConsole() }
    @objc private func about() { store.selectedPage = "settings"; showConsole() }
    @objc private func settings() { store.selectedPage = "settings"; showConsole() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showConsole(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidChangeScreenParameters(_ notification: Notification) { dock?.applicationDidChangeScreenParameters(notification) }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "forsythdocker" {
            if let page = url.host, ["overview", "apps", "stacks", "hidden", "menus", "appearance", "displays", "windows", "quit", "settings"].contains(page) {
                store.selectedPage = page
                if page == "quit" { quit.preview() }
            }
        }
        showConsole()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !quitting else { return }; quitting = true
        quit.cancel(); shortcut.stop(); diagnosticsTimer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        dock?.applicationWillTerminate(notification)
        nativeDock.stop()
        try? FileManager.default.removeItem(at: store.directory.appendingPathComponent("runtime.json"))
    }

    private func writeDiagnostics() {
        guard !DockerStore.isPreview else { return }
        var report = dock?.runtimeSnapshot() ?? [:]
        report["version"] = "1.0.0"
        report["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        report["processID"] = getpid()
        report["timestamp"] = Date().timeIntervalSince1970
        report["nativeDockHidden"] = store.nativeDockEffective
        report["nativeDockStatus"] = store.nativeDockStatus
        report["nativePermission"] = store.nativePermission
        report["helperTrusted"] = store.helperTrusted
        report["helperStatus"] = store.helperStatus
        report["configSchema"] = store.configuration.schemaVersion
        report["catalogCount"] = store.catalog.count
        report["quitControl"] = NativeQuitControl.snapshot(in: store.directory)
        report["dockResizeSurface"] = "edges"
        report["unavailableApplicationIDs"] = store.catalog.filter { !$0.installed }.map(\.id)
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let url = store.directory.appendingPathComponent("runtime.json")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

@main
@MainActor
struct Docker {
    static func main() {
        if CommandLine.arguments.contains("--control-center-status") {
            NativeQuitControl.printStatusAndExit()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--validate-configuration"), CommandLine.arguments.indices.contains(index + 1) {
            do {
                let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                let config = try DockerConfiguration.decodeValidated(Data(contentsOf: url))
                print("Valid Docker configuration: \(config.groups.count) groups, \(config.rules.count) application rules")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = DockerAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
