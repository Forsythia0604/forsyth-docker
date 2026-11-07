import AppKit
import Combine

struct QuitEntry: Identifiable {
    let id: String
    let name: String
    let processIDs: [pid_t]
    var selected = true
    var status = "等待退出"
}

@MainActor
protocol QuitServiceStore: AnyObject {
    var configuration: DockerConfiguration { get }
    var directory: URL { get }
    var quitIsPreview: Bool { get }
    var message: String { get set }
    func rule(for id: String) -> ApplicationRule
}

protocol QuitApplication: AnyObject {
    var bundleIdentifier: String? { get }
    var localizedName: String? { get }
    var processIdentifier: pid_t { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
}

extension NSRunningApplication: QuitApplication {}

@MainActor
final class QuitService: ObservableObject {
    @Published var entries: [QuitEntry] = []
    @Published var processing = false
    @Published var summary = ""
    @Published private(set) var waitingApplicationName: String?
    private var cancelled = false
    private var skipWaiting = false
    private var activeTask: Task<Void, Never>?
    private let store: any QuitServiceStore
    private let applications: () -> [any QuitApplication]
    private let waitingNoticeAfter: TimeInterval
    init(store: any QuitServiceStore,
         applications: @escaping () -> [any QuitApplication] = { NSWorkspace.shared.runningApplications },
         waitingNoticeAfter: TimeInterval = 8) {
        self.store = store; self.applications = applications; self.waitingNoticeAfter = waitingNoticeAfter
    }

    func preview() {
        guard !processing else { return }
        let apps = applications().filter { !$0.isTerminated && $0.activationPolicy == .regular }
        let candidates = PlacementResolver.quitTargets(regularIDs: Set(apps.compactMap(\.bundleIdentifier)),
                                                        rules: store.configuration.rules,
                                                        ownID: Bundle.main.bundleIdentifier ?? "")
        entries = candidates.sorted().map { id in
            let instances = apps.filter { $0.bundleIdentifier == id }
            return QuitEntry(id: id, name: instances.first?.localizedName ?? id, processIDs: instances.map(\.processIdentifier))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        summary = entries.isEmpty ? "没有需要退出的应用。" : "将正常退出选中的应用。未保存内容由应用自行提示。"
    }

    @discardableResult
    func run() -> Task<Void, Never>? {
        guard !store.quitIsPreview else { summary = "界面预览不会退出其他应用。"; return nil }
        guard !processing else { return activeTask }
        guard let lease = QuitSessionLease.acquire(in: store.directory) else {
            summary = "已有退出任务正在进行，请先处理该任务。"; return nil
        }
        cancelled = false; skipWaiting = false; processing = true
        let task = Task { @MainActor in
            defer { lease.release(); waitingApplicationName = nil; processing = false; activeTask = nil }
            for index in entries.indices where entries[index].selected && entries[index].status == "等待退出" {
                guard !cancelled else { break }
                let target = entries[index]
                guard !store.rule(for: target.id).keepOnQuit, !DockerConfiguration.protectedIDs.contains(target.id) else {
                    entries[index].status = "已按保留规则跳过"; continue
                }
                let live = applications().filter {
                    target.processIDs.contains($0.processIdentifier) && !$0.isTerminated && $0.bundleIdentifier == target.id
                }
                guard !live.isEmpty else { entries[index].status = "已退出"; continue }
                entries[index].status = "正在请求正常退出…"
                // A process may exit between the snapshot and terminate(). A false
                // return only fails this target if that same process is still alive.
                let unsent = live.filter { !$0.terminate() }
                if unsent.contains(where: { !$0.isTerminated }) {
                    entries[index].status = "未能发送退出请求"
                    continue
                }
                let requested = Date()
                skipWaiting = false
                while !cancelled && !skipWaiting && !live.allSatisfy(\.isTerminated) {
                    if Date().timeIntervalSince(requested) >= waitingNoticeAfter && waitingApplicationName == nil {
                        waitingApplicationName = target.name
                        entries[index].status = "等待保存提示或应用完成退出…"
                        summary = "正在等待“\(target.name)”退出。处理它的保存提示后会自动继续，也可以保留它并继续其余应用。"
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                waitingApplicationName = nil
                if live.allSatisfy(\.isTerminated) { entries[index].status = "已退出" }
                else if skipWaiting { entries[index].status = "已保留，继续其余应用" }
                else {
                    entries[index].status = "尚未退出"
                    summary = "已停止后续请求；已显示的保存提示仍由对应应用处理。"
                    return
                }
            }
            let pending = entries.contains { $0.selected && $0.status != "已退出" && $0.status != "已按保留规则跳过" }
            if cancelled { summary = "已停止后续退出请求。" }
            else if !pending {
                if store.configuration.clearRecentsOnQuit { clearRecents() }
                summary = "选中的应用已退出，保留名单中的应用继续运行。"
            } else { summary = "其余应用已处理；部分应用仍在运行，请检查退出清单和对应窗口。" }
        }
        activeTask = task
        return task
    }

    func cancel() { cancelled = true }
    func skipWaitingApplication() { if waitingApplicationName != nil { skipWaiting = true } }

    func clearRecents() {
        guard !store.quitIsPreview else { summary = "预览模式不会修改系统 Dock。"; return }
        CFPreferencesSetAppValue("recent-apps" as CFString, [] as CFArray, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); process.arguments = ["Dock"]
        do { try process.run(); store.message = "已清理最近使用记录；固定项目保持不变。" }
        catch { store.message = "清理记录后未能刷新 Dock：\(error.localizedDescription)" }
    }
}
