import AppKit

@MainActor
final class DockWindowBridge {
    var geometry: (() -> (screenFrame: NSRect, visibleFrame: NSRect, dockFrame: NSRect)?)?
    var onStatusChange: ((String) -> Void)?
    var onSuppressionChange: ((Bool) -> Void)?
    var dockResizing = false { didSet { publish(force: true) } }
    var enabled = false { didSet { publish(force: true) } }
    private let session = UUID().uuidString
    private var timer: Timer?
    private let directoryEvents = DirectoryEvents()
    private var lastStatusData: Data?
    private var commands: [DockWindowCommand] = []
    private var lastGeometry: DockWindowGeometry?
    private var lastPublication: TimeInterval = 0
    private var lastLaunch: TimeInterval = 0
    private var lastStatus: String?
    private var lastSuppression = false
    private var stopped = false
    private var lastReport: DockWindowStatus?
    var statusCode: String { lastStatus ?? "starting" }
    var diagnostics: [String: Any] {
        ["helperBundleID": DockWindowPaths.helperBundleID,
         "manualWindows": lastReport?.manualWindows ?? 0,
         "managedWindows": lastReport?.managedWindows ?? 0,
         "monitoringMode": lastReport?.monitoringMode ?? "polling",
         "scanCount": lastReport?.scanCount ?? 0,
         "observedApplications": lastReport?.observedApplications ?? 0,
         "observedWindows": lastReport?.observedWindows ?? 0,
         "lastScanReason": lastReport?.lastScanReason ?? "unknown",
         "policyVersion": lastReport?.policyVersion ?? "unloaded"]
    }

    static var isTrusted: Bool {
        guard let data = try? Data(contentsOf: DockWindowPaths.status),
              let status = try? JSONDecoder().decode(DockWindowStatus.self, from: data),
              Date.timeIntervalSinceReferenceDate - status.timestamp < DockWindowPaths.freshnessInterval else { return false }
        return status.trusted
    }

    func start() {
        guard timer == nil else { return }
        stopped = false
        try? DockWindowPaths.prepareDirectory()
        installBundledHelperIfNeeded()
        publish(force: true)
        ensureHelper()
        directoryEvents.start(at: DockWindowPaths.directory) { [weak self] in self?.readStatus() }
        let timer = Timer(timeInterval: DockWindowPaths.heartbeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publish(force: false)
                self?.readStatus()
                self?.ensureHelper()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        directoryEvents.stop()
        publish(force: true)
        if DockWindowPaths.testing {
            NSRunningApplication.runningApplications(withBundleIdentifier: DockWindowPaths.helperBundleID).forEach { _ = $0.terminate() }
        }
    }

    func requestTrust() { request(.authorize) }
    func geometryChanged() { publish(force: false) }
    func maximizeFocusedWindow() { request(.maximize, processID: NSWorkspace.shared.frontmostApplication?.processIdentifier) }
    func restoreMinimizedWindow(for processID: pid_t) { request(.restore, processID: processID) }

    private func request(_ action: DockWindowCommand.Action, processID: pid_t? = nil) {
        commands.append(DockWindowCommand(id: UUID().uuidString, action: action,
                                         timestamp: Date.timeIntervalSinceReferenceDate, processID: processID))
        publish(force: true)
        ensureHelper()
    }

    private func publish(force: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        commands.removeAll { now - $0.timestamp > 3 }
        let frames = stopped ? nil : geometry?()
        let current = frames.map {
            DockWindowGeometry(screen: WindowRect($0.screenFrame), available: WindowRect($0.visibleFrame),
                               dock: WindowRect($0.dockFrame))
        }
        guard force || current != lastGeometry || now - lastPublication >= DockWindowPaths.heartbeatInterval else { return }
        let packet = DockWindowPacket(schemaVersion: 1, session: session,
                                      processID: ProcessInfo.processInfo.processIdentifier, timestamp: now,
                                      enabled: enabled && !stopped, geometry: current, commands: commands,
                                      dockResizing: dockResizing)
        do {
            try DockWindowPaths.write(packet, to: DockWindowPaths.geometry)
            lastGeometry = current
            lastPublication = now
        } catch { report("bridgeUnavailable") }
    }

    private func ensureHelper() {
        guard !stopped, Date.timeIntervalSinceReferenceDate - lastLaunch > 5 else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: DockWindowPaths.helperBundleID).isEmpty else { return }
        lastLaunch = Date.timeIntervalSinceReferenceDate
        guard Bundle(url: DockWindowPaths.helper)?.bundleIdentifier == DockWindowPaths.helperBundleID else {
            report("helperMissing")
            return
        }
        Task {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = false
            do { _ = try await NSWorkspace.shared.openApplication(at: DockWindowPaths.helper, configuration: configuration) }
            catch { report("helperUnavailable") }
        }
    }

    private func installBundledHelperIfNeeded() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Dock 窗口助手.app", isDirectory: true)
        let policy = Bundle.main.resourceURL?.appendingPathComponent("WindowHelper/window-layout.js")
        do {
            if DockWindowPaths.testing {
                if let policy {
                    let data = try Data(contentsOf: policy)
                    if (try? Data(contentsOf: DockWindowPaths.policy)) != data { try data.write(to: DockWindowPaths.policy, options: .atomic) }
                }
                return
            }
            if !FileManager.default.fileExists(atPath: DockWindowPaths.helper.path) {
                guard Bundle(url: bundled)?.bundleIdentifier == DockWindowPaths.helperBundleID else { return }
                try FileManager.default.copyItem(at: bundled, to: DockWindowPaths.helper)
            }
            if !FileManager.default.fileExists(atPath: DockWindowPaths.policy.path), let policy {
                try FileManager.default.copyItem(at: policy, to: DockWindowPaths.policy)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: DockWindowPaths.policy.path)
            }
        } catch { report("helperUnavailable") }
    }

    private func readStatus() {
        guard let data = try? Data(contentsOf: DockWindowPaths.status),
              let status = try? JSONDecoder().decode(DockWindowStatus.self, from: data),
              status.schemaVersion == 1, status.session == session,
              Date.timeIntervalSinceReferenceDate - status.timestamp < DockWindowPaths.freshnessInterval else {
            lastStatusData = nil
            lastReport = nil
            if lastSuppression {
                lastSuppression = false
                onSuppressionChange?(false)
            }
            report("helperUnavailable")
            return
        }
        guard data != lastStatusData else { return }
        lastStatusData = data
        lastReport = status
        report(status.code)
        // A normal window that cannot shrink must not make the Dock disappear.
        // Only a real native fullscreen Space may temporarily suppress it.
        let suppress = status.shouldSuppressDock
        if lastSuppression != suppress {
            lastSuppression = suppress
            onSuppressionChange?(suppress)
        }
    }

    private func report(_ code: String) {
        guard code != lastStatus else { return }
        lastStatus = code
        onStatusChange?(code)
    }
}
