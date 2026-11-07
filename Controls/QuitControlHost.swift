import AppKit
import Combine
import SwiftUI
import WidgetKit

@MainActor
final class QuitControlHostDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private lazy var store = DockerStore.shared
    private lazy var service = QuitService(store: store)
    private var idleTimer: Timer?
    private var activeRun: Task<Void, Never>?
    private var activeRequests = 0
    private var waitingObserver: AnyCancellable?
    private var window: NSWindow?
    private var started: Date?
    private var candidates = 0
    private var sequence = 0
    private var invocationID = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        ControlCenter.shared.reloadControls(ofKind: "local.forsyth.docker.quit")
        waitingObserver = service.$waitingApplicationName.removeDuplicates().sink { [weak self] name in
            guard name != nil else { return }
            Task { @MainActor in self?.showProgress(); self?.writeReport(finished: false) }
        }
        DockerQuitControlDispatch.install { [weak self] in await self?.runQuit() }
        scheduleExit(after: CommandLine.arguments.contains("--register-controls") ? 5 : 30)
    }

    private func runQuit() async {
        idleTimer?.invalidate(); idleTimer = nil
        activeRequests += 1
        defer {
            activeRequests -= 1
            // Let App Intents deliver its result before the host exits. Further
            // clicks during an active run await that run instead of being lost.
            if activeRequests == 0 { scheduleExit(after: window == nil ? 2 : 30) }
        }
        if let activeRun {
            await activeRun.value
            return
        }
        let task = Task { @MainActor in
            started = Date(); invocationID = UUID().uuidString
            let path = store.directory.appendingPathComponent("quit-control-last.json")
            if let data = try? Data(contentsOf: path),
               let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               previous["provider"] as? String == "native-control" { sequence = previous["sequence"] as? Int ?? 0 }
            sequence += 1
            service.preview(); candidates = service.entries.count
            let operation = service.run()
            writeReport(finished: false)
            await operation?.value
            writeReport(finished: true)
            if service.entries.contains(where: { $0.selected && $0.status != "已退出" && $0.status != "已按保留规则跳过" }) {
                showProgress()
            }
        }
        activeRun = task
        await task.value
        activeRun = nil
    }

    private func scheduleExit(after delay: TimeInterval) {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activeRequests == 0, !self.service.processing else { return }
                NSApplication.shared.terminate(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common); idleTimer = timer
    }

    private func showProgress() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Docker · 一键退出"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: QuitControlProgress(service: service))
            window.delegate = self; window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    private func writeReport(finished: Bool) {
        guard let started else { return }
        var report: [String: Any] = ["provider": "native-control", "schemaVersion": 2,
            "invocationID": invocationID, "sequence": sequence, "started": started.timeIntervalSince1970,
            "hostBundleID": Bundle.main.bundleIdentifier ?? "", "candidates": candidates,
            "exited": service.entries.filter { $0.status == "已退出" }.count,
            "processing": service.processing, "finished": finished, "summary": service.summary,
            "entries": service.entries.map { ["id": $0.id, "name": $0.name, "status": $0.status] }]
        if let waiting = service.waitingApplicationName { report["waitingApplication"] = waiting }
        if finished { report["completed"] = Date().timeIntervalSince1970 }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let url = store.directory.appendingPathComponent("quit-control-last.json")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { if started != nil { service.cancel() } }
    func windowWillClose(_ notification: Notification) { service.cancel() }
}

private struct QuitControlProgress: View {
    @ObservedObject var service: QuitService
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(service.processing ? "正在退出应用" : "退出处理结果").font(.title2.bold())
            Text(service.summary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(service.entries) { entry in
                        HStack { Text(entry.name); Spacer(); Text(entry.status).foregroundStyle(.secondary) }
                    }
                }
            }.frame(maxHeight: 180)
            HStack {
                if service.waitingApplicationName != nil {
                    Button("保留当前应用并继续") { service.skipWaitingApplication() }
                }
                Spacer()
                if service.processing {
                    Button("停止后续退出", role: .cancel) { service.cancel() }
                } else {
                    Button("完成") { NSApplication.shared.terminate(nil) }.keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 460, height: 400)
    }
}

@main @MainActor
struct DockerControlHost {
    static func main() {
        if CommandLine.arguments.contains("--control-center-status") {
            Task { @MainActor in
                do {
                    let controls = try await ControlCenter.shared.currentControls()
                    let data = try JSONSerialization.data(withJSONObject: controls.map { ["kind": $0.kind] })
                    print(String(decoding: data, as: UTF8.self)); exit(0)
                } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            RunLoop.main.run(); return
        }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = QuitControlHostDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv) }
    }
}
