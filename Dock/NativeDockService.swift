import AppKit
import CoreFoundation

@MainActor
final class NativeDockService {
    private let store: DockerStore
    private var session: NativeDockSession?
    private var timer: Timer?
    private var busy = false
    private var stopping = false
    private var watchdog: Process?
    private var observer: NSObjectProtocol?
    private var lastLaunch = Date.distantPast
    private var sessionURL: URL { store.directory.appendingPathComponent("native-dock-session.json") }
    private var engineURL: URL? { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DockLock.app") }

    init(store: DockerStore) { self.store = store }

    func start() {
        guard !DockerStore.isPreview else { store.nativeDockStatus = "界面预览，未接管系统 Dock"; return }
        // Recover a previous crashed session before taking a new snapshot.
        if let data = try? Data(contentsOf: sessionURL),
           let prior = try? JSONDecoder().decode(NativeDockSession.self, from: data), !prior.ownerIsAlive() {
            _ = prior.restore(at: sessionURL)
        }
        observer = NotificationCenter.default.addObserver(forName: .dockerConfigurationChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        timer.tolerance = 0.3; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        update()
    }

    func update() {
        guard !busy, !stopping else { return }
        guard store.configuration.nativeDockHidden else {
            if let session { _ = session.restore(at: sessionURL); self.session = nil }
            store.nativeDockEffective = false; store.nativeDockStatus = "系统 Dock 已恢复 · Docker Dock 已暂停"
            return
        }
        busy = true
        Task {
            defer { busy = false }
            if session == nil {
                do {
                    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    let capture = NativeDockSession.capture()
                    try capture.save(to: sessionURL)
                    session = capture
                    await configureEngine()
                    startWatchdog(capture)
                } catch {
                    store.nativeDockStatus = "无法准备 Dock 恢复记录：\(error.localizedDescription)"
                    return
                }
            }
            guard !stopping, store.configuration.nativeDockHidden else { return }
            var report = await Task.detached(priority: .utility) { DockEngineClient.report() }.value
            if report == nil, Date().timeIntervalSince(lastLaunch) > 5 {
                await launchEngine()
                report = await Task.detached(priority: .utility) { DockEngineClient.report() }.value
            }
            if let current = report, (!current.enabled || !current.dockHidden || current.paused) {
                _ = await Task.detached(priority: .utility) {
                    _ = DockEngineClient.send(.setEnabled(true))
                    _ = DockEngineClient.send(.resume)
                    return DockEngineClient.send(.setHideDock(true))
                }.value
                report = await Task.detached(priority: .utility) { DockEngineClient.report() }.value
            }
            guard !stopping else { return }
            store.nativePermission = report?.accessibilityGranted ?? false
            store.nativeDockEffective = report.map { $0.enabled && $0.dockHidden && $0.guardActive && $0.dockAutoHide } ?? false
            if store.nativeDockEffective { store.nativeDockStatus = "系统 Dock 已完全隐藏" }
            else if let report, !report.accessibilityGranted { store.nativeDockStatus = "需要为 Dock 隐藏组件授权辅助功能" }
            else if report == nil { store.nativeDockStatus = "Dock 隐藏组件暂未连接，正在重试…" }
            else { store.nativeDockStatus = "正在启用系统 Dock 隐藏与边缘保护…" }
        }
    }

    private func configureEngine() async {
        _ = await Task.detached(priority: .utility) {
            _ = DockEngineClient.send(.setEnabled(false))
            return DockEngineClient.send(.quit)
        }.value
        for _ in 0..<30 {
            if CFMessagePortCreateRemote(nil, DockLockInfo.controlPortName as CFString) == nil { break }
            try? await Task.sleep(for: .milliseconds(60))
        }
        guard !stopping, store.configuration.nativeDockHidden, session != nil else { return }
        var settings: DockLockSettings
        if let original = session?.settings, let decoded = try? DockLockSettings.decode(original) { settings = decoded }
        else { settings = DockLockSettings() }
        settings.isEnabled = true; settings.mode = .lock; settings.showDockIcon = false; settings.showMenuBarIcon = false
        settings.autoRelocate = false; settings.autoHideWhileHidden = true
        // DockLock briefly admits the 6-point corners for system hot-corner actions,
        // then resumes the edge guard before a sustained Dock-edge gesture.
        settings.keepHotCorners = true; settings.hotCornerGrace = 0.3
        settings.bypassModifiers = []; settings.hideDockWhileScreenSharing = false
        settings.meetingAppBundleIDs = ["local.codex.native-dock-preview"]; settings.appRules = []
        let names = store.screens
        if !names.isEmpty {
            let key = ArrangementKey.make(Array(names.keys))
            let home = names.keys.sorted().first
            settings.arrangements[key] = ArrangementPreferences(allowed: home.map { [$0] } ?? [], home: home, names: names, lastUsed: Date())
        }
        settings.hotKeys = settings.hotKeys.map { var value = $0; value.enabled = false; return value }
        if let data = try? settings.encoded() {
            CFPreferencesSetAppValue("settings.v1" as CFString, data as CFData, "dev.yihui.docklock" as CFString)
            CFPreferencesAppSynchronize("dev.yihui.docklock" as CFString)
        }
        await launchEngine()
    }

    private func launchEngine() async {
        guard !stopping, let engineURL, Bundle(url: engineURL)?.bundleIdentifier == "dev.yihui.docklock" else { return }
        lastLaunch = Date()
        let options = NSWorkspace.OpenConfiguration(); options.activates = false; options.hides = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: engineURL, configuration: options)
            for _ in 0..<20 {
                if CFMessagePortCreateRemote(nil, DockLockInfo.controlPortName as CFString) != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        } catch { store.nativeDockStatus = "Dock 隐藏组件启动失败：\(error.localizedDescription)" }
    }

    private func startWatchdog(_ session: NativeDockSession) {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/DockerWatchdog")
        let process = Process(); process.executableURL = url; process.arguments = [sessionURL.path, session.token]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); watchdog = process }
        catch { store.message = "系统 Dock 自动恢复组件未启动：\(error.localizedDescription)" }
    }

    func stop() {
        stopping = true; timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let session { _ = session.restore(at: sessionURL); self.session = nil }
        if watchdog?.isRunning == true { watchdog?.terminate() }
        watchdog = nil
    }

    func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
}
