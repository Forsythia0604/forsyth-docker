import AppKit
import Foundation

@MainActor
private final class TestQuitStore: QuitServiceStore {
    var configuration = DockerConfiguration.initial()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("docker-quit-tests-" + UUID().uuidString)
    var quitIsPreview = false
    var message = ""
    init() { configuration.clearRecentsOnQuit = false }
    func rule(for id: String) -> ApplicationRule { configuration.rules[id] ?? ApplicationRule() }
}

private final class TestQuitApp: QuitApplication {
    let bundleIdentifier: String?
    let localizedName: String?
    let processIdentifier: pid_t
    let activationPolicy: NSApplication.ActivationPolicy = .regular
    var isTerminated = false
    var requests = 0
    var onTerminate: () -> Bool = { true }
    init(_ name: String, pid: pid_t) {
        localizedName = name; bundleIdentifier = "local.forsyth.quit-test." + name; processIdentifier = pid
    }
    func terminate() -> Bool { requests += 1; return onTerminate() }
    func exitAfter(_ delay: Duration) {
        onTerminate = { [weak self] in
            Task { @MainActor in try? await Task.sleep(for: delay); self?.isTerminated = true }
            return true
        }
    }
}

@main
struct QuitServiceTests {
    @MainActor
    static func main() async {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            precondition(condition(), label); checks += 1
        }
        func waitUntil(_ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(2)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            precondition(condition(), "Timed out waiting for test state")
        }

        // Reproduce the reported cutoff using a real nine-second application
        // shutdown. One click must remain active past eight seconds and then
        // automatically continue, without sending the slow app a second quit.
        do {
            let store = TestQuitStore(), first = TestQuitApp("A", pid: 1), second = TestQuitApp("B", pid: 2)
            first.exitAfter(.seconds(9)); second.onTerminate = { second.isTerminated = true; return true }
            let service = QuitService(store: store, applications: { [first, second] })
            service.preview(); let task = service.run()
            try? await Task.sleep(for: .milliseconds(8250))
            check(service.processing, "An eight-second wait must not finish the operation")
            check(service.waitingApplicationName == "A", "A slow application must be identified")
            check(second.requests == 0, "Do not stack save prompts while waiting")
            let repeated = service.run()
            await task?.value; await repeated?.value
            check(first.requests == 1 && second.requests == 1, "One request must finish both targets without repeated quits")
            check(service.entries.allSatisfy { $0.status == "已退出" }, "Automatically advance after delayed exit")
            check(!service.processing && service.waitingApplicationName == nil, "Release active and waiting states")
            try? FileManager.default.removeItem(at: store.directory)
        }
        do {
            let store = TestQuitStore(), first = TestQuitApp("A", pid: 1), second = TestQuitApp("B", pid: 2)
            second.onTerminate = { second.isTerminated = true; return true }
            let service = QuitService(store: store, applications: { [first, second] }, waitingNoticeAfter: 0.01)
            service.preview(); let task = service.run()
            await waitUntil { service.waitingApplicationName != nil }
            service.skipWaitingApplication(); await task?.value
            check(!first.isTerminated && first.requests == 1, "Skipping must preserve the waiting app")
            check(second.requests == 1 && second.isTerminated, "Skipping must continue remaining apps")
            check(service.entries[0].status == "已保留，继续其余应用", "Report the skipped app")
            try? FileManager.default.removeItem(at: store.directory)
        }
        do {
            let store = TestQuitStore(), first = TestQuitApp("A", pid: 1), second = TestQuitApp("B", pid: 2)
            let service = QuitService(store: store, applications: { [first, second] }, waitingNoticeAfter: 0.01)
            service.preview(); let task = service.run()
            await waitUntil { service.waitingApplicationName != nil }
            service.cancel(); await task?.value
            check(second.requests == 0 && !first.isTerminated, "Cancel must stop subsequent requests without forcing exit")
            check(QuitSessionLease.acquire(in: store.directory) != nil, "Cancel must release the cross-process lock")
            try? FileManager.default.removeItem(at: store.directory)
        }
        do {
            let store = TestQuitStore(), first = TestQuitApp("A", pid: 1), second = TestQuitApp("B", pid: 2)
            first.onTerminate = { false }; second.onTerminate = { second.isTerminated = true; return true }
            let service = QuitService(store: store, applications: { [first, second] })
            service.preview(); await service.run()?.value
            check(service.entries[0].status == "未能发送退出请求", "Keep an actionable failure for a rejected request")
            check(second.requests == 1, "A failed send must not block all remaining apps")
            check(!first.isTerminated, "Never force an unresponsive app to quit")
            try? FileManager.default.removeItem(at: store.directory)
        }
        do {
            let store = TestQuitStore(), app = TestQuitApp("A", pid: 1)
            app.onTerminate = { app.isTerminated = true; return false }
            let service = QuitService(store: store, applications: { [app] })
            service.preview(); await service.run()?.value
            check(service.entries[0].status == "已退出", "An exit racing with a failed send is still successful")
            try? FileManager.default.removeItem(at: store.directory)
        }
        do {
            let store = TestQuitStore(), app = TestQuitApp("A", pid: 1)
            let service = QuitService(store: store, applications: { [app] })
            service.preview(); store.configuration.rules[app.bundleIdentifier!] = ApplicationRule(keepOnQuit: true)
            await service.run()?.value
            check(app.requests == 0 && service.entries[0].status == "已按保留规则跳过", "Recheck keep rules immediately before quitting")
            try? FileManager.default.removeItem(at: store.directory)
        }
        do {
            let store = TestQuitStore(), old = TestQuitApp("A", pid: 1), replacement = TestQuitApp("A", pid: 2)
            var running = [old]
            let service = QuitService(store: store, applications: { running })
            service.preview(); running = [replacement]; await service.run()?.value
            check(replacement.requests == 0, "Do not quit a replacement process started after the preview")
            try? FileManager.default.removeItem(at: store.directory)
        }
        do {
            let store = TestQuitStore(), app = TestQuitApp("A", pid: 1)
            store.quitIsPreview = true
            let service = QuitService(store: store, applications: { [app] })
            service.preview(); check(service.run() == nil && app.requests == 0, "Preview must never quit applications")
        }
        print("Quit service: \(checks) checks passed")
    }
}
